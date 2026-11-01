import Foundation
import Testing

@Suite(.serialized) @MainActor
struct PrivateSessionOwnershipTests {
  @Test func deferredOldOwnerReleaseCannotRetireReplacementOwnership() {
    let oldOwner = UUID().uuidString
    let replacementOwner = UUID().uuidString
    NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: oldOwner)
    NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: replacementOwner)
    defer { NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: replacementOwner) }
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: oldOwner)
    #expect(NativePrivateSessionCleanup.ownsWorkspace)
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: replacementOwner)
    #expect(!NativePrivateSessionCleanup.ownsWorkspace)
  }

  @Test func ownershipTokensKeepByteExactIdentities() {
    let owner = "caf\u{e9}"
    let other = "cafe\u{301}"
    NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: owner)
    defer { NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: owner) }
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: other)
    #expect(NativePrivateSessionCleanup.ownsWorkspace)
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: owner)
    #expect(!NativePrivateSessionCleanup.ownsWorkspace)
  }
}
