@preconcurrency import CoreVideo
import CryptoKit
import Foundation
import MonitorToolsCore
import MonitorToolsMetal

struct BenchmarkFailure: Error { let reason: String }
func require(_ condition: Bool, _ reason: String) throws {
  if !condition { throw BenchmarkFailure(reason: reason) }
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func dimensions(_ buffer: CVPixelBuffer) -> String {
  "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
}
func summary(_ samples: [Double]) -> [String: Any] {
  let sorted = samples.sorted()
  func percentile(_ q: Double) -> Any {
    guard !sorted.isEmpty else { return NSNull() }
    return sorted[Int((Double(sorted.count - 1) * q).rounded(.down))]
  }
  return ["count": sorted.count, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
          "p99_ms": percentile(0.99)]
}
func fingerprint(_ buffer: CVPixelBuffer) -> String {
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "unavailable" }
  let data = Data(bytesNoCopy: base, count: CVPixelBufferGetDataSize(buffer), deallocator: .none)
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  var attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
  if format == kCVPixelFormatType_32BGRA { attributes[kCVPixelBufferMetalCompatibilityKey] = true }
  let attrs = attributes as CFDictionary
  try require(CVPixelBufferCreate(nil, width, height, format, attrs, &buffer) == kCVReturnSuccess,
              "synthetic allocation failed")
  guard let buffer else { throw BenchmarkFailure(reason: "missing synthetic buffer") }
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  guard let base = CVPixelBufferGetBaseAddress(buffer) else {
    throw BenchmarkFailure(reason: "synthetic buffer has no base address")
  }
  memset(base, 0, CVPixelBufferGetDataSize(buffer))
  let row = CVPixelBufferGetBytesPerRow(buffer)
  if format == kCVPixelFormatType_422YpCbCr10 {
    let words = base.assumingMemoryBound(to: UInt32.self)
    for y in 0..<height {
      for x in stride(from: 0, to: width, by: 6) {
        func level(_ offset: Int) -> UInt32 {
          let column = min(width - 1, x + offset)
          let detail = (column / 12 + y / 16) % 2 == 0 ? 0 : 80
          return UInt32(min(940, 64 + column * 796 / (width - 1) + detail))
        }
        let i = y * (row / 4) + x / 6 * 4
        words[i] = 512 | (level(0) << 10) | (512 << 20)
        words[i + 1] = level(1) | (512 << 10) | (level(2) << 20)
        words[i + 2] = 512 | (level(3) << 10) | (512 << 20)
        words[i + 3] = level(4) | (512 << 10) | (level(5) << 20)
      }
    }
  } else {
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width {
        let detail = (x / 12 + y / 16) % 2 == 0 ? 0 : 24
        let value = UInt8(min(255, x * 231 / (width - 1) + detail))
        let i = y * row + x * 4
        bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
      }
    }
  }
  return buffer
}

enum BenchmarkCase: String {
  case focus = "focus-only-sony-v210-4k-paired1080"
  case scaling = "scaled-preview-v210-4k-zebra120"
  case scopes = "scopes-only-rgb-parade-v210-4k-30hz"
  case owned = "owned-bgra4k-preview-zebra120"
  case sony = "sony-false-color-semantic-change"
  case elZone = "el-zone-candidate-only"
  var algorithm: String {
    if self == .sony {
      #if MONITOR_RESOURCE_STATISTICS
      return "candidate Sony native SLog3 Pattern2 classifier; different semantics from baseline"
      #else
      return "baseline per-channel Sony SLog3 decode, S-Gamut3.Cine luminance, ARRI LogC3 EI800 bands"
      #endif
    }
    if self == .elZone { return "candidate versioned Ultracam EL Zone public-chart midpoint profile; vendor parity unqualified" }
    return "same declared feature configuration; implementation may differ; image accuracy remains package-test evidence"
  }
  func configuration() -> MonitorConfiguration {
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.sourceProfileID = self == .owned ? nil : "sony-slog3-sgamut3cine"
    config.sourceCodeRange = self == .owned ? .full : .legal
    config.sourceLogMapping = .native10Bit
    config.pictureStage = self == .focus ? .processedOutput : .source
    config.scopeStage = .source
    switch self {
    case .focus: config.focus.enabled = true
    case .scaling, .owned:
      config.zebra.enabled = true; config.zebra.thresholdIRE = 120
    case .scopes:
      config.scopes.enabled = true; config.scopes.mode = .rgbParade; config.scopes.refreshHz = 30
    case .sony:
      #if MONITOR_RESOURCE_STATISTICS
      config.falseColor.mode = .sonySLog3
      config.falseColor.profileID = SonySLog3FalseColor.profileID
      config.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
      #else
      config.falseColor.mode = .arri
      config.falseColor.profileID = SonyARRIStyleFalseColor.profileID
      config.falseColor.specificationVersion = SonyARRIStyleFalseColor.specificationVersion
      #endif
    case .elZone:
      #if MONITOR_RESOURCE_STATISTICS
      config.falseColor.mode = .elZone
      config.falseColor.profileID = ELZoneProfile.profileID
      config.falseColor.specificationVersion = ELZoneProfile.specificationVersion
      #endif
    }
    return config.normalized()
  }
}

