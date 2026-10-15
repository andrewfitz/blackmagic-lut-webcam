import CoreMediaIO
import Foundation

let camera = CameraProvider()
guard let provider = camera.provider else {
  fatalError("Camera provider was not created")
}
CMIOExtensionProvider.startService(provider: provider)
dispatchMain()
