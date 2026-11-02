import Foundation
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct PrivateSessionOwnershipTests {
  @Test func deferredOldOwnerReleaseCannotRetireReplacementSession() {
    let session = "replacement-ownership-" + UUID().uuidString
    let profile = "incognito:replacement@" + session
    let oldOwner = UUID().uuidString
    let replacementOwner = UUID().uuidString
    let hub = WebKitHub.shared
    NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: oldOwner)
    NativePrivateSessionCleanup.beginWebKitSession(session, generation: "old-generation")
    NativePrivateSessionCleanup.setWorkspaceOwnership(true, owner: replacementOwner)
    NativePrivateSessionCleanup.beginWebKitSession(session, generation: "replacement-generation")
    let replacement = hub.dataStore(for: profile)
    defer {
      NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: replacementOwner)
      hub.endPrivateSession(session)
    }
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: oldOwner)
    NativePrivateSessionCleanup.endFallbackWebKitSession(session)
    #expect(NativePrivateSessionCleanup.generation(session: session) == "replacement-generation")
    #expect(hub.dataStore(for: profile) === replacement)
    NativePrivateSessionCleanup.setWorkspaceOwnership(false, owner: replacementOwner)
    NativePrivateSessionCleanup.endFallbackWebKitSession(session)
    #expect(NativePrivateSessionCleanup.generation(session: session) == nil)
    #expect(hub.dataStore(for: profile) !== replacement)
  }

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
