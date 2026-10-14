// Synthetic installed-extension IPC check. Never opens a physical camera,
// displays an image, writes media, or submits a system-extension request.
import CoreMediaIO
import Foundation
import Security

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    fputs("CMIO_SMOKE assertion: \(message)\n", stderr)
    fflush(stderr)
    throw VideoError.message(message)
  }
}

func check(_ status: OSStatus, _ operation: String) throws {
  try require(status == noErr, "\(operation) failed (\(status)).")
}

func address(_ selector: Int) -> CMIOObjectPropertyAddress {
  CMIOObjectPropertyAddress(mSelector: UInt32(selector),
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
}

func ids(_ object: CMIOObjectID, _ selector: Int) throws -> [UInt32] {
  var property = address(selector)
  var size: UInt32 = 0
  try check(CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read CMIO list size")
  try require(size % UInt32(MemoryLayout<UInt32>.size) == 0, "Invalid CMIO list size.")
  var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
  if !values.isEmpty {
    try values.withUnsafeMutableBytes {
      try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, $0.baseAddress!), "Read CMIO list")
    }
  }
  return values
}

func string(_ object: CMIOObjectID, _ selector: Int) throws -> String {
  var property = address(selector)
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, &value), "Read CMIO identity")
  return value?.takeRetainedValue() as String? ?? ""
}

func log(_ message: String) { print(message); fflush(stdout) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func pollPause() { Thread.sleep(forTimeInterval: 0.002) }

// One thread owns all dequeues, including cleanup. The notification callback
// has no state/refCon and never dequeues, avoiding a concurrent-drain race.
// Apple CMIOHardwareStream.h documents the Copy-owned queue and that a nil
// callback unregisters notifications (and may return no queue):
// https://developer.apple.com/documentation/coremediaio/cmiostreamcopybufferqueue(_:_:_:_:)
// CMSimpleQueue.h documents that payload lifetime is managed externally:
// https://developer.apple.com/documentation/coremedia/cmsimplequeue-api
// A dequeued CMIO sample transfers the producer's payload retain to this
// consumer; takeRetainedValue releases that retain after inspection.
final class SourceQueue {
  let device: CMIODeviceID
  let stream: CMIOStreamID
  let queue: CMSimpleQueue
  private var started = false
  private var closed = false
  private var closeStatus: OSStatus = noErr

  init() throws {
    guard let device = try ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
      .first(where: { try string($0, kCMIODevicePropertyDeviceUID) == VideoContract.deviceUID }),
      let stream = try ids(device, kCMIODevicePropertyStreams)
      .first(where: { try string($0, kCMIOObjectPropertyName) == VideoContract.cameraName }) else {
      throw VideoError.message("Installed synthetic target/source was not discovered.")
    }
    self.device = device
    self.stream = stream
    var copied: Unmanaged<CMSimpleQueue>?
    try check(CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &copied), "Copy source queue")
    guard let copied else { throw VideoError.message("Source queue is unavailable.") }
    queue = copied.takeRetainedValue()
    try check(CMIODeviceStartStream(device, stream), "Start installed camera source")
    started = true
    log("CMIO_SMOKE sourceStarted device=\(device) stream=\(stream) queueCapacity=\(CMSimpleQueueGetCapacity(queue))")
  }

  func next() -> CMSampleBuffer? {
    guard let token = CMSimpleQueueDequeue(queue) else { return nil }
    return Unmanaged<CMSampleBuffer>.fromOpaque(token).takeRetainedValue()
  }

  @discardableResult
  func stop() -> OSStatus {
    guard !closed else { return closeStatus }
    closed = true
    if started {
      let status = CMIODeviceStopStream(device, stream)
      log("CMIO_SMOKE sourceStop=\(status)")
      closeStatus = status
      started = false
    }
    var copied: Unmanaged<CMSimpleQueue>?
    let status = CMIOStreamCopyBufferQueue(stream, nil, nil, &copied)
    log("CMIO_SMOKE sourceUnregister=\(status)")
    if closeStatus == noErr { closeStatus = status }
    if let copied { _ = copied.takeRetainedValue() }
    // Stopped stream; release each remaining producer-owned sample once.
    for _ in 0..<CMSimpleQueueGetCapacity(queue) {
      guard let sample = next() else { break }
      withExtendedLifetime(sample) {}
    }
    return closeStatus
  }

  deinit { stop() }
}

