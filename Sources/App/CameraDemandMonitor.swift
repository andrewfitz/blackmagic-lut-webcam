import CoreMediaIO
import Foundation

// Registers notifications only; it never starts a stream, allocates images,
// schedules a timer or polls the camera. All state and callbacks use main.
@MainActor
final class CameraDemandMonitor {
  private final class Listener {
    let object: CMIOObjectID
    var address: CMIOObjectPropertyAddress
    let block: CMIOObjectPropertyListenerBlock

    init(object: CMIOObjectID, address: CMIOObjectPropertyAddress, block: @escaping CMIOObjectPropertyListenerBlock) {
      self.object = object
      self.address = address
      self.block = block
    }

    deinit { _ = CMIOObjectRemovePropertyListenerBlock(object, &address, .main, block) }
  }
  private var topology: Listener?
  private var demand: Listener?
  private var enabled = false
  var onChange: ((Bool?, String?) -> Void)?

  func start() {
    guard !enabled else { return }
    enabled = true
    do {
      // CMIO requires each process to opt in to enumerating virtual cameras.
      // Do this without opening either stream (the producer normally opts in
      // during connect, which is intentionally deferred in automatic mode).
      var visibility = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
      var allow: UInt32 = 1
      try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &visibility,
        0, nil, UInt32(MemoryLayout<UInt32>.size), &allow))
      topology = try listen(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) { [weak self] in
        self?.discover()
      }
      discover()
    } catch { onChange?(nil, error.localizedDescription) }
  }

  func stop() {
    enabled = false
    remove(&demand)
    remove(&topology)
  }

  func refresh() { if enabled { discover() } }

  private func discover() {
    guard enabled else { return }
    do {
      guard let device = try ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        .first(where: { try string($0, kCMIODevicePropertyDeviceUID) == VideoContract.deviceUID }),
        let source = try ids(device, kCMIODevicePropertyStreams)
        .first(where: { try string($0, kCMIOObjectPropertyName) == VideoContract.cameraName }) else {
        throw VideoError.message("Install and enable the virtual camera to use automatic feed.")
      }
      if demand?.object != source {
        remove(&demand)
        var property = address(Int(VideoContract.demandSelector))
        guard CMIOObjectHasProperty(source, &property) else {
          throw VideoError.message("Update the installed camera extension to use automatic feed.")
        }
        // Subscribe before reading the initial state, including when enabled
        // after Zoom has already opened the camera.
        demand = try listen(source, Int(VideoContract.demandSelector)) { [weak self] in self?.readDemand() }
      }
      readDemand()
    } catch {
      remove(&demand)
      onChange?(nil, error.localizedDescription)
    }
  }

  private func readDemand() {
    guard enabled, let source = demand?.object else { return }
    do {
      let value = try string(source, Int(VideoContract.demandSelector))
      guard value == "0" || value == "1" else { throw VideoError.message("Invalid virtual camera activity state.") }
      onChange?(value == "1", nil)
    } catch { onChange?(nil, error.localizedDescription) }
  }

  private func listen(_ object: CMIOObjectID, _ selector: Int, changed: @escaping () -> Void) throws -> Listener {
    var property = address(selector)
    let block: CMIOObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { changed() } }
    try check(CMIOObjectAddPropertyListenerBlock(object, &property, .main, block))
    return Listener(object: object, address: property, block: block)
  }

  private func remove(_ listener: inout Listener?) {
    listener = nil
  }

  private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain))
  }

  private func ids(_ object: CMIOObjectID, _ selector: Int) throws -> [UInt32] {
    var property = address(selector)
    var size: UInt32 = 0
    try check(CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size))
    guard size % 4 == 0, size <= 64 * 1024 else { throw VideoError.message("Invalid camera device list.") }
    var result = [UInt32](repeating: 0, count: Int(size) / 4)
    if !result.isEmpty {
      try result.withUnsafeMutableBytes {
        try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, $0.baseAddress!))
      }
    }
    return result
  }

  private func string(_ object: CMIOObjectID, _ selector: Int) throws -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, &value))
    return value?.takeRetainedValue() as String? ?? ""
  }

  private func check(_ status: OSStatus) throws {
    guard status == noErr else { throw VideoError.message("Cannot monitor virtual camera activity (\(status)).") }
  }
}
