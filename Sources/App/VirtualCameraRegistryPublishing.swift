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

    // A valid previous snapshot from another app-group cannot be used as a
    // generation source.  This also makes tests and first launch deterministic
    // when the local-development group changes.
    let currentGeneration = previous?.appGroupIdentifier == appGroupIdentifier
      ? (previous?.generation ?? 0) : 0
    return VirtualCameraRegistrySnapshot(
      generation: currentGeneration == UInt64.max ? UInt64.max : currentGeneration + 1,
      appGroupIdentifier: appGroupIdentifier,
      devices: devices)
  }
}