struct SyntheticMode {
  let width: Int
  let height: Int
  let format: OSType
  var black: UInt16 { format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 64 }

  func row(marker: UInt16, plane: Int) -> [UInt8] {
    if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
      return [UInt8](repeating: plane == 0 ? UInt8(marker) : 128, count: width)
    }
    if format == kCVPixelFormatType_422YpCbCr10 {
      let y = UInt32(marker), c: UInt32 = 512
      let group = [c | (y << 10) | (c << 20), y | (c << 10) | (y << 20),
        c | (y << 10) | (c << 20), y | (c << 10) | (y << 20)]
      let words = (0..<(width / 6 * 4)).map { group[$0 % 4] }
      return words.withUnsafeBytes { Array($0) }
    }
    // Adjacent ten-bit luma codes deliberately exercise the lower two bits
    // that an accidental eight-bit transport would lose.
    let words = [UInt16](repeating: (plane == 0 ? marker : 512) << 6, count: width)
    return words.withUnsafeBytes { Array($0) }
  }
}

func makePool(_ mode: SyntheticMode) throws -> CVPixelBufferPool {
  var pool: CVPixelBufferPool?
  let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
    [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.warmBufferCount] as CFDictionary,
    [kCVPixelBufferWidthKey: mode.width, kCVPixelBufferHeightKey: mode.height,
      kCVPixelBufferPixelFormatTypeKey: mode.format,
      kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
  try require(status == kCVReturnSuccess && pool != nil, "Cannot allocate bounded synthetic pool (\(status)).")
  return pool!
}

func image(marker: UInt16, pool: CVPixelBufferPool, mode: SyntheticMode) throws -> CVPixelBuffer {
  var created: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
    [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &created)
  try require(status == kCVReturnSuccess && created != nil, "Cannot allocate synthetic IOSurface (\(status)).")
  let result = created!
  try require(CVPixelBufferGetIOSurface(result) != nil, "Synthetic image is not shareable.")
  try check(CVPixelBufferLockBaseAddress(result, []), "Lock synthetic image")
  defer { CVPixelBufferUnlockBaseAddress(result, []) }
  let planes = CVPixelBufferIsPlanar(result) ? CVPixelBufferGetPlaneCount(result) : 1
  for plane in 0..<planes {
    let planar = CVPixelBufferIsPlanar(result)
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(result, plane) : CVPixelBufferGetBaseAddress(result) else {
      throw VideoError.message("Synthetic plane is absent.")
    }
    let rows = planar ? CVPixelBufferGetHeightOfPlane(result, plane) : mode.height
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(result, plane) : CVPixelBufferGetBytesPerRow(result)
    let reference = mode.row(marker: marker, plane: plane)
    try require(stride >= reference.count, "Synthetic stride is shorter than active pixels.")
    memset(base, 0, stride * rows)
    reference.withUnsafeBytes { expected in
      for row in 0..<rows { memcpy(base.advanced(by: row * stride), expected.baseAddress!, reference.count) }
    }
  }
  return result
}

func inspect(_ sample: CMSampleBuffer, duration: CMTime, mode: SyntheticMode) throws -> UInt16 {
  try require(CMSampleBufferDataIsReady(sample), "Received unready sample.")
  guard let image = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Received no image.") }
  try VideoBufferLayout.validate(image)
  try require(CVPixelBufferGetWidth(image) == mode.width && CVPixelBufferGetHeight(image) == mode.height &&
    CVPixelBufferGetPixelFormatType(image) == mode.format,
    "Installed camera changed synthetic dimensions or color format.")
  try require(CMSampleBufferGetDuration(sample) == duration, "Installed camera changed frame duration.")
  try check(CVPixelBufferLockBaseAddress(image, .readOnly), "Lock received synthetic image")
  defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
  let planar = CVPixelBufferIsPlanar(image)
  guard let luma = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image) else {
    throw VideoError.message("Received no luma.")
  }
  let marker: UInt16
  if mode.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { marker = UInt16(luma.load(as: UInt8.self)) }
  else if planar { marker = luma.load(as: UInt16.self) >> 6 }
  else { marker = UInt16((luma.load(as: UInt32.self) >> 10) & 1023) }
  let planes = planar ? CVPixelBufferGetPlaneCount(image) : 1
  for plane in 0..<planes {
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, plane) : CVPixelBufferGetBaseAddress(image) else {
      throw VideoError.message("Received no plane.")
    }
    let rows = planar ? CVPixelBufferGetHeightOfPlane(image, plane) : mode.height
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, plane) : CVPixelBufferGetBytesPerRow(image)
    let reference = mode.row(marker: marker, plane: plane)
    try reference.withUnsafeBytes { expected in
      for row in 0..<rows {
        try require(memcmp(base.advanced(by: row * stride), expected.baseAddress!, reference.count) == 0,
          "Synthetic active pixels changed in plane \(plane), row \(row).")
      }
    }
  }
  return marker
}

