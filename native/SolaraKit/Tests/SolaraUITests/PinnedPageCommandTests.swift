import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite struct PinnedPageCommandTests {
  @Test(arguments: ["reload", "forceReload", "returnToPinnedUrl", "handOffPin"])
  func nativeCommandsConsumeMissingTargets(_ command: String) {
    let state = BrowserState(settings: Settings.hydrated(from: nil))
    #expect(PinnedPageCommand.commands.contains(command))
    #expect(PinnedPageCommand.plan(command, tabId: "missing", state: state) == nil)
  }

  @Test func capturedFamilyRejectsReplacementUnpinAndWindowMove() throws {
    var state = sharedState()
    state.tabs["copy"]?.pageIn = "holder"
    let copy = try #require(state.tabs["copy"])
    let holder = try #require(state.tabs["holder"])
    let plan = try #require(PinnedPageCommand.plan("forceReload", tabId: copy.id, state: state))
    #expect(plan.page == .forceReload)
    #expect(plan.current(state))
    state.tabs["holder"]?.navigation = Navigation(url: "https://replacement.test/", seq: 42, userInitiated: true)
    #expect(!plan.current(state))
    state.tabs["holder"] = holder
    state.tabs["copy"]?.pinnedUrl = nil
    #expect(!plan.current(state))
    state.tabs["copy"] = copy
    state.tabs["copy"]?.pinned = false
    #expect(!plan.current(state))
    state.tabs["copy"] = copy
    state.tabs["holder"]?.windowId = "elsewhere"
    #expect(!plan.current(state))
  }

  @Test(arguments: ["back", "forward"])
  func frozenHistoryRetainsItsActionAcrossTheMove(_ command: String) throws {
    let state = sharedState()
    let plan = try #require(PinnedPageCommand.plan(command, tabId: "copy", state: state))
    #expect(plan.page == (command == "back" ? .goBack : .goForward))
    #expect(plan.moving)
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 1)
    session.handOffPin(plan.copy.id)
    #expect(session.state.tabs[plan.holder.id]?.windowId == "to")
    #expect(session.state.activeTabId("to") == plan.holder.id)
    #expect(plan.page == (command == "back" ? .goBack : .goForward))
  }

  @Test func captureTimeoutPublishesTheHoldersLatestPicture() throws {
    let holder = "data:image/jpeg;base64,new-holder"
    let previous = "data:image/jpeg;base64,old-copy"
    let picture = PinnedPageCommand.pictureAfterCaptureTimeout(holder: holder, previous: previous)
    let state = sharedState()
    let presentation = try #require(PinnedPageCommand.presentation(tabId: "copy", state: state, token: 1,
      picture: picture, bridge: nil, dark: false))
    #expect(presentation["uri"] == .string(holder))
    #expect(PinnedPageCommand.pictureAfterCaptureTimeout(holder: holder, previous: nil) == holder)
    #expect(PinnedPageCommand.pictureAfterCaptureTimeout(holder: nil, previous: previous) == previous)
    #expect(PinnedPageCommand.pictureAfterCaptureTimeout(holder: nil, previous: nil) == nil)
  }

  private func sharedState() -> BrowserState {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var copy = Tab(id: "copy", windowId: "to", profileId: "default", url: "https://pin.test/away", now: 0)
    copy.pinned = true
    copy.pinKey = "family"
    copy.pinnedUrl = "https://pin.test/"
    copy.unloaded = true
    var holder = copy
    holder.id = "holder"
    holder.windowId = "from"
    holder.unloaded = nil
    holder.navigation = Navigation(url: holder.url, seq: 1, userInitiated: true)
    state.tabs[copy.id] = copy
    state.tabs[holder.id] = holder
    for tab in [copy, holder] {
      var window = BrowserWindow(id: tab.windowId, profileId: "default", incognito: false, frame: nil, createdAt: 0)
      window.tabIds = [tab.id]
      window.activeTabIds["default"] = tab.id
      state.windows[window.id] = window
    }
    return state
  }

  @Test(arguments: ["handOffPin", "reload", "forceReload", "returnToPinnedUrl"])
  func newlyMirroredCopyFindsItsPhysicalHolderWithoutPageIn(_ command: String) throws {
    let state = sharedState()
    #expect(state.tabs["copy"]?.pageIn == nil)
    let plan = try #require(PinnedPageCommand.plan(command, tabId: "copy", state: state))
    #expect(plan.moving)
    #expect(plan.holder.id == "holder")
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 1)
    session.handOffPin(plan.copy.id)
    #expect(session.state.tabs[plan.holder.id]?.windowId == "to")
    #expect(session.state.tabs[plan.copy.id]?.windowId == "from")
    #expect(session.state.tabs[plan.copy.id]?.pageIn == plan.holder.id)
    #expect(session.state.activeTabId("to") == plan.holder.id)
    let wanted = TabViewWanted.from(session.state, windows: ["from", "to"], isInternal: { _ in false }, frozen: { _ in false })
    #expect(wanted.first { $0.tabId == "holder" }?.windowId == "to")
    #expect(!wanted.contains { $0.tabId == "copy" })
    if plan.home {
      session.returnToPinnedUrl(plan.holder.id)
      #expect(session.state.tabs[plan.holder.id]?.navigation?.url == "https://pin.test/")
    }
  }

  @Test func metadataReportsDoNotCancelTheHandoffButNavigationDoes() throws {
    var state = sharedState()
    let plan = try #require(PinnedPageCommand.plan("handOffPin", tabId: "copy", state: state))
    state.tabs["holder"]?.title = "Reported title"
    state.tabs["holder"]?.zoom = 1.5
    #expect(plan.current(state))
    state.tabs["holder"]?.navigation = Navigation(url: "https://changed.test/", seq: 2, userInitiated: true)
    #expect(!plan.current(state))
  }

  @Test func frozenPublicationOwnsTheSnapshotFieldsAndBridgeScope() throws {
    var state = sharedState()
    let uri = "data:image/jpeg;base64,AA=="
    let copy = try #require(PinnedPageCommand.presentation(tabId: "copy", state: state, token: 7, picture: uri, bridge: nil, dark: false))
    #expect(copy == ["token": .number(7), "tabId": .string("copy"), "copyId": .string("copy"), "uri": .string(uri), "dark": .bool(false)])
    let bridge = (copy: "copy", uri: uri)
    let source = try #require(PinnedPageCommand.presentation(tabId: "holder", state: state, token: 8, picture: nil, bridge: bridge, dark: true))
    #expect(source["copyId"] == .string("copy"))
    #expect(source["uri"] == .string(uri))
    #expect(source["dark"] == .bool(true))
    #expect(PinnedPageCommand.presentation(tabId: "copy", state: state, token: 8, picture: nil, bridge: bridge, dark: false)?["uri"] == .null)
    state.tabs["copy"]?.navigation = Navigation(url: "https://own.test/", seq: 2, userInitiated: true)
    #expect(PinnedPageCommand.presentation(tabId: "holder", state: state, token: 9, picture: nil, bridge: bridge, dark: false) == nil)
  }

  @Test func frozenTokenSurvivesFoundationPublicationAndThePageReturnsHome() throws {
    let state = sharedState()
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: StoreConfig(), now: 1)
    session.handOffPin("copy")
    let json = try #require(PinnedPageCommand.presentation(tabId: "copy", state: session.state, token: 7,
      picture: "data:image/jpeg;base64,AA==", bridge: nil, dark: false))
    let fields = try #require(PageValue(json: .object(json)).foundation as? [String: Any])
    #expect(PinnedPageCommand.token(in: fields) == 7)
    let plan = try #require(PinnedPageCommand.plan("handOffPin", tabId: "copy", state: session.state))
    #expect(plan.moving)
    session.handOffPin(plan.copy.id)
    #expect(session.state.tabs["holder"]?.windowId == "from")
    #expect(session.state.activeTabId("from") == "holder")
  }

  @Test(arguments: ["undisturbed", "switchBack", "panel", "cancelledAction"])
  func captureCompletionRespectsInterveningWindowIntent(_ scenario: String) throws {
    var state = sharedState()
    var other = try #require(state.tabs["copy"])
    other.id = "other"
    other.pinned = false
    other.pinKey = nil
    other.pinnedUrl = nil
    other.navigation = Navigation(url: "https://other.test/", seq: 2, userInitiated: true)
    state.tabs[other.id] = other
    state.windows["to"]?.tabIds.append(other.id)
    var another = other
    another.id = "another"
    state.tabs[another.id] = another
    state.windows["to"]?.tabIds.append(another.id)
    state.windows["to"]?.activeTabIds["default"] = other.id
    var config = StoreConfig()
    config.handOffPinsImmediately = false
    let session = Session(state: state, memory: StoreMemory(), env: PlainWebAddressing(), config: config, now: 1)
    var interactions = PinnedPageCommand.Interactions(state: session.state)
    let gate = PinnedPageCommand.Gate(request: 3, interaction: interactions["to"], ownership: 9, deadline: 10)
    if scenario == "switchBack" || scenario == "cancelledAction" {
      session.activate("another")
      interactions.receive(session.state)
      session.activate("other")
      interactions.receive(session.state)
      #expect(session.state.activeTabId("to") == state.activeTabId("to"))
    }
    if scenario == "panel" {
      session.openPanel("to", "", nil)
      interactions.receive(session.state)
    }
    var actions = 0
    let moved = gate.perform(request: 3, interaction: interactions["to"], ownership: 9, now: 9) {
      session.handOffPin("copy")
      #expect(session.state.tabs["holder"]?.windowId == "to")
      #expect(session.state.activeTabId("to") == "holder")
      actions += 1
    }
    #expect(moved == (scenario == "undisturbed"))
    #expect(session.state.tabs["holder"]?.windowId == (moved ? "to" : "from"))
    #expect(actions == (moved ? 1 : 0))
    if scenario == "panel" { #expect(session.state.windowUi["to"]?.panelOpen == true) }
    if scenario == "cancelledAction" {
      let next = PinnedPageCommand.Gate(request: 4, interaction: interactions["to"], ownership: 9, deadline: 10)
      #expect(next.perform(request: 4, interaction: interactions["to"], ownership: 9, now: 9) { session.handOffPin("copy") })
      #expect(session.state.tabs["holder"]?.windowId == "to")
      #expect(!gate.perform(request: 4, interaction: interactions["to"], ownership: 9, now: 9) { actions += 1 })
      #expect(actions == 0)
    }
  }

  @Test func receiptRejectsTimeoutNewIntentAndOwnershipLoss() {
    let gate = PinnedPageCommand.Gate(request: 3, interaction: 7, ownership: 9, deadline: 10)
    #expect(gate.allows(request: 3, interaction: 7, ownership: 9, now: 9))
    #expect(!gate.allows(request: 4, interaction: 7, ownership: 9, now: 9))
    #expect(!gate.allows(request: 3, interaction: 8, ownership: 9, now: 9))
    #expect(!gate.allows(request: 3, interaction: 7, ownership: 10, now: 9))
    #expect(!gate.allows(request: 3, interaction: 7, ownership: 9, now: 10))
  }
}
