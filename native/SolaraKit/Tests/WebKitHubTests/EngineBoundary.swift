import AppKit
import Foundation
import Testing

@MainActor
enum SolaraCoreHost {
  static let safeMode = true
  static let windowSeenDidChange = Notification.Name("SolaraCoreWindowSeenDidChange")
  static func userSees(_ window: NSWindow?) -> Bool { false }
  static func activateForPictureInPicture(_ why: String) {}
}

func SolaraCoreTestHooksAllowed() -> Bool { false }

@MainActor
enum SolaraCoreEngineBridge {
  static func exports(_ name: String) -> Bool { false }
  static func call(_ name: String, profile: String, args: String?, completion: @escaping (String) -> Void) {
    Issue.record("Unexpected engine call: \(name)")
  }
}

@MainActor
enum SolaraCoreFavicons {
  static func fetch(_ url: String, profile: String, name: String?, completion: @escaping ([String: Any]?) -> Void) {
    Issue.record("Unexpected favicon fetch: \(url)")
  }
}
