import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Testing

@Suite struct NativeCacheCompatibilityTests {
  @Test func legacyNativeOwnedCacheCommandsAreAcceptedWithoutWriting() throws {
    let store = Store(checksInvariants: false)
    let bridge = StoreBridge(store: store)
    let before = store.state
    let response = try JSONValue.parse(bridge.dispatch(#"[{"name":"setEarlyLaunchTab","args":[false]},{"name":"setLaunchBackdrop","args":[{"dark":true}]},{"name":"setHistoryHints","args":["default",[{"url":"https://legacy.test/","title":"Legacy"}]]},{"name":"setLastTabKeepsWindow","args":[true]}]"#, sinceRev: 0))
    #expect(response["error"] == nil)
    #expect(store.state == before)
    #expect(!store.memory.lastTabKeepsWindow)
    #expect(store.rev == 0)
  }

  @Test func legacyAudioCacheCommandDoesNotForgeAuthoritativeLive() throws {
    let store = Store(checksInvariants: false)
    let bridge = StoreBridge(store: store)
    let response = try JSONValue.parse(bridge.dispatch(#"{"name":"setPlayingAudio","args":[["tab"]]}"#, sinceRev: 0))
    #expect(response["error"] == nil)
    #expect(store.state.caches.playingAudio == ["tab"])
    #expect(store.state.live.isEmpty)
    #expect(response["patches"]?.array?.allSatisfy { $0["live"] == nil } == true)
  }
}
