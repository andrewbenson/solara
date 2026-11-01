import Foundation

@MainActor
@objc public final class NativePrivateSessionCleanup: NSObject {
  private static var workspaceOwner: String?

  static var ownsWorkspace: Bool { workspaceOwner != nil }

  @objc public static func setWorkspaceOwnership(_ owned: Bool, owner: String) {
    if owned {
      workspaceOwner = owner
    } else if workspaceOwner?.utf8.elementsEqual(owner.utf8) == true {
      workspaceOwner = nil
    }
  }
}
