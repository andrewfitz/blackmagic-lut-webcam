import Foundation

/// The app's long-lived models, shared by the scenes, the menu bar item and the
/// self-test. Created lazily on first use, so test harnesses that compile every
/// app source don't create them.
@MainActor enum UIAppEnvironment {
  static let model = AppModel()
  static let interface = UIInterfaceState()
}
