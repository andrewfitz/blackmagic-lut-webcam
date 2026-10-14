import Foundation
import Observation
import SystemExtensions

@MainActor @Observable
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
  var status = "Camera extension has not been requested."
  var pending = false

  func install() {
    pending = true
    status = "Requesting camera extension activation…"
    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }
  func uninstall() {
    pending = true
    let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }
  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    Task { @MainActor in self.status = "Approve UltraStudio LUT in System Settings → General → Login Items & Extensions → Camera Extensions." }
  }
  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    Task { @MainActor in
      self.pending = false
      self.status = result == .completed ? "Camera extension request completed. Refresh inputs; select UltraStudio LUT in Zoom." : "Camera extension change requires a restart."
    }
  }
  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    Task { @MainActor in self.pending = false; self.status = "Camera installation failed: \(error.localizedDescription)" }
  }
  nonisolated func request(_ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
