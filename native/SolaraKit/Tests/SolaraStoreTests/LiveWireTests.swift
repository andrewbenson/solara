import SolaraModel
import SolaraStore
import Testing

@Suite struct LiveWireTests {
  @Test func liveFactsRoundTripAndOlderPayloadDefaultsDiscardedToFalse() throws {
    let facts = PageLiveFacts(isLoading: true, canGoBack: true, canGoForward: true, playingAudio: true, themeColor: "blue", discarded: true)
    #expect(try PageLiveFacts(json: facts.json) == facts)
    #expect(facts.json["discarded"] == true)
    var older = facts.json
    older["discarded"] = nil
    let decoded = try PageLiveFacts(json: older)
    #expect(!decoded.discarded)
    #expect(decoded.themeColor == facts.themeColor)
    #expect(try PageLiveFacts(json: [:]) == PageLiveFacts())
    var retained = PageLive(facts: facts)
    #expect(retained.discarded)
    retained.ready()
    #expect(!retained.discarded)
    #expect(retained.facts?.discarded == false)
    #expect(PageLive(discarded: true).facts?.discarded == true)
  }

  @Test func liveOnlyChangesProduceFactUpsertsAndRemovals() {
    var before = BrowserState()
    before.live = ["removed": PageLiveFacts(playingAudio: true), "kept": PageLiveFacts()]
    var after = before
    after.live["removed"] = nil
    after.live["kept"] = PageLiveFacts(isLoading: true, discarded: true)
    after.live["added"] = PageLiveFacts(canGoBack: true)
    let changes = ChangeSet(from: before, to: after)
    #expect(!changes.isEmpty)
    #expect(Set(changes.live.upserted) == Set(["kept", "added"]))
    #expect(changes.live.removed == ["removed"])
    #expect(!changes.live.reordered)
    #expect(changes.tabs.isEmpty)
    let patch = Patch(rev: 7, changes: changes, state: after).json
    #expect(patch["rev"] == 7)
    #expect(patch["live"]?["remove"] == ["removed"])
    #expect(patch["live"]?["order"] == nil)
    let upserts = patch["live"]?["upsert"]?.array ?? []
    #expect(upserts.count == 2)
    for id in ["kept", "added"] {
      var expected = after.live[id]!.json
      expected["id"] = .string(id)
      #expect(upserts.first { $0["id"] == .string(id) } == .object(expected))
    }
  }

  @Test func equalLiveDictionariesDoNotProduceAChangeOrPatch() {
    var before = BrowserState()
    before.live["b"] = PageLiveFacts(playingAudio: true)
    before.live["a"] = PageLiveFacts(isLoading: true)
    var after = before
    after.live = [:]
    after.live["a"] = before.live["a"]
    after.live["b"] = before.live["b"]
    let changes = ChangeSet(from: before, to: after)
    #expect(changes.isEmpty)
    #expect(Patch(rev: 0, changes: changes, state: after).json["live"] == nil)
  }

  @Test func trustedStateJSONIncludesLiveAndRetainsNativeLocalSlices() throws {
    var state = BrowserState()
    state.live["tab"] = PageLiveFacts(playingAudio: true, themeColor: "blue", discarded: true)
    try state.applySlice("find", ["tab": ["open": true, "query": "text"]])
    try state.applySlice("selection", ["window": ["tab"]])
    try state.applySlice("selectionAnchors", ["window": "tab"])
    try state.applySlice("windowUi", ["window": ["panel": ["open": true, "initialText": "text"], "downloadsOpen": true]])
    let snapshot = state.stateJSON
    #expect(snapshot["live"]?["tab"] == state.live["tab"]?.jsonValue)
    let restored = try BrowserState(stateJSON: snapshot)
    #expect(restored.live == state.live)
    #expect(restored.find == state.find)
    #expect(restored.selection == state.selection)
    #expect(restored.selectionAnchors == state.selectionAnchors)
    #expect(restored.windowUi == state.windowUi)
    #expect(restored.stateJSON == snapshot)
  }

  @Test func liveFactMutationsStayOutsideSessionDocument() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let document = store.sessionDocument().json()
    var state = store.state
    state.live[tab] = PageLiveFacts(isLoading: true, playingAudio: true, discarded: true)
    let changed = Store(state: state, memory: store.memory, checksInvariants: false, clock: { 1 })
    #expect(changed.sessionDocument().json() == document)
    #expect(state.stateJSON["live"]?[tab]?["discarded"] == true)
  }
}
