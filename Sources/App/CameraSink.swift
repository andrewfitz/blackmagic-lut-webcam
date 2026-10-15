import CoreMediaIO
import Foundation

// Queue-altered is a notification, not a transfer of sample ownership. CMIO's
// consumer owns the dequeued enqueue retain and releases it after use. Releasing
// the notification token here caused real installed-extension double frees.
let cameraSinkQueueAltered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }

// CMSimpleQueue does not retain its elements. Each successful enqueue owns
// exactly one retain, transferred to CMIO on dequeue or released by our stop
// drain if the sample was never consumed.
final class CameraBufferQueue {
  let queue: CMSimpleQueue

  init(_ queue: CMSimpleQueue) { self.queue = queue }
  deinit { drain() }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
    let retained = Unmanaged.passRetained(sample)
    let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
    if status != noErr { retained.release() }
    if status == kCMSimpleQueueError_QueueIsFull { return false }
    guard status == noErr else { throw VideoError.message("Send camera frame failed (\(status)).") }
    return true
  }

  // Call only after stopping the CMIO consumer. CMSimpleQueue permits one
  // producer and one consumer; draining a live consumer would violate that.
  func drain() {
    while let token = CMSimpleQueueDequeue(queue) {
      Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
    }
  }
}

// DeckLink's borrowed v210 capture buffers are not necessarily IOSurfaces.
// CMIO's interprocess transport requires shareable storage, so stage raw bytes
// without changing format, quantizing pixels or losing sample metadata.
final class CameraFrameStager {
  private var pool: CVPixelBufferPool?
  private var dimensions: (Int, Int, OSType)?
  private var prepared = false
  private lazy var gpuCopy = GPURawFrameCopy()
  private var cachedFormat: (source: CMVideoFormatDescription, stride: Int, staged: CMVideoFormatDescription)?
#if CAPTURE_LIFECYCLE_TESTS
  private(set) var lastRawCopyTiming: GPURawFrameCopy.Timing?
#endif

  // Call on the same serial owner as stage, before capture begins or before
  // delivering the first retained frame of a new layout. Holding three images
  // together forces actual bounded pool allocation rather than recycling one
  // image three times. Mapping initializes the layout without changing pixels.
  func prepare(width: Int, height: Int, pixelFormat: OSType) throws {
    let pool = try configurePool(width: width, height: height, type: pixelFormat)
    guard !prepared else { return }
    if pixelFormat == kCVPixelFormatType_422YpCbCr10 { _ = gpuCopy }
    var warmImages: [CVPixelBuffer] = []
    warmImages.reserveCapacity(VideoContract.warmBufferCount)
    for _ in 0..<VideoContract.warmBufferCount {
      var image: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
        [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &image)
      // Existing active frames may already occupy a warmed pool. Preparing it
      // must not turn ordinary transport backpressure into a fatal start error.
      if status == kCVReturnWouldExceedAllocationThreshold { break }
      guard status == kCVReturnSuccess, let image, CVPixelBufferGetIOSurface(image) != nil else {
        throw VideoError.message("Cannot prepare shareable camera image (\(status)).")
      }
      let lockStatus = CVPixelBufferLockBaseAddress(image, [])
      guard lockStatus == kCVReturnSuccess else {
        throw VideoError.message("Cannot prepare shareable camera layout (\(lockStatus)).")
      }
      CVPixelBufferUnlockBaseAddress(image, [])
      warmImages.append(image)
    }
    withExtendedLifetime(warmImages) { prepared = true }
  }

