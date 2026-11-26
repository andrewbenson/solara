import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
struct ExtensionSidePanelLifecycleTests {
  private let a = "chrome-extension://a/panel.html"
  private let b = "chrome-extension://b/panel.html"

  private func store() -> Store {
    var state = BrowserState(settings: Settings(values: ["extensionSidePanelWidth": 420]))
    for id in ["w", "other"] {
      state.windows[id] = BrowserWindow(id: id, profileId: state.settings.defaultProfileId, incognito: false, frame: nil, createdAt: 0)
      state.windowOrder.append(id)
    }
    return Store(state: state, checksInvariants: false)
  }

  @Test func resizePersistsAndResetKeepsOtherWindowsAtTheirOldWidth() throws {
    let store = store()
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    let panel = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false))
    try #require(lifecycle.saveWidth(490, key: panel.key, windowId: "w", store: store))
    #expect(store.state.windows["w"]?.effectiveSidePanelWidth(store.state.settings) == 490)
    try #require(lifecycle.saveWidth(nil, key: panel.key, windowId: "w", store: store))
    #expect(store.state.windows["w"]?.effectiveSidePanelWidth(store.state.settings) == 360)
    #expect(store.state.settings.number("extensionSidePanelWidth") == 360)
    #expect(store.state.windows["other"]?.effectiveSidePanelWidth(store.state.settings) == 420)
  }

  @Test func splitFitsWithinTheCardAndReleasesRoomInFullscreen() throws {
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    let panel = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false))
    let room = panel.room(width: 360)
    #expect(room == 366)
    let frames = DockedLayoutFrames.of(.init(size: CGSize(width: 1200, height: 800), dock: 1, sidePanel: room))
    let split = SplitView(id: "s", windowId: "w", tabIds: ["left", "right"], orientation: "horizontal", sizes: [0.5, 0.5])
    let panes = ShellGeometry.split(split, width: frames.card.width, height: frames.card.height).panes
    #expect(panes.count == 2)
    for pane in panes.values { #expect(pane.maxX + frames.card.minX <= frames.sidePanel!.minX) }
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: true) == nil)
    #expect(lifecycle.extensionId == "a")
  }

  @Test func disabledExtensionClearsEvenWhileItsBrowserIsMissing() {
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false) != nil)
    #expect(lifecycle.reconcile(eligible: false, pageProfile: "", url: .unavailable(fallback: a), fullscreen: false) == nil)
    #expect(lifecycle.extensionId == nil)
  }

  @Test func windowCloseOnlyConsumesTheCurrentPageKey() throws {
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    let first = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false))
    #expect(!lifecycle.close(key: "stale"))
    #expect(lifecycle.close(key: first.key))
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false) == nil)
    lifecycle.request("a")
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false)?.key != first.key)
  }

  @Test func urlAndProfileReplacementFenceTheOldPage() throws {
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    let first = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false))
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "", url: .unavailable(fallback: nil), fullscreen: false) == first)
    let otherURL = a + "?tab=2"
    let next = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(otherURL), fullscreen: false))
    #expect(next.url == otherURL)
    #expect(!lifecycle.close(key: first.key))
    let privatePage = try #require(lifecycle.reconcile(eligible: true, pageProfile: "private", url: .resolved(otherURL), fullscreen: false))
    #expect(privatePage.key != next.key)
    lifecycle.request("b")
    let replacement = try #require(lifecycle.reconcile(eligible: true, pageProfile: "private", url: .resolved(b), fullscreen: false))
    #expect(replacement.extensionId == "b")
    #expect(!lifecycle.close(key: privatePage.key))
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "private", url: .resolved(nil), fullscreen: false) == nil)
    #expect(lifecycle.extensionId == nil)
  }

  @Test func webKitClearsThePanelAndChromiumStartupKeepsItsFallback() throws {
    let lifecycle = ExtensionSidePanelLifecycle()
    let starting = ExtensionSidePanelLifecycle.URLSource(engine: .chromium, browserId: 0, fallback: a, resolved: nil)
    let webKit = ExtensionSidePanelLifecycle.URLSource(engine: .webKit, browserId: 0, fallback: a, resolved: nil)

    lifecycle.request("a")
    let opened = try #require(lifecycle.reconcile(eligible: true, pageProfile: "p", url: starting, fullscreen: false))
    #expect(opened.url == a)
    let waiting = ExtensionSidePanelLifecycle.URLSource(engine: .chromium, browserId: 0, fallback: nil, resolved: nil)
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "p", url: waiting, fullscreen: false) == opened)
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "p", url: webKit, fullscreen: false) == nil)
    #expect(lifecycle.extensionId == nil)

    lifecycle.request("a")
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "p", url: webKit, fullscreen: false) == nil)
    #expect(lifecycle.extensionId == nil)
  }

  @Test func uninstallMatchesOnlyItsCatalogProfileAndExtension() {
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    #expect(lifecycle.reconcile(eligible: true, pageProfile: "incognito:p", url: .resolved(a), fullscreen: false) != nil)
    #expect(lifecycle.matchesRemoval("a", profile: "p", catalogProfile: "p"))
    #expect(!lifecycle.matchesRemoval("a", profile: "other", catalogProfile: "p"))
    #expect(!lifecycle.matchesRemoval("b", profile: "p", catalogProfile: "p"))
  }

  @Test func clampsSavedWidthsBeforeComputingPanelRoom() throws {
    let store = store()
    let lifecycle = ExtensionSidePanelLifecycle()
    lifecycle.request("a")
    let panel = try #require(lifecycle.reconcile(eligible: true, pageProfile: "p", url: .resolved(a), fullscreen: false))
    for (saved, expected) in [(0.0, 320.0), (490, 490), (999, 600)] {
      try store.dispatch(Command("setWindowSidebar", [.string("w"), ["sidePanelWidth": .number(saved)]]), origin: .native)
      let window = try #require(store.state.windows["w"])
      let rawWidth = window.effectiveSidePanelWidth(store.state.settings)
      #expect(rawWidth == saved)
      let width = SidePanelMetrics.presentationWidth(rawWidth)
      #expect(width == expected)
      #expect(panel.room(width: width) == CGFloat(expected + 6))
    }
  }

  @Test func detachedRendererFocusIsRememberedOnlyWhenCaptured() {
    let page = NSView()
    let renderer = NSView()
    page.addSubview(renderer)
    #expect(ExtensionSidePanelFocus.holdsFocus(renderer, in: page))
    renderer.removeFromSuperview()
    #expect(ExtensionSidePanelFocus.holdsFocus(nil, in: page, beforeDetach: true))
    #expect(!ExtensionSidePanelFocus.holdsFocus(nil, in: page))
    #expect(!ExtensionSidePanelFocus.holdsFocus(renderer, in: page))
  }

  @Test func twelveCyclesReleaseEveryOwnedPage() throws {
    let lifecycle = ExtensionSidePanelLifecycle()
    var keys = Set<String>()
    final class Page {}
    let slot = ExtensionSidePanelPageSlot<Page>()
    for _ in 0..<12 {
      lifecycle.request("a")
      let panel = try #require(lifecycle.reconcile(eligible: true, pageProfile: "", url: .resolved(a), fullscreen: false))
      #expect(keys.insert(panel.key).inserted)
      slot.page = Page()
      weak var page = slot.page
      #expect(lifecycle.close(key: panel.key))
      slot.remove { _ in }
      #expect(page == nil)
      #expect(slot.page == nil)
      #expect(lifecycle.extensionId == nil)
    }
  }
}
