import Foundation

/// The app-side projection of persisted feeds into the camera-extension
/// registry.  The extension deliberately knows nothing about AppSettings or
/// FeedDescriptor; this small adapter keeps the two targets' contracts
/// independent while giving every configured feed a stable CMIO identity.
extension VirtualCameraRegistrySnapshot {
  /// Builds a complete registry snapshot for the current feed collection.
  ///
  /// Separate-camera mode publishes one descriptor per enabled feed. Program
  /// mode publishes the single program descriptor; the feed runtimes remain
  /// app-owned and are selected by the switcher. The previous generation is
  /// retained so the extension's stale-write fence works across app restarts.
  static func forFeeds(_ feeds: [FeedDescriptor], outputMode: FeedOutputMode,
                       previous: VirtualCameraRegistrySnapshot? = nil,
                       appGroupIdentifier: String = Self.defaultAppGroupIdentifier)
    -> VirtualCameraRegistrySnapshot {
    let devices: [VirtualCameraDescriptor]
    switch outputMode {
    case .separateCameras:
      devices = feeds.filter(\.enabled).map { feed in
        VirtualCameraDescriptor.feed(feedID: feed.id.rawValue,
          displayName: "UltraStudio LUT · \(feed.name)", enabled: true)
      }
    case .program:
      devices = [.program(displayName: "UltraStudio LUT · Program")]
    }

    // A previous snapshot is only a generation source when it is itself a
    // complete snapshot for this app group.  A malformed same-group value may
    // have come from a partial write or an older schema and must not advance
    // the rollback fence.
    let currentGeneration: UInt64
    if let previous, previous.appGroupIdentifier == appGroupIdentifier,
       (try? previous.validate()) != nil {
      currentGeneration = previous.generation
    } else {
      currentGeneration = 0
    }
    return VirtualCameraRegistrySnapshot(
      generation: currentGeneration == UInt64.max ? UInt64.max : currentGeneration + 1,
      appGroupIdentifier: appGroupIdentifier,
      devices: devices)
  }
}

