import CoreMediaIO
import Foundation

// The CMIO queue owns one retain until it reports removal of that token.
private let sinkQueueAltered: CMIODeviceStreamQueueAlteredProc = { _, token, _ in
  if let token { Unmanaged<CMSampleBuffer>.fromOpaque(token).release() }
}

final class CameraSink {
  private var deviceID: CMIODeviceID = 0
  private var streamID: CMIOStreamID = 0
  private var queue: CMSimpleQueue?

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
      for stream in streams {
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
      for stream in streams {
        guard try string(stream, selector: kCMIOObjectPropertyName) == VideoContract.sinkName else { continue }
        var unmanaged: Unmanaged<CMSimpleQueue>?
        try check(CMIOStreamCopyBufferQueue(stream, sinkQueueAltered, nil, &unmanaged), "Open camera queue")
        guard let unmanaged else { throw VideoError.message("Camera queue is unavailable.") }
        queue = unmanaged.takeRetainedValue()
        deviceID = id
        streamID = stream
        do { try check(CMIODeviceStartStream(id, stream), "Start virtual camera input") }
        catch { disconnect(); throw error }
        return
      }
    }
    throw VideoError.message("Install and approve the UltraStudio LUT camera extension, then reconnect.")
  }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    guard let queue else { throw VideoError.message("Virtual camera is disconnected.") }
    guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
    let retained = Unmanaged.passRetained(sample)
    let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
    if status != noErr { retained.release() }
    if status == kCMSimpleQueueError_QueueIsFull { return false }
    try check(status, "Send camera frame")
    return true
  }

  func disconnect() {
    if streamID != 0 { CMIODeviceStopStream(deviceID, streamID) }
    if let queue {
      while let token = CMSimpleQueueDequeue(queue) {
        Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
      }
    }
    queue = nil
    deviceID = 0
    streamID = 0
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