final class Measurements: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: MonitorDisplayResult?
  private var measuring = false
  private var activeSequence: UInt64 = 0
  private var gpu: [[String: Double]] = []
  private var frames: [[String: Any]] = []
  private var failures: [String] = []
  private var lastScope: UInt64 = 0
  func beginOffer(sequence: UInt64, measured: Bool) {
    lock.lock(); activeSequence = sequence; measuring = measured; lock.unlock()
  }
  func recordGPU(_ start: Double, _ end: Double) {
    lock.lock(); defer { lock.unlock() }
    if measuring && end > start {
      gpu.append(["sequence": Double(activeSequence), "gpu_start": start, "gpu_end": end, "ms": (end-start)*1000])
    }
  }
  func accept(_ result: Result<MonitorDisplayResult, Error>, sequence: UInt64, started: Double,
              measured: Bool) {
    let completed = now()
    var previous: MonitorDisplayResult?
    lock.lock()
    switch result {
    case .success(let display):
      previous = latest; latest = display
      let fresh = display.scope.map { $0.stamp.sequence == sequence } ?? false
      let advancing = display.scope.map { $0.stamp.sequence > lastScope } ?? false
      if let scope = display.scope { lastScope = max(lastScope, scope.stamp.sequence) }
      if measured {
        frames.append(["sequence": sequence, "latency_ms": (completed-started)*1000,
                       "offer_started_uptime": started, "callback_uptime": completed,
                       "clean_dimensions": dimensions(display.clean.pixelBuffer),
                       "decorated_dimensions": display.decorated.map { dimensions($0.pixelBuffer) } ?? "none",
                       "scope_updated_this_offer": fresh, "scope_advanced": advancing,
                       "scope_sequence": display.scope.map { $0.stamp.sequence as Any } ?? NSNull(),
                       "scope_sampling_stride": display.scope.map { $0.samplingStride as Any } ?? NSNull(),
                       "availability": display.availability])
      }
    case .failure(let error): failures.append("sequence \(sequence): \(error)")
    }
    lock.unlock()
    withExtendedLifetime(previous) {}
  }
  func releaseLatest() {
    lock.lock(); let previous = latest; latest = nil; lock.unlock()
    withExtendedLifetime(previous) {}
  }
  func snapshot() -> (frames: [[String: Any]], gpu: [[String: Double]], failures: [String]) {
    lock.lock(); defer { lock.unlock() }; return (frames, gpu, failures)
  }
}

func resourceStatistics(_ runtime: MonitorRuntime) -> [String: Any] {
  #if MONITOR_RESOURCE_STATISTICS
  let value = runtime.resourceStatistics
  return ["available": true, "scope": "runtime cumulative since creation, including warmup; byte counts are active image payload excluding row padding and zero-fill; pool capacity is a conservative cache reservation bound, not physical allocated bytes",
          "cleanCopiedBytes": value.cleanCopiedBytes, "stagingCopiedBytes": value.stagingCopiedBytes,
          "ownedInputBoundBytes": value.ownedInputBoundBytes,
          "ownedInputBoundBytes_semantics": "avoided active image payload upload, excluding row padding and zero-fill; not copied bytes or additional memory",
          "compositeAllocations": value.compositeAllocations, "compositeReuses": value.compositeReuses,
          "compositePoolFailures": value.compositePoolFailures,
          "compositePoolCapacityBytes": value.compositePoolCapacityBytes]
  #else
  return ["available": false, "reason": "frozen baseline has no public resourceStatistics API"]
  #endif
}

