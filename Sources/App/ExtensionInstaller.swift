import Foundation
import Observation
import Security
import SystemExtensions

struct ExtensionInstallPreflight: Sendable {
  static let entitlement = "com.apple.developer.system-extension.install"
  let developerSigned: Bool
  let hasInstallEntitlement: Bool

  var unavailableReason: String? {
    guard developerSigned, hasInstallEntitlement else {
      return "Camera installation requires a developer-signed app with the system-extension install entitlement. Capture and preview still work."
    }
    return nil
  }

  static func current() -> Self {
    // Inspect the running code, not the source entitlements plist. Security's
    // public SDK documents effective task rights and embedded signing data:
    // https://developer.apple.com/documentation/security/sectaskcopyvalueforentitlement(_:_:_:)
    var code: SecCode?
    var information: CFDictionary?
    var staticCode: SecStaticCode?
    let flags = SecCSFlags(rawValue: 0)
    let valid = SecCodeCopySelf(flags, &code) == errSecSuccess && code != nil &&
      SecCodeCheckValidity(code!, flags, nil) == errSecSuccess
    var developerSigned = false
    if valid, let code, SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let details = information as? [String: Any],
      let signatureFlags = details[kSecCodeInfoFlags as String] as? NSNumber {
      developerSigned = details[kSecCodeInfoIdentifier as String] is String &&
        (details[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false &&
        signatureFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0 &&
        (details[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty == false
    }
    var entitled = false
    if let task = SecTaskCreateFromSelf(nil),
      let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil),
      CFGetTypeID(value) == CFBooleanGetTypeID() {
      entitled = (value as? Bool) == true
    }
    return Self(developerSigned: developerSigned, hasInstallEntitlement: entitled)
  }
}

private final class ExtensionRequestIdentity: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (request: ObjectIdentifier, token: UUID)?

  func set(_ request: ObjectIdentifier) { lock.withLock { current = (request, UUID()) } }
  func clear() { lock.withLock { current = nil } }
  func token(for request: ObjectIdentifier) -> UUID? {
    lock.withLock { current?.request == request ? current?.token : nil }
  }
  func matches(_ token: UUID) -> Bool { lock.withLock { current?.token == token } }
}

@MainActor @Observable
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
  enum Change { case install, remove }

  struct Services {
    var preflight: () -> ExtensionInstallPreflight
    var makeRequest: (Change) -> OSSystemExtensionRequest
    var submit: (OSSystemExtensionRequest) -> Void

    static func live() -> Self {
      Self(preflight: { ExtensionInstallPreflight.current() }, makeRequest: { change in
        switch change {
        case .install:
          return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        case .remove:
          return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        }
      }, submit: { OSSystemExtensionManager.shared.submitRequest($0) })
    }
  }

  private(set) var status: String
  private(set) var pending = false
  private(set) var unavailableReason: String?
  var canRequestChanges: Bool { unavailableReason == nil }

  @ObservationIgnored private let services: Services
  @ObservationIgnored private var activeRequest: OSSystemExtensionRequest?
  @ObservationIgnored private var activeChange: Change?
  private nonisolated let requestIdentity = ExtensionRequestIdentity()

  override convenience init() { self.init(services: .live()) }

  init(services: Services) {
    self.services = services
    let reason = services.preflight().unavailableReason
    unavailableReason = reason
    status = reason ?? "Camera extension has not been requested."
    super.init()
  }

  func install() { requestChange(.install) }
  func uninstall() { requestChange(.remove) }

  private func requestChange(_ change: Change) {
    guard !pending else { return }
    unavailableReason = services.preflight().unavailableReason
    guard canRequestChanges else { status = unavailableReason!; return }
    let request = services.makeRequest(change)
    activeRequest = request
    activeChange = change
    requestIdentity.set(ObjectIdentifier(request))
    pending = true
    status = change == .install ? "Requesting camera extension activation…" : "Requesting camera extension removal…"
    request.delegate = self
    services.submit(request)
  }

  private func finish(_ identity: UUID, message: String) {
    guard requestIdentity.matches(identity) else { return }
    requestIdentity.clear()
    activeRequest?.delegate = nil
    activeRequest = nil
    activeChange = nil
    pending = false
    status = message
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    guard let identity = requestIdentity.token(for: ObjectIdentifier(request)) else { return }
    Task { @MainActor in
      guard self.requestIdentity.matches(identity) else { return }
      self.status = "Approve UltraStudio LUT in System Settings → General → Login Items & Extensions → Camera Extensions."
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    guard let identity = requestIdentity.token(for: ObjectIdentifier(request)) else { return }
    let completed = result == .completed
    Task { @MainActor in
      guard self.requestIdentity.matches(identity) else { return }
      let removed = self.activeChange == .remove
      self.finish(identity, message: completed ? (removed ? "Camera extension removed." :
        "Camera extension request completed. Refresh inputs; select UltraStudio LUT in Zoom.") :
        "Camera extension change requires a restart.")
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    guard let identity = requestIdentity.token(for: ObjectIdentifier(request)) else { return }
    let description = error.localizedDescription
    Task { @MainActor in self.finish(identity, message: "Camera extension change failed: \(description). Capture and preview still work.") }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    requestIdentity.token(for: ObjectIdentifier(request)) != nil ? .replace : .cancel
  }
}