func smoke() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  try require(arguments == ["--run"] || arguments == ["--run", "--full"],
    "Pass --run (optionally --full) to perform the synthetic installed-camera check.")
  // CMIO's synchronous IPC APIs have no per-call timeout. Bound even a stalled
  // service call with a process-local watchdog; normal paths stop both streams.
  DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60) {
    fputs("CMIO_SMOKE FAIL 60-second process watchdog expired.\n", stderr)
    _exit(124)
  }
  var code: SecCode?
  try check(SecCodeCopySelf([], &code), "Read helper signature")
  var requirement: SecRequirement?
  try check(SecRequirementCreateWithString("identifier \"org.ultrastudiolut.app\"" as CFString, [], &requirement), "Create helper signing requirement")
  try check(SecCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate), requirement), "Validate helper signature and producer identifier")
  var staticCode: SecStaticCode?
  try check(SecCodeCopyStaticCode(code!, [], &staticCode), "Read helper static code")
  var signing: CFDictionary?
  try check(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &signing), "Read helper signing identifier")
  let identifier = (signing as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
  try require(identifier == "org.ultrastudiolut.app", "Helper must be signed as the authorized synthetic producer.")
  log("CMIO_SMOKE begin pid=\(ProcessInfo.processInfo.processIdentifier) signingID=\(identifier!) syntheticOnly=true")
  let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Bounded synthetic camera IPC verification")
  defer { ProcessInfo.processInfo.endActivity(activity) }
  var modes = [SyntheticMode(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
  if arguments.contains("--full") {
    modes += [SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
      SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)]
  }
  for mode in modes {
    let pool = try makePool(mode)
    try runCase(fast: false, pool: pool, mode: mode)
    try runCase(fast: true, pool: pool, mode: mode)
  }
}

func runCase(fast: Bool, pool: CVPixelBufferPool, mode: SyntheticMode) throws {
  let duration = fast ? VideoContract.fastDuration : VideoContract.slowDuration
  let fps = fast ? "60000/1001" : "30000/1001"
  log("CMIO_SMOKE case size=\(mode.width)x\(mode.height) format=\(VideoContract.fourCC(mode.format)) fps=\(fps)")
  let sink = CameraSink()
  defer { sink.disconnect(); log("CMIO_SMOKE producerDisconnected") }
  var configuration = PipelineConfiguration()
  configuration.inputFast = fast
  configuration.downscale = mode.width == 1920
  configuration.convertTo420 = mode.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  let discoveryDeadline = now() + 5
  var connected = false
  var lastError = ""
  repeat {
    do {
      try sink.connect(configuration: configuration, passthroughFormat: mode.format)
      connected = true
      break
    } catch {
      lastError = error.localizedDescription
      // Discovery can lag extension activation. Authorization, negotiation and
      // stream-start errors require investigation, not repeated OS requests.
      guard lastError.hasPrefix("Install and approve") else { throw error }
      Thread.sleep(forTimeInterval: 0.1)
    }
  } while now() < discoveryDeadline
  try require(connected, "Producer connection deadline: \(lastError)")
  log("CMIO_SMOKE producerConnected")
  let source = try SourceQueue()
  defer { source.stop() }
  let factory = VideoSampleFactory()
  let hostClock = CMClockGetHostTimeClock()
  let warm = try factory.sample(image(marker: 63, pool: pool, mode: mode), at: CMClockGetTime(hostClock), duration: duration)
  let warmSent = try sink.send(warm)
  try require(warmSent, "Warmup producer queue is full.")
  let warmDeadline = now() + 3
  var warmReceived = false
  var standby = 0
  repeat {
    if let sample = source.next() {
      let marker = try inspect(sample, duration: duration, mode: mode)
      if marker == 63 { warmReceived = true; break }
      try require(marker == mode.black, "Unexpected preflight marker \(marker).")
      standby += 1
    } else { pollPause() }
  } while now() < warmDeadline
  try require(warmReceived, "No synthetic warmup returned through installed extension within 3 seconds.")
  log("CMIO_SMOKE warmupReceived standby=\(standby)")
  let count = 60
  let epoch = CMTimeConvertScale(CMClockGetTime(hostClock), timescale: 60_000, method: .default)
  let start = now()
  var received = 0
  var sent = 0
  var retries = 0
  var previous: CMTime?
  func consume() throws {
    while let sample = source.next() {
      let marker = try inspect(sample, duration: duration, mode: mode)
      if marker == 63 { continue }
      try require(received < sent, "Received an unsent or duplicate synthetic frame.")
      try require(marker == UInt16(64 + received), "Synthetic marker order/count mismatch: expected \(64 + received), received \(marker).")
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      let expected = CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(received)))
      try require(time.isNumeric && time.epoch == 0 && time == expected, "Installed camera changed producer timestamp for marker \(marker).")
      if let previous { try require(CMTimeSubtract(time, previous) == duration, "Output cadence differs from the negotiated rational duration.") }
      previous = time
      received += 1
    }
  }
  for index in 0..<count {
    let deadline = start + Double(index) * duration.seconds
    while now() < deadline { try consume(); pollPause() }
    let sample = try factory.sample(image(marker: UInt16(64 + index), pool: pool, mode: mode),
      at: CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(index))), duration: duration)
    let sendDeadline = now() + 0.25
    while try !sink.send(sample) {
      retries += 1
      try consume()
      try require(now() < sendDeadline, "Producer queue remained full for 250 milliseconds.")
      pollPause()
    }
    sent += 1
    try consume()
  }
  let finalDeadline = now() + 3
  while received < count && now() < finalDeadline { try consume(); pollPause() }
  try require(received == count, "Consumer deadline: received \(received) of \(count) synthetic frames.")
  try check(source.stop(), "Stop and unregister synthetic consumer")
  log("CMIO_SMOKE PASS sent=\(sent) received=\(received) size=\(mode.width)x\(mode.height) format=\(VideoContract.fourCC(mode.format)) fps=\(fps) exactPixels=true exactPTS=true retries=\(retries)")
}

do { try smoke() }
catch { fputs("CMIO_SMOKE FAIL \(error.localizedDescription)\n", stderr); exit(1) }
