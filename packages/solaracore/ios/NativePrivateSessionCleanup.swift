import Foundation

@MainActor
@objc public final class NativePrivateSessionCleanup: NSObject {
  private static var workspaceOwner: String?

  static var ownsWorkspace: Bool { workspaceOwner != nil }
  private static var generations = WebKitStoreGenerations()

  @objc public static func setWorkspaceOwnership(_ owned: Bool, owner: String) {
    if owned {
      if workspaceOwner?.utf8.elementsEqual(owner.utf8) != true { generations.removeAll() }
      workspaceOwner = owner
    } else if workspaceOwner?.utf8.elementsEqual(owner.utf8) == true {
      workspaceOwner = nil
      generations.removeAll()
    }
  }

  @objc public static func beginWebKitSession(_ session: String, generation: String) {
    generations.begin(session: session, generation: generation)
  }

  static func generation(session: String) -> String? { generations.generation(session: session) }

  @objc public static func endWebKitSession(_ session: String) {
    generations.end(session: session)
    WebKitHub.shared.endPrivateSession(session)
  }

  static func endFallbackWebKitSession(_ session: String) {
    guard workspaceOwner == nil else { return }
    endWebKitSession(session)
  }
}
