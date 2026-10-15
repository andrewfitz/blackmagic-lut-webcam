@preconcurrency import CoreMedia
@preconcurrency import CoreMediaIO
import CoreVideo
import IOKit.audio
import Foundation
import os
#if UDL_LOCAL_DEVELOPMENT
import Security
#endif

enum CameraProducerAuthorization {
  static let identifier = "org.ultrastudiolut.app"

  static func allows(signingID: String?, pid: pid_t, verifyLocalProcess: (pid_t) -> Bool) -> Bool {
    if signingID == identifier { return true }
#if UDL_LOCAL_DEVELOPMENT
    // CMIO reports the literal "unknown" for an ad-hoc producer on macOS 27.
    // Verify that particular running process instead of trusting the placeholder.
    guard signingID == nil || signingID == "unknown", pid > 0 else { return false }
    return verifyLocalProcess(pid)
#else
    return false
#endif
  }

#if UDL_LOCAL_DEVELOPMENT
  static func verifyRunningProcess(pid: pid_t, reportPhase: (String) -> Void = { _ in }) -> OSStatus {
    guard pid > 0 else { return errSecParam }
    var requirement: SecRequirement?
    let creation = SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
    reportPhase("identifier requirement")
    guard creation == errSecSuccess, let requirement else { return creation == errSecSuccess ? errSecParam : creation }
    var code: SecCode?
    // Apple's public dynamic-code attribute asks Security for the running
    // process's signature representation rather than opening its executable.
    // This avoids file access outside the camera extension's sandbox.
    // https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/cskernel.cpp
    let lookup = SecCodeCopyGuestWithAttributes(nil,
      [kSecGuestAttributePid: NSNumber(value: pid), kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &code)
    reportPhase("running signature lookup")
    guard lookup == errSecSuccess, let code else { return lookup == errSecSuccess ? errSecCSNoSuchCode : lookup }
    // Check the dynamic code's validity and identifier together. A missing,
    // terminated, unsigned or differently signed process fails closed. Nothing
    // is cached by PID across requests or CMIO client lifetimes.
    reportPhase("running signature verification")
    return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
  }
#endif
}

typealias CameraSampleCompletion = @Sendable (CMSampleBuffer?, UInt64,
  CMIOExtensionStream.DiscontinuityFlags, Bool, Error?) -> Void
typealias CameraSampleRequest = (@escaping CameraSampleCompletion) -> Void

// Provider API calls, resource state and timers live on this serial queue.
// Transport injection permits the actual stream lifecycle to run in-process;
// tests never register or install the unsigned system extension.
final class CameraDeviceRuntime: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
  let queue = DispatchQueue(label: "org.ultrastudiolut.camera")
  private(set) var descriptor: VirtualCameraDescriptor
  var onDemandChange: (() -> Void)?
  var provider: CMIOExtensionProvider!
  var device: CMIOExtensionDevice!
  let deviceSource = CameraDeviceSource()
  var source: CameraStream!
  var sink: CameraStream!
  private(set) var activeIndex = 0
  private(set) var duration = VideoContract.fastDuration
  private(set) var latest: CVPixelBuffer?
  private(set) var receivedAt: CMTime = .invalid
  var consumers = 0
  private var black: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var lastOutput: CMTime = .invalid
  private var nextStandby: CMTime = .invalid
  private var wasStandby = true
  let automaticTimers: Bool
  let clock: () -> CMTime
  private let output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)?
  let logger = Logger(subsystem: VideoContract.extensionID, category: "camera")
  private(set) var formats: [CMIOExtensionStreamFormat] = []

  init(automaticTimers: Bool = true, createNativeProvider: Bool = true,
    clock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
    output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)? = nil,
    descriptor: VirtualCameraDescriptor = .feed(feedID: "default")) {
    self.descriptor = descriptor
    self.automaticTimers = automaticTimers
    self.clock = clock
    self.output = output
    super.init()
    do {
      for (width, height) in [(1920, 1080), (3840, 2160)] {
        for type in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] + VideoContract.tenBit422 {
          let description = try VideoContract.formatDescription(width: width, height: height, pixelFormat: type)
          formats.append(CMIOExtensionStreamFormat(formatDescription: description,
            maxFrameDuration: VideoContract.slowDuration, minFrameDuration: VideoContract.fastDuration,
            validFrameDurations: [VideoContract.slowDuration, VideoContract.fastDuration]))
        }
      }
      // CMIOExtensionProvider is a process singleton. In-process tests create
      // native streams/devices but omit a second native provider registration.
      if createNativeProvider { provider = CMIOExtensionProvider(source: self, clientQueue: queue) }
      device = CMIOExtensionDevice(localizedName: descriptor.displayName,
        deviceID: Self.deviceUUID(for: descriptor.id),
        legacyDeviceID: descriptor.deviceUID, source: deviceSource)
      source = CameraStream(owner: self, isSink: false, descriptor: descriptor)
      sink = CameraStream(owner: self, isSink: true, descriptor: descriptor)
      try device.addStream(source.stream)
      try device.addStream(sink.stream)
      if let provider { try provider.addDevice(device) }
    } catch { fatalError("Cannot publish virtual camera: \(error)") }
  }

  deinit { timer?.cancel() }

  func updateDescriptor(_ descriptor: VirtualCameraDescriptor) {
    precondition(descriptor.id == self.descriptor.id, "Cannot change a published camera identity")
    self.descriptor = descriptor
  }

  static func deviceUUID(for identity: String) -> UUID {
    deterministicUUID(for: identity)
  }

  static func streamUUID(for identity: String) -> UUID {
    deterministicUUID(for: identity)
  }

  private static func deterministicUUID(for identity: String) -> UUID {
    // UUID fields only accept 128 bits while registry identities are strings.
    // A pair of FNV-1a rounds gives a stable, process-independent mapping.
    var first: UInt64 = 0xcbf29ce484222325
    var second: UInt64 = 0x84222325cbf29ce4
    for byte in identity.utf8 {
      first ^= UInt64(byte); first &*= 0x100000001b3
      second ^= UInt64(byte &+ 0x9d); second &*= 0x100000001b3
    }
    var bytes = withUnsafeBytes(of: first.bigEndian) { Array($0) }
    bytes += withUnsafeBytes(of: second.bigEndian) { Array($0) }
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let uuid = bytes.map { String(format: "%02x", $0) }
    let text = "\(uuid[0])\(uuid[1])\(uuid[2])\(uuid[3])\(uuid[4])\(uuid[5])\(uuid[6])\(uuid[7])-\(uuid[8])\(uuid[9])-\(uuid[10])\(uuid[11])-\(uuid[12])\(uuid[13])-\(uuid[14])\(uuid[15])\(uuid[16])\(uuid[17])\(uuid[18])\(uuid[19])\(uuid[20])\(uuid[21])\(uuid[22])\(uuid[23])\(uuid[24])\(uuid[25])\(uuid[26])\(uuid[27])\(uuid[28])\(uuid[29])\(uuid[30])\(uuid[31])"
    return UUID(uuidString: text)!
  }

  var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
  func connect(to client: CMIOExtensionClient) throws {}
  func disconnect(from client: CMIOExtensionClient) {
    // CMIO can hand the source a different wrapper instance for the same
    // client over its lifetime.  Ownership follows clientID, not NSObject
    // identity.  A disconnected source client must release its demand or the
    // provider will keep capture and its timers alive indefinitely.
    sink.disconnect(from: client)
    source.disconnect(from: client)
  }
  func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
    let result = CMIOExtensionProviderProperties(dictionary: [:])
    result.manufacturer = "UltraStudio LUT"
    return result
  }
  func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}

  func setProperties(index: Int?, frameDuration: CMTime?, fromProducer: Bool = false) throws {
    let nextIndex = index ?? activeIndex
    guard formats.indices.contains(nextIndex) else { throw VideoError.message("Unsupported camera format.") }
    let nextDuration: CMTime
    if let requested = frameDuration {
      guard requested.isNumeric, requested.epoch == 0 else { throw VideoError.message("Use 29.97 or 59.94 fps.") }
      if abs(requested.seconds - VideoContract.slowDuration.seconds) < 0.000001 {
        nextDuration = VideoContract.slowDuration
      } else if abs(requested.seconds - VideoContract.fastDuration.seconds) < 0.000001 {
        nextDuration = VideoContract.fastDuration
      } else { throw VideoError.message("Use 29.97 or 59.94 fps.") }
    } else { nextDuration = duration }
    // Validate the complete request before modifying either property. The host
    // selects the common source/sink contract before starting the producer.
    guard fromProducer || !sink.consuming || (nextIndex == activeIndex && nextDuration == duration) else {
      throw VideoError.message("Stop capture in UltraStudio LUT before changing the output format or frame rate.")
    }
    var changes: [CMIOExtensionProperty: CMIOExtensionPropertyState<AnyObject>] = [:]
    if nextIndex != activeIndex {
      activeIndex = nextIndex
      latest = nil
      receivedAt = .invalid
      black = nil
      changes[.streamActiveFormatIndex] = CMIOExtensionPropertyState(value: NSNumber(value: nextIndex))
    }
    if nextDuration != duration {
      duration = nextDuration
      changes[.streamFrameDuration] = CMIOExtensionPropertyState(value: CMTimeCopyAsDictionary(nextDuration, allocator: kCFAllocatorDefault))
    }
    if !changes.isEmpty {
      source.stream.notifyPropertiesChanged(changes)
      sink.stream.notifyPropertiesChanged(changes)
      // Producer negotiation can change the cadence while the sink pull loop
      // is active.  Re-arm that loop so it does not continue polling at the
      // previous rate after a 29.97/59.94 transition.
      sink.restartConsumptionTimer()
      restartTimer()
    }
  }

  func restartTimer() {
    timer?.cancel()
    timer = nil
    nextStandby = .invalid
    guard consumers > 0 else {
      lastOutput = .invalid
      // A new source client starts a fresh output segment.  Mark its first
      // live frame as a discontinuity even when the producer stayed running
      // while the previous viewer disconnected.
      wasStandby = true
      black = nil
      return
    }
    guard automaticTimers else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.emitStandby() }
    self.timer = timer
    timer.resume()
  }

  // Live frames already have the selected capture cadence. Forward them once,
  // preserving metadata and timestamps, instead of sampling latest on another
  // free-running clock (which duplicates and drops live frames).
  @discardableResult
  func receive(_ sample: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags,
    producerCanNegotiate: Bool = false) -> Bool {
    guard CMSampleBufferDataIsReady(sample), let image = CMSampleBufferGetImageBuffer(sample) else { return false }
    guard (try? VideoBufferLayout.validate(image)) != nil else { return false }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    let sampleDuration = CMSampleBufferGetDuration(sample)
    guard time.isNumeric, time.epoch == 0, time.seconds >= 0,
      sampleDuration.isNumeric, sampleDuration.epoch == 0 else { return false }
    let expected = formats[activeIndex].formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(expected)
    if CVPixelBufferGetWidth(image) != dimensions.width || CVPixelBufferGetHeight(image) != dimensions.height ||
      CVPixelBufferGetPixelFormatType(image) != CMFormatDescriptionGetMediaSubType(expected) ||
      abs(sampleDuration.seconds - duration.seconds) >= 0.000001 {
      // Only the signature-authorized sink client can establish its output
      // contract from a frame. This handles a camera app already holding CMIO
      // device control when the producer starts. Generic ingress stays strict.
      guard producerCanNegotiate, let index = formats.firstIndex(where: {
        let description = $0.formatDescription
        let size = CMVideoFormatDescriptionGetDimensions(description)
        return size.width == CVPixelBufferGetWidth(image) && size.height == CVPixelBufferGetHeight(image) &&
          CMFormatDescriptionGetMediaSubType(description) == CVPixelBufferGetPixelFormatType(image)
      }) else { return false }
      do { try setProperties(index: index, frameDuration: sampleDuration, fromProducer: true) }
      catch { return false }
    }
    latest = image
    receivedAt = clock()
    nextStandby = .invalid
    guard consumers > 0 else { return true }
    do {
      var outgoing = sample
      var flags = discontinuity
      if wasStandby { flags.insert(.time) }
      // A queued capture frame may predate the last standby frame on recovery.
      // Repair only that boundary; live frames keep their producer timestamps.
      if lastOutput.isNumeric, CMTimeCompare(time, lastOutput) <= 0 {
        let now = clock()
        let adjusted = CMTimeCompare(now, lastOutput) > 0 ? now : CMTimeAdd(lastOutput, duration)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: adjusted, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
          sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw VideoError.message("Cannot repair source timestamp (\(status)).") }
        outgoing = copy
        flags.insert(.time)
      }
      wasStandby = false
      send(outgoing, discontinuity: flags)
      return true
    } catch {
      logger.error("Camera output failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func clearInput() {
    latest = nil
    receivedAt = .invalid
    nextStandby = .invalid
  }

  func emitStandby() {
    guard consumers > 0 else { return }
    let now = clock()
    guard now.isNumeric else { return }
    if receivedAt.isNumeric, CMTimeSubtract(now, receivedAt).seconds < 0.5 { return }
    do {
      latest = nil
      if black == nil { black = try makeBlack() }
      guard let black else { return }
      if !nextStandby.isNumeric {
        nextStandby = CMTimeConvertScale(now, timescale: 60_000, method: .roundTowardZero)
      }
      if lastOutput.isNumeric, CMTimeCompare(nextStandby, lastOutput) <= 0 {
        nextStandby = CMTimeAdd(lastOutput, duration)
      }
      guard CMTimeCompare(now, nextStandby) >= 0 else { return }
      // Skip late timer slots instead of bursting queued standby frames.
      let lateness = CMTimeSubtract(now, nextStandby).seconds
      if lateness >= duration.seconds {
        let missed = Int32(min(floor(lateness / duration.seconds), Double(Int32.max)))
        nextStandby = CMTimeAdd(nextStandby, CMTimeMultiply(duration, multiplier: missed))
      }
      let sample = try VideoContract.sample(black, at: nextStandby, duration: duration)
      send(sample, discontinuity: wasStandby ? [] : [.time])
      wasStandby = true
      nextStandby = CMTimeAdd(nextStandby, duration)
    } catch { logger.error("Camera output failed: \(error.localizedDescription, privacy: .public)") }
  }

  private func send(_ sample: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags) {
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    lastOutput = time
    let nanoseconds = UInt64(max(0, CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value))
    if let output { output(sample, discontinuity, nanoseconds) }
    else { source.stream.send(sample, discontinuity: discontinuity, hostTimeInNanoseconds: nanoseconds) }
  }

  private func makeBlack() throws -> CVPixelBuffer {
    let description = formats[activeIndex].formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let type = CMFormatDescriptionGetMediaSubType(description)
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(dimensions.width), Int(dimensions.height), type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else { throw VideoError.message("Cannot allocate standby image.") }
    guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw VideoError.message("Cannot fill standby image.") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    if CVPixelBufferIsPlanar(result) {
      for plane in 0..<CVPixelBufferGetPlaneCount(result) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { continue }
        let length = CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane)
        if type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
          memset(base, plane == 0 ? 16 : 128, length)
        } else {
          let value: UInt16 = plane == 0 ? (type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 0 : 64 << 6) : 512 << 6
          base.assumingMemoryBound(to: UInt16.self).initialize(repeating: value, count: length / 2)
        }
      }
    } else if let base = CVPixelBufferGetBaseAddress(result) {
      let count = CVPixelBufferGetBytesPerRow(result) * CVPixelBufferGetHeight(result) / 4
      let words = base.assumingMemoryBound(to: UInt32.self)
      let pattern: [UInt32] = [512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20),
        512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20)]
      for i in 0..<count { words[i] = pattern[i % 4] }
    }
    CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return result
  }
}

