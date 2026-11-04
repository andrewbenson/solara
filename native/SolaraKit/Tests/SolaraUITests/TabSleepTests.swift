import SolaraModel
import SolaraStore
import SolaraUI
import Testing

@MainActor
@Suite struct TabSleepTests {
  private func fixture(_ protection: String? = nil) -> BrowserState {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    for windowId in ["first", "second"] {
      var window = BrowserWindow(id: windowId, profileId: profile, incognito: false, frame: nil, createdAt: 0)
      let active = "\(windowId)-active"
      window.tabIds = [active]
      window.activeTabIds[profile] = active
      state.windows[windowId] = window
      state.windowOrder.append(windowId)
      var tab = Tab(id: active, windowId: windowId, profileId: profile, url: "https://active.example/", now: 0)
      tab.navigation = Navigation(url: tab.url, seq: 1)
      state.tabs[active] = tab
    }
    var target = Tab(id: "target", windowId: "second", profileId: profile, url: "https://background.example/", now: 0)
    target.navigation = Navigation(url: target.url, seq: 2)
    state.tabs[target.id] = target
    state.windows["second"]!.tabIds.append(target.id)
    state.ui.focusedWindowId = "first"
    switch protection {
    case "shown": state.windows["second"]!.activeTabIds[profile] = target.id
    case "peek": state.peeks["second"] = Peek(tabId: target.id, sourceId: "second-active", sourcePage: "https://active.example/", from: nil)
    case "held":
      state.tabs["second-active"]!.navigation = nil
      state.tabs["second-active"]!.pageIn = target.id
      state.tabs[target.id]!.windowId = "first"
      state.windows["second"]!.tabIds.removeAll { $0 == target.id }
      state.windows["first"]!.tabIds.append(target.id)
    case "split":
      state.splits["split"] = SplitView(id: "split", windowId: "second", tabIds: ["second-active", target.id], orientation: "horizontal", sizes: [0.5, 0.5])
    case "shared":
      state.tabs[target.id]!.navigation = nil
      state.tabs[target.id]!.pageIn = "first-active"
    default: break
    }
    return state
  }

  @Test(arguments: ["shown", "split", "peek", "held", "shared"])
  func protectsEverySolaraPresentation(_ reason: String) {
    let sleep = TabSleep(store: Store(state: fixture(reason)), pages: PageRegistry())
    #expect(sleep.solaraReasonNotToSleep("target") == reason)
  }

  @Test(arguments: ["shown", "split", "peek", "held", "shared"])
  func protectedTabsNeverReachTheEngine(_ reason: String) {
    let pages = PageRegistry()
    var commands: [PageCommand] = []
    pages.register(tabID: "target", engine: .chromium, host: .pooled) { command, finish in
      commands.append(command)
      finish(.success(.string("discarded")))
    }
    let store = Store(state: fixture(reason))
    let before = store.state
    let sleep = TabSleep(store: store, pages: pages)
    #expect(!sleep.sleepNow("target"))
    #expect(commands.isEmpty)
    #expect(store.state == before)
  }

  @Test func eligibleBackgroundTabRequestsExternalDiscardExactlyOnce() {
    let store = Store(state: fixture())
    let pages = PageRegistry()
    var commands: [PageCommand] = []
    pages.register(tabID: "target", engine: .chromium, host: .reactNative) { command, finish in
      commands.append(command)
      finish(.success(.string("refused")))
    }
    let before = store.state
    let sleep = TabSleep(store: store, pages: pages)
    #expect(sleep.solaraReasonNotToSleep("target") == nil)
    #expect(sleep.sleepNow("target"))
    #expect(commands == [.discard(false)])
    #expect(store.state == before)
    #expect(store.state.live["target"]?.discarded == false)
  }

