import CoreMediaIO
import Foundation

// Read the last complete feed registry before publishing any CMIO devices.
// The host app writes this transactionally in the shared app group, so Zoom
// enumerates one stable virtual device per enabled feed on extension launch.
let camera = CameraProvider(registryStore: VirtualCameraRegistryStore())
guard let provider = camera.provider else {
  fatalError("Camera provider was not created")
}
CMIOExtensionProvider.startService(provider: provider)
dispatchMain()