/// Descriptor-backed CMIO provider. Each registry descriptor owns an independent
/// runtime, stream pair, demand lease and producer owner. The old single-feed
/// properties below delegate to the first published device for compatibility
/// with the existing app while callers migrate to `runtime(for:)`.
final class CameraProvider: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
  let queue = DispatchQueue(label: "org.ultrastudiolut.camera.registry")
  var provider: CMIOExtensionProvider!
  private(set) var snapshot: VirtualCameraRegistrySnapshot
  private(set) var descriptors: [VirtualCameraDescriptor]
  private var runtimes: [String: CameraDeviceRuntime] = [:]
  private var pendingRemoval: Set<String> = []
  private let automaticTimers: Bool
  private let clock: () -> CMTime
  private let output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)?
  let logger = Logger(subsystem: VideoContract.extensionID, category: "camera.registry")

  init(automaticTimers: Bool = true, createNativeProvider: Bool = true,
    clock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
    output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)? = nil,
    registrySnapshot: VirtualCameraRegistrySnapshot? = nil,
    registryStore: VirtualCameraRegistryStore? = nil,
    registry: VirtualCameraRegistrySnapshot? = nil,
    store: VirtualCameraRegistryStore? = nil) {
    self.automaticTimers = automaticTimers
    self.clock = clock
    self.output = output
    let fallback = Self.fallbackSnapshot()
    let selected = [registrySnapshot, registry, registryStore?.load(), store?.load()].compactMap { $0 }
      .first(where: { (try? $0.validate()) != nil }) ?? fallback
    self.snapshot = selected
    self.descriptors = selected.devices.filter(\.enabled)
    super.init()
    do {
      if createNativeProvider { provider = CMIOExtensionProvider(source: self, clientQueue: queue) }
      for descriptor in descriptors { try publish(descriptor) }
    } catch {
      fatalError("Cannot publish virtual camera registry: \(error)")
    }
  }

  private static func fallbackSnapshot() -> VirtualCameraRegistrySnapshot {
    let descriptor = VirtualCameraDescriptor.feed(feedID: "default", displayName: VideoContract.cameraName)
    return VirtualCameraRegistrySnapshot(generation: 0, devices: [descriptor])
  }

  /// All currently published native devices, in registry order.
  var devices: [CMIOExtensionDevice] {
    descriptors.compactMap { runtimes[$0.id]?.device }
  }

  var devicesByID: [String: CMIOExtensionDevice] {
    Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
      guard let device = runtimes[descriptor.id]?.device else { return nil }
      return (descriptor.id, device)
    })
  }

  /// Runtime lookup is identity based, so changing display names does not
  /// detach a camera client from its existing device.
  func runtime(for descriptorID: String) -> CameraDeviceRuntime? { runtimes[descriptorID] }
  func runtime(for descriptor: VirtualCameraDescriptor) -> CameraDeviceRuntime? { runtime(for: descriptor.id) }
  func device(for descriptorID: String) -> CMIOExtensionDevice? { runtimes[descriptorID]?.device }

  // Legacy one-camera aliases. They intentionally follow registry order.
  private var legacyRuntime: CameraDeviceRuntime {
    guard let id = descriptors.first?.id, let runtime = runtimes[id] else {
      fatalError("Virtual-camera registry has no enabled device")
    }
    return runtime
  }
  var device: CMIOExtensionDevice { legacyRuntime.device }
  var source: CameraStream { legacyRuntime.source }
  var sink: CameraStream { legacyRuntime.sink }
  var activeIndex: Int { legacyRuntime.activeIndex }
  var duration: CMTime { legacyRuntime.duration }
  var latest: CVPixelBuffer? { legacyRuntime.latest }
  var receivedAt: CMTime { legacyRuntime.receivedAt }
  var consumers: Int { legacyRuntime.consumers }
  var formats: [CMIOExtensionStreamFormat] { legacyRuntime.formats }

  private func publish(_ descriptor: VirtualCameraDescriptor) throws {
    try descriptor.validate()
    let runtime = CameraDeviceRuntime(automaticTimers: automaticTimers, createNativeProvider: false,
      clock: clock, output: output, descriptor: descriptor)
    runtime.onDemandChange = { [weak self, weak runtime] in
      guard let self, let runtime else { return }
      self.queue.async { self.removeIfReleased(runtime) }
    }
    runtimes[descriptor.id] = runtime
    if let provider { try provider.addDevice(runtime.device) }
  }

  private func removeIfReleased(_ runtime: CameraDeviceRuntime) {
    guard pendingRemoval.contains(runtime.descriptor.id), runtime.consumers == 0 else { return }
    pendingRemoval.remove(runtime.descriptor.id)
    if let provider { try? provider.removeDevice(runtime.device) }
    runtimes.removeValue(forKey: runtime.descriptor.id)
  }

  /// Reconcile one complete, validated registry snapshot. Existing runtimes
  /// remain in place when their identity is unchanged; removed devices stay
  /// published until their last source client disconnects.
  @discardableResult
  func reconcile(_ candidate: VirtualCameraRegistrySnapshot) throws -> VirtualCameraRegistrySnapshot {
    let next = try snapshot.applying(candidate)
    let nextDescriptors = next.devices.filter(\.enabled)
    let nextIDs = Set(nextDescriptors.map(\.id))
    for descriptor in nextDescriptors {
      pendingRemoval.remove(descriptor.id)
      if let runtime = runtimes[descriptor.id] {
        runtime.updateDescriptor(descriptor)
      } else {
        try publish(descriptor)
      }
    }
    for (id, runtime) in runtimes where !nextIDs.contains(id) {
      pendingRemoval.insert(id)
      removeIfReleased(runtime)
    }
    snapshot = next
    descriptors = nextDescriptors + descriptors.filter { descriptor in
      pendingRemoval.contains(descriptor.id) && !nextIDs.contains(descriptor.id)
    }
    return next
  }

  func reconcile(snapshot candidate: VirtualCameraRegistrySnapshot) throws {
    _ = try reconcile(candidate)
  }

  var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
  func connect(to client: CMIOExtensionClient) throws {}
  func disconnect(from client: CMIOExtensionClient) {
    for runtime in runtimes.values { runtime.disconnect(from: client) }
  }
  func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
    let result = CMIOExtensionProviderProperties(dictionary: [:])
    result.manufacturer = "UltraStudio LUT"
    return result
  }
  func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}

  func setProperties(index: Int?, frameDuration: CMTime?, fromProducer: Bool = false) throws {
    try legacyRuntime.setProperties(index: index, frameDuration: frameDuration, fromProducer: fromProducer)
  }
  func restartTimer() { legacyRuntime.restartTimer() }
  @discardableResult
  func receive(_ sample: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags,
    producerCanNegotiate: Bool = false) -> Bool {
    legacyRuntime.receive(sample, discontinuity: discontinuity, producerCanNegotiate: producerCanNegotiate)
  }
  func clearInput() { legacyRuntime.clearInput() }
  func emitStandby() { legacyRuntime.emitStandby() }
}