  @Test func sleepRechecksTheCurrentSelection() throws {
    let store = Store(state: fixture())
    let pages = PageRegistry()
    var calls = 0
    pages.register(tabID: "target", engine: .chromium, host: .pooled) { _, finish in
      calls += 1
      finish(.success(.string("discarded")))
    }
    let sleep = TabSleep(store: store, pages: pages)
    #expect(sleep.solaraReasonNotToSleep("target") == nil)
    try store.dispatch(Command("activate", ["target"]))
    #expect(sleep.solaraReasonNotToSleep("target") == "shown")
    #expect(!sleep.sleepNow("target"))
    #expect(calls == 0)
  }

  @Test func sharedBackgroundCopiesDoNotProtectTheirOwner() {
    var state = fixture()
    var copy = state.tabs["target"]!
    copy.id = "copy"
    copy.windowId = "first"
    copy.navigation = nil
    copy.pageIn = "target"
    copy.pinKey = "target"
    copy.pinned = true
    state.tabs[copy.id] = copy
    state.windows["first"]!.tabIds.append(copy.id)
    state.tabs["target"]!.pinned = true
    let sleep = TabSleep(store: Store(state: state), pages: PageRegistry())
    #expect(sleep.solaraReasonNotToSleep("copy") == "shared")
    #expect(sleep.solaraReasonNotToSleep("target") == nil)
  }

  @Test func backgroundSplitIsEligibleAndFocusedPaneIsShown() {
    var state = fixture()
    var other = state.tabs["target"]!
    other.id = "other"
    state.tabs[other.id] = other
    state.windows["second"]!.tabIds.append(other.id)
    state.splits["background"] = SplitView(id: "background", windowId: "second", tabIds: ["target", "other"], orientation: "horizontal", sizes: [0.5, 0.5])
    let sleep = TabSleep(store: Store(state: state), pages: PageRegistry())
    #expect(sleep.solaraReasonNotToSleep("target") == nil)
    let shown = TabSleep(store: Store(state: fixture("split")), pages: PageRegistry())
    #expect(shown.solaraReasonNotToSleep("second-active") == "shown")
  }

  @Test(arguments: ["missing", "blank", "lazy", "unloaded", "history", "bookmarks", "downloads", "pending-internal"])
  func tabsWithoutAnEnginePageAreRefused(_ kind: String) {
    var state = fixture()
    switch kind {
    case "missing": state.tabs.remove(["target"])
    case "blank": state.tabs["target"]!.url = ""
    case "lazy": state.tabs["target"]!.navigation = nil
    case "unloaded": state.tabs["target"]!.unloaded = true
    case "pending-internal": state.tabs["target"]!.navigation = Navigation(url: "SOLARA://HISTORY?q=test", seq: 3)
    default:
      state.tabs["target"]!.url = "solara://\(kind)"
      state.tabs["target"]!.navigation = nil
      state.tabs["target"]!.adoptId = "adopted"
    }
    let pages = PageRegistry()
    var calls = 0
    pages.register(tabID: "target", engine: .chromium, host: .pooled) { _, finish in
      calls += 1
      finish(.success(.string("discarded")))
    }
    let sleep = TabSleep(store: Store(state: state), pages: pages)
    #expect(sleep.solaraReasonNotToSleep("target") == "no page")
    #expect(!sleep.sleepNow("target"))
    #expect(calls == 0)
  }

  @Test func missingWebKitAndAlreadyDiscardedPagesAreNotRequested() {
    let state = fixture()
    let store = Store(state: state)
    let pages = PageRegistry()
    let sleep = TabSleep(store: store, pages: pages)
    #expect(!sleep.sleepNow("target"))
    var calls = 0
    pages.register(tabID: "target", engine: .webKit, host: .pooled) { _, finish in
      calls += 1
      finish(.success(.string("discarded")))
    }
    #expect(!sleep.sleepNow("target"))
    var discarded = state
    discarded.live["target"] = PageLiveFacts(discarded: true)
    pages.register(tabID: "target", engine: .chromium, host: .pooled) { _, finish in
      calls += 1
      finish(.success(.string("discarded")))
    }
    #expect(!TabSleep(store: Store(state: discarded), pages: pages).sleepNow("target"))
    #expect(calls == 0)
  }
}
