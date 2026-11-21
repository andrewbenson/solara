import SolaraModel
import Testing
@testable import SolaraStore

@MainActor
@Suite(.serialized)
struct WorkspaceWritesTests {
  @Test func theWorkspaceGateKeepsSafeModeButNotAFrozenOrUnownedStore() {
    let previousOwns = NativeStoreHandle.ownsWorkspace
    let previousResolve = NativeStoreHandle.resolve
    defer {
      NativeStoreHandle.ownsWorkspace = previousOwns
      NativeStoreHandle.resolve = previousResolve
      NativeStoreHandle.thawForTests()
    }
    let owned = Store(state: BrowserState(settings: Settings.hydrated(from: nil)))
    var safeConfig = StoreConfig()
    safeConfig.safeMode = true
    let safe = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), config: safeConfig)
    NativeStoreHandle.thawForTests()
    NativeStoreHandle.resolve = { owned }
    NativeStoreHandle.ownsWorkspace = false
    #expect(WorkspaceWrites.store == nil)
    NativeStoreHandle.ownsWorkspace = true
    #expect(WorkspaceWrites.store === owned)
    NativeStoreHandle.resolve = { nil }
    #expect(WorkspaceWrites.store == nil)
    NativeStoreHandle.resolve = { safe }
    #expect(WorkspaceWrites.store === safe)
    #expect(SettingsWrites.directStore == nil)
    NativeStoreHandle.resolve = { owned }
    NativeStoreHandle.markFrozen()
    #expect(WorkspaceWrites.store == nil)
  }
}