func runCase(_ name: BenchmarkCase, source: CVPixelBuffer, output: CVPixelBuffer,
             bgra: CVPixelBuffer) -> [String: Any] {
  let measured = Measurements()
  let runtime = MonitorRuntime(gpuTiming: { measured.recordGPU($0, $1) })
  let target = MonitorTargetID("microbenchmark-\(name.rawValue)")
  let config = name.configuration()
  runtime.configure(target: target, generation: 1, configurationRevision: 1, configuration: config)
  let input = name == .owned ? bgra : source
  let sourceSignal = MonitorFrameSignal(range: name == .owned ? .full : .legal, matrix: .bt709,
                                       transfer: name == .owned ? "sRGB" : "slog3",
                                       profileID: name == .owned ? nil : "sony-slog3-sgamut3cine")
  let outputSignal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "sRGB")
  var submit: [[String: Any]] = [], rejected = 0, timedOut = false, peakBytes = 0, attempted = 0
  var nextScopeOffer = now()
  var measurementStarted: Double?
  let caseStarted = now()
  for index in 0..<150 {
    if name == .scopes {
      let delay = nextScopeOffer-now()
      if delay > 0 { Thread.sleep(forTimeInterval: delay) }
      nextScopeOffer = max(nextScopeOffer + 1.0/30.0, now())
    }
    let isMeasured = index >= 30, sequence = UInt64(index + 1), done = DispatchSemaphore(value: 0)
    measured.beginOffer(sequence: sequence, measured: isMeasured)
    if index == 30 { measurementStarted = now() }
    let started = now()
    let stamp = MonitorFrameStamp(target: target, generation: 1, sequence: sequence,
                                 sourcePTS: Double(index)*1001/30000, hostTime: started,
                                 configurationRevision: 1)
    let frame = MonitorFrameBundle(stamp: stamp, source: input, output: output,
                                  outputGeometry: MonitorGeometry(width: 1920, height: 1080),
                                  correspondence: MonitorCorrespondence(scaleX: 0.5, scaleY: 0.5, offsetX: 0, offsetY: 0),
                                  sourceSignal: sourceSignal, outputSignal: outputSignal)
    let offered = now()
    let accepted = runtime.offer(frame) { result in
      measured.accept(result, sequence: sequence, started: offered, measured: isMeasured)
      done.signal()
    }
    attempted += 1
    let submitMS = (now()-offered)*1000
    if isMeasured { submit.append(["sequence": sequence, "submit_wall_ms": submitMS, "admitted": accepted]) }
    if !accepted { rejected += 1 }
    else if done.wait(timeout: .now() + 5) == .timedOut { timedOut = true; break }
    // Deadline fallback can deliver a clean frame while committed GPU work is
    // still charged. Preserve one real job in flight even for a failed sample.
    let jobDrainDeadline = now()+5
    while runtime.ledger.snapshot.analysisJobs > 0 && now() < jobDrainDeadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    if runtime.ledger.snapshot.analysisJobs > 0 { timedOut = true; break }
    peakBytes = max(peakBytes, runtime.ledger.snapshot.retainedBytes)
  }
  let elapsed = now()-caseStarted
  let measuredWall = measurementStarted.map { now()-$0 }
  let sample = measured.snapshot()
  let before = resourceStatistics(runtime)
  runtime.remove(target: target)
  measured.releaseLatest()
  let drainDeadline = now()+3
  while runtime.ledger.snapshot.retainedBytes > 0 && now() < drainDeadline { Thread.sleep(forTimeInterval: 0.01) }
  let retained = runtime.ledger.snapshot.retainedBytes
  let frames = sample.frames
  let decorated = frames.filter { ($0["decorated_dimensions"] as? String) != "none" }.count
  let scopes = frames.filter { $0["scope_updated_this_offer"] as? Bool == true }.count
  let updatedSequences = Set(frames.filter { $0["scope_updated_this_offer"] as? Bool == true }
    .compactMap { $0["sequence"] as? UInt64 }.map { Double($0) })
  let passed = rejected == 0 && !timedOut && sample.failures.isEmpty && frames.count == 120
    && decorated == 120 && sample.gpu.count == 120 && retained == 0 && (name != .scopes || scopes >= 60)
  return ["case": name.rawValue, "status": passed ? "passed" : "failed", "algorithm": name.algorithm,
          "configuration": String(data: (try? JSONEncoder().encode(config)) ?? Data(), encoding: .utf8) ?? "unavailable",
          "warmup_offer_target": 30, "measured_offer_target": 120, "actual_total_offers": attempted,
          "measured_completed": frames.count, "measured_decorated": decorated,
          "scope_updates_for_offered_sequence": scopes,
          "scope_schedule": name == .scopes ? "real host time; paced 30Hz outside submit/latency interval; runtime30Hz scope gate retained" : "unpaced serialized offers",
          "rejected_total_including_warmup": rejected, "callback_timeout": timedOut,
          "failures": sample.failures, "elapsed_including_warmup_and_scope_pacing_seconds": elapsed,
          "measured_wall_seconds_including_scope_pacing_and_job_drains": measuredWall.map { $0 as Any } ?? NSNull(),
          "measured_completed_per_second_including_scope_pacing_and_job_drains": measuredWall.map { Double(frames.count)/$0 as Any } ?? NSNull(),
          "timing_anchor": "submit wall surrounds runtime.offer only; latency ends at callback entry; scope pacing and ledger drains are outside each interval",
          "submit_wall": summary(submit.compactMap { $0["submit_wall_ms"] as? Double }),
          "callback_latency": summary(frames.compactMap { $0["latency_ms"] as? Double }),
          "scope_update_callback_latency": summary(frames.filter { $0["scope_updated_this_offer"] as? Bool == true }.compactMap { $0["latency_ms"] as? Double }),
          "compose_only_callback_latency": summary(frames.filter { $0["scope_updated_this_offer"] as? Bool != true }.compactMap { $0["latency_ms"] as? Double }),
          "gpu_command_intervals": summary(sample.gpu.compactMap { $0["ms"] }),
          "scope_update_gpu_command_intervals": summary(sample.gpu.filter { updatedSequences.contains($0["sequence"] ?? -1) }.compactMap { $0["ms"] }),
          "compose_only_gpu_command_intervals": summary(sample.gpu.filter { !updatedSequences.contains($0["sequence"] ?? -1) }.compactMap { $0["ms"] }),
          "gpu_metric": "actual command GPU start/end intervals, not utilization; full command may include focus, compose and scope stages",
          "raw_submit_samples": submit, "raw_callback_samples": frames, "raw_gpu_samples": sample.gpu,
          "resource_statistics_before_removal": before, "resource_statistics_after_teardown": resourceStatistics(runtime),
          "observed_peak_ledger_bytes_after_each_completion": peakBytes, "teardown_retained_bytes": retained]
}