  private func configurePool(width: Int, height: Int, type: OSType) throws -> CVPixelBufferPool {
    if dimensions?.0 != width || dimensions?.1 != height || dimensions?.2 != type {
      var next: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.warmBufferCount] as CFDictionary,
        [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
          kCVPixelBufferPixelFormatTypeKey: type,
          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &next)
      guard status == kCVReturnSuccess, let next else { throw VideoError.message("Cannot allocate shareable camera pool (\(status)).") }
      pool = next
      dimensions = (width, height, type)
      prepared = false
    }
    guard let pool else { throw VideoError.message("Camera staging pool is unavailable.") }
    return pool
  }

  func stage(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
#if CAPTURE_LIFECYCLE_TESTS
    lastRawCopyTiming = nil
#endif
    guard let input = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Camera sample has no image.") }
    try VideoBufferLayout.validate(input)
    if CVPixelBufferGetIOSurface(input) != nil { return sample }
    let width = CVPixelBufferGetWidth(input)
    let height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    let pool = try configurePool(width: width, height: height, type: type)
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &output)
    if status == kCVReturnWouldExceedAllocationThreshold { return nil }
    guard status == kCVReturnSuccess, let output, CVPixelBufferGetIOSurface(output) != nil else {
      throw VideoError.message("Cannot allocate shareable camera image (\(status)).")
    }
    // The raw Metal copier supports packed v210 only. Avoid initializing its
    // device/queue for planar formats that must take the validated row copy.
    let copiedOnGPU: Bool
    if type == kCVPixelFormatType_422YpCbCr10 {
      copiedOnGPU = try gpuCopy?.copy(input, to: output) ?? false
#if CAPTURE_LIFECYCLE_TESTS
      lastRawCopyTiming = gpuCopy?.lastTiming
#endif
    } else { copiedOnGPU = false }
    if !copiedOnGPU { try copyPixels(input, to: output, type: type, width: width) }
    return try makeStagedSample(sample, input: input, output: output, type: type, width: width, height: height)
  }

  private func copyPixels(_ input: CVPixelBuffer, to output: CVPixelBuffer,
    type: OSType, width: Int) throws {
    let height = CVPixelBufferGetHeight(input)
    guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else {
      throw VideoError.message("Cannot read captured camera image.")
    }
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else {
      throw VideoError.message("Cannot write shareable camera image.")
    }
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    guard CVPixelBufferGetPlaneCount(input) == CVPixelBufferGetPlaneCount(output) else {
      throw VideoError.message("Captured and shareable camera layouts do not match.")
    }
    if CVPixelBufferIsPlanar(input) {
      for plane in 0..<CVPixelBufferGetPlaneCount(input) {
        let rows = CVPixelBufferGetHeightOfPlane(input, plane)
        guard rows == CVPixelBufferGetHeightOfPlane(output, plane),
          let source = CVPixelBufferGetBaseAddressOfPlane(input, plane),
          let destination = CVPixelBufferGetBaseAddressOfPlane(output, plane) else {
          throw VideoError.message("Captured camera plane is unavailable.")
        }
        let bytesPerComponent = type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 2
        let rowBytes = width * bytesPerComponent
        try copyRows(source: source, sourceStride: CVPixelBufferGetBytesPerRowOfPlane(input, plane),
          destination: destination, destinationStride: CVPixelBufferGetBytesPerRowOfPlane(output, plane),
          rowBytes: rowBytes, rows: rows)
      }
    } else {
      guard type == kCVPixelFormatType_422YpCbCr10,
        let source = CVPixelBufferGetBaseAddress(input), let destination = CVPixelBufferGetBaseAddress(output) else {
        throw VideoError.message("Unsupported captured camera layout.")
      }
      // v210 stores six pixels in four 32-bit words. Row padding is not media.
      let rowBytes = ((width + 5) / 6) * 16
      try copyRows(source: source, sourceStride: CVPixelBufferGetBytesPerRow(input),
        destination: destination, destinationStride: CVPixelBufferGetBytesPerRow(output),
        rowBytes: rowBytes, rows: height)
    }
  }

  private func makeStagedSample(_ sample: CMSampleBuffer, input: CVPixelBuffer,
    output: CVPixelBuffer, type: OSType, width: Int, height: Int) throws -> CMSampleBuffer {
    CVBufferRemoveAllAttachments(output)
    for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
      if let attachments = CVBufferCopyAttachments(input, mode) { CVBufferSetAttachments(output, attachments, mode) }
    }
    var timing = CMSampleTimingInfo()
    var result: CMSampleBuffer?
    var resultStatus = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
    guard resultStatus == noErr, let format = CMSampleBufferGetFormatDescription(sample) else {
      throw VideoError.message("Captured camera timing or format is unavailable.")
    }
    // Packed format descriptions include BytesPerRow. Preserve source format
    // extensions while updating that layout field for the destination stride.
    let stride = CVPixelBufferGetBytesPerRow(output)
    let stagedFormat: CMVideoFormatDescription
    if let cachedFormat, cachedFormat.stride == stride, CFEqual(cachedFormat.source, format) {
      stagedFormat = cachedFormat.staged
    } else {
      var extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
      if !CVPixelBufferIsPlanar(output) { extensions[kCMFormatDescriptionExtension_BytesPerRow as String] = stride }
      var next: CMVideoFormatDescription?
      resultStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: type,
        width: Int32(width), height: Int32(height), extensions: extensions as CFDictionary,
        formatDescriptionOut: &next)
      guard resultStatus == noErr, let next else { throw VideoError.message("Cannot describe staged camera image (\(resultStatus)).") }
      cachedFormat = (format, stride, next)
      stagedFormat = next
    }
    resultStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: output, formatDescription: stagedFormat, sampleTiming: &timing, sampleBufferOut: &result)
    guard resultStatus == noErr, let result else { throw VideoError.message("Cannot stage camera sample (\(resultStatus)).") }
    for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
      if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: mode) {
        CMSetAttachments(result, attachments: attachments, attachmentMode: mode)
      }
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[AnyHashable: Any]],
      let destinations = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary] {
      for (destination, attachment) in zip(destinations, attachments) { destination.addEntries(from: attachment) }
    }
    return result
  }

  private func copyRows(source: UnsafeMutableRawPointer, sourceStride: Int,
    destination: UnsafeMutableRawPointer, destinationStride: Int, rowBytes: Int, rows: Int) throws {
    guard sourceStride >= rowBytes, destinationStride >= rowBytes, rows > 0 else {
      throw VideoError.message("Captured camera row stride is too short for its pixel format.")
    }
    if sourceStride == rowBytes && destinationStride == rowBytes {
      memcpy(destination, source, rowBytes * rows)
      return
    }
    for row in 0..<rows {
      let destinationRow = destination.advanced(by: row * destinationStride)
      memcpy(destinationRow, source.advanced(by: row * sourceStride), rowBytes)
      if destinationStride > rowBytes { memset(destinationRow.advanced(by: rowBytes), 0, destinationStride - rowBytes) }
    }
  }
}

