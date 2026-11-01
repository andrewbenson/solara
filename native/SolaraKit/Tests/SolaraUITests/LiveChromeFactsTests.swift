import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct LiveChromeFactsTests {
  private func state() -> BrowserState {
    var state = BrowserState()
    var window = BrowserWindow(id: "window", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    window.tabIds = ["native", "stale", "unloaded"]
    window.activeTabIds["default"] = "native"
    state.windows[window.id] = window
    state.windowOrder = [window.id]
    for id in window.tabIds {
      var tab = Tab(id: id, windowId: window.id, profileId: "default", url: "https://\(id).test/", now: 0)
      if id == "unloaded" { tab.unloaded = true }
      else { tab.navigation = Navigation(url: tab.url, seq: 1) }
      state.tabs[id] = tab
    }
    return state
  }

  private func host() -> SidebarHostState {
    var host = SidebarHostState(profileId: "default")
    host.loading = ["stale"]
    host.playing = ["stale"]
    host.sleeping = ["stale"]
    host.selection = ["native"]
    host.developer = ["native"]
    host.pip = ["native"]
    host.capture = ["native": .screen]
    return host
  }

  @Test func nativeSidebarFactsOverrideStaleJSFeeds() {
    let flags = SidebarFlags(host(), live: ["native": PageLiveFacts(isLoading: true, playingAudio: true, discarded: true)])
    #expect(flags.loading == ["native"])
    #expect(flags.playing == ["native"])
    #expect(flags.sleeping == ["native"])
    #expect(flags.selection == ["native"])
    #expect(flags.developer == ["native"])
    #expect(flags.pip == ["native"])
    #expect(flags.capture == ["native": .screen])
  }

  @Test func fallbackSidebarStillUsesHostFacts() {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = false
    defer { NativeStoreHandle.ownsWorkspace = previousOwnership }
    var state = state()
    state.live = ["native": PageLiveFacts(isLoading: true, playingAudio: true, discarded: true)]
    let context = SidebarContext(state: state, host: host(), windowId: "window", favicons: SidebarFavicons())
    #expect(context.flags.loading == ["stale"])
    #expect(context.flags.playing == ["stale"])
    #expect(context.flags.sleeping == ["stale"])
    var stripHost = StripHostState(profileId: "default")
    stripHost.playing = ["stale"]
    let strip = StripContext(state: state, host: stripHost, windowId: "window", favicons: SidebarFavicons(), previous: nil)
    #expect(strip.playing == ["stale"])
    #expect(strip.playing == strip.sidebar.flags.playing)
  }

  @Test func nativeContextsRefreshFactsWithoutAHostPropChange() {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = true
    defer { NativeStoreHandle.ownsWorkspace = previousOwnership }
    var state = state()
    let host = host()
    let favicons = SidebarFavicons()
    let first = SidebarContext(state: state, host: host, windowId: "window", favicons: favicons)
    state.live = ["native": PageLiveFacts(isLoading: true, playingAudio: true, discarded: true)]
    let next = SidebarContext(state: state, host: host, windowId: "window", favicons: favicons, previous: first)
    #expect(first.flags.loading.isEmpty)
    #expect(next.flags.loading == ["native"])
    #expect(next.flags.playing == ["native"])
    #expect(next.flags.sleeping == ["native"])
    #expect(first.paletteGeneration == next.paletteGeneration)
  }

  @Test func emptyOwnedLiveDoesNotFallBackToHost() {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = true
    defer { NativeStoreHandle.ownsWorkspace = previousOwnership }
    let context = SidebarContext(state: state(), host: host(), windowId: "window", favicons: SidebarFavicons())
    #expect(context.flags.loading.isEmpty)
    #expect(context.flags.playing.isEmpty)
    #expect(context.flags.sleeping.isEmpty)
    #expect(context.flags.selection == ["native"])
    #expect(context.flags.developer == ["native"])
  }

  @Test func stripUsesSidebarFlagsForLiveAudio() {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = true
    defer { NativeStoreHandle.ownsWorkspace = previousOwnership }
    var state = state()
    state.live = ["native": PageLiveFacts(playingAudio: true)]
    var host = StripHostState(profileId: "default")
    host.playing = ["stale"]
    let favicons = SidebarFavicons()
    let first = StripContext(state: state, host: host, windowId: "window", favicons: favicons, previous: nil)
    #expect(first.playing == ["native"])
    #expect(first.playing == first.sidebar.flags.playing)
    state.live = [:]
    let next = StripContext(state: state, host: host, windowId: "window", favicons: favicons, previous: first)
    #expect(next.playing.isEmpty)
    #expect(next.playing == next.sidebar.flags.playing)
  }

  @Test func discardedAndUnloadedStayDistinct() throws {
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.ownsWorkspace = true
    defer { NativeStoreHandle.ownsWorkspace = previousOwnership }
    var state = state()
    state.live = ["native": PageLiveFacts(discarded: true), "stale": PageLiveFacts()]
    var context = SidebarContext(state: state, host: host(), windowId: "window", favicons: SidebarFavicons())
    let discarded = try #require(state.tabs["native"])
    let unloaded = try #require(state.tabs["unloaded"])
    #expect(context.flags.sleeping == ["native"])
    #expect(!context.query.pageUnloaded("native"))
    #expect(context.query.pageUnloaded("unloaded"))
    #expect(context.iconSpec(discarded).dimmed)
    #expect(!context.iconSpec(unloaded).dimmed)
    state.settings["fadeUnloadedTabs"] = .bool(true)
    context = SidebarContext(state: state, host: host(), windowId: "window", favicons: SidebarFavicons(), previous: context)
    #expect(context.iconSpec(unloaded).dimmed)
    #expect(!context.flags.sleeping.contains("unloaded"))
  }
}