final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
  var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
  func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
    let result = CMIOExtensionDeviceProperties(dictionary: [:])
    result.transportType = kIOAudioDeviceTransportTypeVirtual
    result.model = "FX3 LUT camera"
    return result
  }
  func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}

final class CameraStream: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
  unowned let owner: CameraDeviceRuntime
  let isSink: Bool
  var stream: CMIOExtensionStream!
  private(set) var client: CMIOExtensionClient?
  private(set) var consuming = false
  private(set) var consumePending = false
  private var generation: UInt64 = 0
  private var timer: DispatchSourceTimer?
  private var request: CameraSampleRequest?
  private var authorizationRejections = 0
  // CMIO's stream start/stop callbacks do not carry the client argument.  The
  // authorization callback immediately preceding a start gives us the stable
  // client ID to associate with that start, allowing provider disconnect to
  // release only the departed source client's demand.
  private var pendingSourceClientIDs: [UUID] = []
  private var activeSourceClientIDs: Set<UUID> = []
  private var anonymousSourceStarts = 0

  init(owner: CameraDeviceRuntime, isSink: Bool, descriptor: VirtualCameraDescriptor) {
    self.owner = owner
    self.isSink = isSink
    super.init()
    stream = CMIOExtensionStream(localizedName: isSink ? "\(descriptor.displayName) · Sink" : descriptor.displayName,
      streamID: CameraDeviceRuntime.streamUUID(for: isSink ? descriptor.sinkStreamID : descriptor.sourceStreamID),
      direction: isSink ? .sink : .source, clockType: .hostTime, source: self)
  }
  deinit { timer?.cancel() }

  var formats: [CMIOExtensionStreamFormat] { owner.formats }
  var availableProperties: Set<CMIOExtensionProperty> {
    var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
    if !isSink { properties.insert(CMIOExtensionProperty(rawValue: VideoContract.demandProperty)) }
    if isSink { properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkEndOfData]) }
    return properties
  }
  func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
    let result = CMIOExtensionStreamProperties(dictionary: [:])
    result.activeFormatIndex = owner.activeIndex
    result.frameDuration = owner.duration
    if !isSink {
      result.setPropertyState(demandState, forProperty: CMIOExtensionProperty(rawValue: VideoContract.demandProperty))
    }
    if isSink {
      result.sinkBufferQueueSize = 3
      result.sinkBuffersRequiredForStartup = 1
      result.sinkEndOfData = 0
    }
    return result
  }
  private var demandState: CMIOExtensionPropertyState<AnyObject> {
    CMIOExtensionPropertyState(value: (owner.consumers > 0 ? "1" : "0") as NSString,
      attributes: CMIOExtensionPropertyAttributes(minValue: nil, maxValue: nil, validValues: nil, readOnly: true))
  }

  private func publishDemand() {
    stream.notifyPropertiesChanged([CMIOExtensionProperty(rawValue: VideoContract.demandProperty): demandState])
  }
  func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
    try owner.setProperties(index: properties.activeFormatIndex, frameDuration: properties.frameDuration)
  }
  func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
    if isSink {
      var verificationStatus: Int32?
      var verificationPhase = "unavailable"
      let allowed = CameraProducerAuthorization.allows(signingID: client.signingID, pid: client.pid) { pid in
#if UDL_LOCAL_DEVELOPMENT
        let status = CameraProducerAuthorization.verifyRunningProcess(pid: pid) { verificationPhase = $0 }
        verificationStatus = status
        return status == errSecSuccess
#else
        return false
#endif
      }
      guard allowed else {
        let detail = verificationStatus.map { "; local signature verification status=\($0), phase=\(verificationPhase)" } ?? ""
        logAuthorizationRejection(client, reason: "producer signing identifier does not match\(detail)")
        return false
      }
      guard self.client == nil || self.client?.clientID == client.clientID else {
        logAuthorizationRejection(client, reason: "another producer owns the sink")
        return false
      }
      self.client = client
    } else if !activeSourceClientIDs.contains(client.clientID), !pendingSourceClientIDs.contains(client.clientID) {
      pendingSourceClientIDs.append(client.clientID)
    }
    return true
  }
  private func logAuthorizationRejection(_ client: CMIOExtensionClient, reason: String) {
    // A failed host may retry; bound diagnostics for the extension's lifetime.
    guard authorizationRejections < 8 else { return }
    authorizationRejections += 1
    owner.logger.error("Camera producer rejected: pid=\(client.pid, privacy: .public), signingID=\(client.signingID ?? "<nil>", privacy: .public), reason=\(reason, privacy: .public)")
  }
  func startStream() throws {
    if isSink {
      guard let client else { throw VideoError.message("Missing camera producer.") }
      beginConsumption { [weak self] completion in
        self?.stream.consumeSampleBuffer(from: client, completionHandler: completion)
      }
    } else {
      if let clientID = pendingSourceClientIDs.first {
        pendingSourceClientIDs.removeFirst()
        activeSourceClientIDs.insert(clientID)
      } else {
        // Keep direct in-process test/control calls balanced even though
        // native CMIO starts are normally preceded by authorization.
        anonymousSourceStarts += 1
      }
      owner.consumers += 1
      // An additional viewer does not reset the clock of existing viewers.
      if owner.consumers == 1 { owner.restartTimer(); publishDemand() }
      owner.onDemandChange?()
    }
  }
  func stopStream() throws {
    if isSink { stopConsumption() }
    else {
      guard owner.consumers > 0 else {
        // A host can abandon an authorization probe without ever starting the
        // stream.  Do not let that stale authorization attach to a later
        // client's start.
        pendingSourceClientIDs.removeAll()
        return
      }
      if anonymousSourceStarts > 0 {
        anonymousSourceStarts -= 1
      } else if let clientID = activeSourceClientIDs.first {
        activeSourceClientIDs.remove(clientID)
      }
      owner.consumers = max(0, owner.consumers - 1)
      if owner.consumers == 0 { owner.restartTimer(); publishDemand() }
      owner.onDemandChange?()
    }
  }

  func disconnect(from client: CMIOExtensionClient) {
    disconnect(clientID: client.clientID)
  }

  private func disconnect(clientID: UUID) {
    if isSink {
      guard self.client?.clientID == clientID else { return }
      stopConsumption()
      return
    }
    pendingSourceClientIDs.removeAll { $0 == clientID }
    guard activeSourceClientIDs.remove(clientID) != nil else { return }
    owner.consumers = max(0, owner.consumers - 1)
    if owner.consumers == 0 { owner.restartTimer(); publishDemand() }
    owner.onDemandChange?()
  }

  func beginConsumption(_ request: @escaping CameraSampleRequest) {
    guard isSink, !consuming else { return }
    consuming = true
    consumePending = false
    generation &+= 1
    self.request = request
    restartConsumptionTimer()
  }

  func restartConsumptionTimer() {
    guard isSink, consuming, owner.automaticTimers else { return }
    timer?.cancel()
    timer = nil
    let timer = DispatchSource.makeTimerSource(queue: owner.queue)
    // Poll at twice the selected frame rate, draining ready frames immediately.
    // This bounds ingress latency without a fixed 250 Hz wakeup rate.
    timer.schedule(deadline: .now(), repeating: owner.duration.seconds / 2, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.consume() }
    self.timer = timer
    timer.resume()
  }
  func stopConsumption() {
    consuming = false
    consumePending = false
    generation &+= 1
    timer?.cancel()
    timer = nil
    request = nil
    client = nil
    owner.clearInput()
  }
  func consume() {
    guard consuming, !consumePending, let request else { return }
    consumePending = true
    let requestedGeneration = generation
    request { [weak self] sample, sequence, discontinuity, hasMore, error in
      guard let self else { return }
      // Strongly retain the immutable callback sample across asynchronous hop.
      let received = ReceivedSample(sample: sample)
      self.owner.queue.async {
        // Old callbacks must neither clear a new request nor publish old footage.
        guard self.consuming, self.generation == requestedGeneration else { return }
        self.consumePending = false
        if let sample = received.sample {
          if !self.owner.receive(sample, discontinuity: discontinuity, producerCanNegotiate: self.client != nil) {
            self.owner.logger.error("Camera input did not match the negotiated format, frame rate or timestamp.")
          }
          self.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence,
            hostTimeInNanoseconds: UInt64(max(0, CMTimeConvertScale(self.owner.clock(), timescale: 1_000_000_000, method: .default).value))))
        }
        if let error { self.owner.logger.error("Camera input failed: \(error.localizedDescription, privacy: .public)") }
        if hasMore && received.sample != nil && error == nil { self.consume() }
      }
    }
  }
}

private struct ReceivedSample: @unchecked Sendable {
  let sample: CMSampleBuffer?
}