final class CameraSink {
  private var deviceID: CMIODeviceID = 0
  private var streamID: CMIOStreamID = 0
  private var queue: CameraBufferQueue?
  private var negotiatedFormat: CMVideoFormatDescription?
  private var negotiatedDuration: CMTime?
  private var stager = CameraFrameStager()

  init(bufferQueue: CameraBufferQueue? = nil) { queue = bufferQueue }
  deinit { disconnect() }

  func connect(configuration: PipelineConfiguration, passthroughFormat: OSType) throws {
    disconnect()
    // Software camera devices are hidden from legacy CMIO clients by default.
    var address = CMIOObjectPropertyAddress(
      mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
      0, nil, UInt32(MemoryLayout.size(ofValue: allow)), &allow), "Enable software camera discovery")
    for id in try ids(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
      guard try string(id, selector: kCMIODevicePropertyDeviceUID) == VideoContract.deviceUID else { continue }
      let streams = try ids(id, selector: kCMIODevicePropertyStreams)
      let format = try VideoContract.formatDescription(width: configuration.width, height: configuration.height,
        pixelFormat: configuration.untouched ? passthroughFormat : configuration.pixelFormat)
      let namedStreams = try streams.map { ($0, try string($0, selector: kCMIOObjectPropertyName)) }
      guard let sinkStream = namedStreams.first(where: { $0.1 == VideoContract.sinkName })?.0,
        let sourceStream = namedStreams.first(where: { $0.1 == VideoContract.cameraName })?.0 else {
        throw VideoError.message("The virtual camera does not publish its source and input streams.")
      }
      // AVFoundation clients such as Zoom claim device control before starting
      // the source. In automatic mode the producer necessarily arrives later.
      // The extension can negotiate our authorized producer's sample contract
      // itself; don't require stealing another client's device-control lease.
      do {
        if !controlledByAnotherProcess(id) {
          for stream in [sinkStream, sourceStream] {
            var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyFormatDescription),
              mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
            var description = Unmanaged.passUnretained(format).toOpaque()
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil,
              UInt32(MemoryLayout<CMVideoFormatDescription>.size), &description), "Set virtual camera format")
            address.mSelector = UInt32(kCMIOStreamPropertyFrameRate)
            var rate = 1 / configuration.duration.seconds
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate),
              "Set virtual camera frame rate")
          }
        }
      } catch {
        // Also handle Zoom acquiring control between the read and setter.
        guard controlledByAnotherProcess(id) else { throw error }
      }
      var unmanaged: Unmanaged<CMSimpleQueue>?
      try check(CMIOStreamCopyBufferQueue(sinkStream, cameraSinkQueueAltered, nil, &unmanaged), "Open camera queue")
      guard let unmanaged else { throw VideoError.message("Camera queue is unavailable.") }
      queue = CameraBufferQueue(unmanaged.takeRetainedValue())
      negotiatedFormat = format
      negotiatedDuration = configuration.duration
      deviceID = id
      streamID = sinkStream
      do { try check(CMIODeviceStartStream(id, sinkStream), "Start virtual camera input") }
      catch { disconnect(); throw error }
      return
    }
    throw VideoError.message("Install and approve the UltraStudio LUT camera extension, then reconnect.")
  }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    guard let queue else { throw VideoError.message("Virtual camera is disconnected.") }
    if let negotiatedFormat, let negotiatedDuration {
      let expected = CMVideoFormatDescriptionGetDimensions(negotiatedFormat)
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      guard CMSampleBufferDataIsReady(sample), let image = CMSampleBufferGetImageBuffer(sample),
        CVPixelBufferGetWidth(image) == expected.width,
        CVPixelBufferGetHeight(image) == expected.height,
        CVPixelBufferGetPixelFormatType(image) == CMFormatDescriptionGetMediaSubType(negotiatedFormat),
        time.isNumeric, time.epoch == 0, time.seconds >= 0,
        CMSampleBufferGetDuration(sample) == negotiatedDuration else {
        throw VideoError.message("Frame does not match the virtual camera's negotiated format and timing.")
      }
    }
    guard let staged = try stager.stage(sample) else { return false }
    return try queue.send(staged)
  }

  func disconnect() {
    if streamID != 0 { CMIODeviceStopStream(deviceID, streamID) }
    queue?.drain()
    queue = nil
    negotiatedFormat = nil
    negotiatedDuration = nil
    stager = CameraFrameStager()
    deviceID = 0
    streamID = 0
  }

  private func controlledByAnotherProcess(_ device: CMIODeviceID) -> Bool {
    var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIODevicePropertyDeviceControl),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard CMIOObjectGetPropertyData(device, &property, 0, nil, size, &size, &pid) == noErr else { return false }
    return pid > 0 && pid != getpid()
  }

  private func ids(_ object: CMIOObjectID, selector: Int) throws -> [UInt32] {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(selector),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    try check(CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read camera list size")
    var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
    if values.isEmpty { return [] }
    try values.withUnsafeMutableBytes { bytes in
      try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, bytes.baseAddress!), "Read camera list")
    }
    return values
  }

  private func string(_ object: CMIOObjectID, selector: Int) throws -> String {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(selector),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &value), "Read camera name")
    return value?.takeRetainedValue() as String? ?? ""
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VideoError.message("\(operation) failed (\(status)).") }
  }
}