func run() throws {
  try require(CommandLine.arguments.count == 2, "output directory required; counts and cases are fixed")
  let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  try require(!FileManager.default.fileExists(atPath: root.path), "output directory already exists; preserve prior run")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let source = try makeBuffer(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)
  let output = try makeBuffer(width: 1920, height: 1080, format: kCVPixelFormatType_32BGRA)
  let bgra = try makeBuffer(width: 3840, height: 2160, format: kCVPixelFormatType_32BGRA)
  let hashes = ["source_v210": fingerprint(source), "paired_output_bgra": fingerprint(output), "source_bgra": fingerprint(bgra)]
  var cases: [BenchmarkCase] = [.focus, .scaling, .scopes, .owned, .sony]
  #if MONITOR_RESOURCE_STATISTICS
  cases.append(.elZone)
  let buildKind = "candidate-resource-statistics-native-Sony-and-EL"
  #else
  let buildKind = "baseline-legacy-Sony-no-resource-statistics"
  #endif
  var results: [[String: Any]] = []
  var receipt: [String: Any] = ["status": "running", "synthetic_only": true, "build_kind": buildKind,
    "qualification": "isolated synthetic throughput microbenchmark; not real cadence, accuracy, recording or sustained qualification",
    "percentile_method": "sorted sample index floor((n-1)*q), milliseconds; raw samples retained",
    "semantic_comparison_limit": "Sony baseline and candidate implement different algorithms; EL has no baseline; do not claim equivalent per-feature speedup",
    "ownership": "one offer in flight; holds only latest display result; no output samples retained",
    "fixture": "immutable neutral-chroma legal10bit ramp/checker v210 plus BGRA ramp/checker; buffers not paired colorimetrically",
    "fixture_sha256": hashes, "case_order": cases.map { $0.rawValue }, "source_manifest_sha256": ProcessInfo.processInfo.environment["MONITOR_SOURCE_MANIFEST_SHA256"] ?? "uncaptured",
    "binary_sha256": ProcessInfo.processInfo.environment["MONITOR_BINARY_SHA256"] ?? "uncaptured",
    "harness_sha256": ProcessInfo.processInfo.environment["MONITOR_BENCHMARK_HARNESS_SHA256"] ?? "uncaptured",
    "thermal_state_start": ProcessInfo.processInfo.thermalState.rawValue, "runs": results]
  func save() throws {
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("benchmark-receipt.json"), options: .atomic)
  }
  try save()
  for name in cases {
    let result = autoreleasepool { runCase(name, source: source, output: output, bgra: bgra) }
    results.append(result); receipt["runs"] = results; try save()
    print("PROGRESS case=\(name.rawValue) status=\(result["status"] ?? "unknown")"); fflush(stdout)
  }
  let unchanged = hashes == ["source_v210": fingerprint(source), "paired_output_bgra": fingerprint(output), "source_bgra": fingerprint(bgra)]
  let passed = unchanged && results.allSatisfy { $0["status"] as? String == "passed" }
  receipt["source_buffers_unchanged"] = unchanged
  receipt["status"] = passed ? "passed" : "failed"
  receipt["thermal_state_end"] = ProcessInfo.processInfo.thermalState.rawValue
  try save()
  try require(passed, "one or more benchmark cases failed; receipt retained")
}
do { try run() } catch { fputs("BENCHMARK FAILED: \(error)\n", stderr); exit(1) }
