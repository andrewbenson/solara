import AppKit
import SolaraModel
import SolaraStore
import XCTest
@testable import SolaraUI

final class ZoomLifecycleTests: XCTestCase {
  func testEscapeDismissalIsConsumedBeforeTheJavaScriptPageEvent() async throws {
    try await MainActor.run {
      let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), checksInvariants: false)
      let windowId = try XCTUnwrap(try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result?.string)
      let tabId = try XCTUnwrap(store.state.windows[windowId]?.tabIds.first)
      let issuer = PageIssuer(store: store, registry: PageRegistry())
      let owner = NSObject()
      let binding = try XCTUnwrap(issuer.attach(tabId: tabId, engine: .chromium, host: .reactNative, owner: owner,
        context: PageHostContext(navigationSeq: store.state.tabs[tabId]?.navigation.flatMap { Int(exactly: $0.seq) }, contextRevision: 1, wasNewTab: false, newTabShownUrl: nil),
        perform: { _, completion in completion(.success(.null)) }))
      var state = PanePopoverLifecycle()
      state.set("zoom", tabId: tabId)
      let previous = PageIssuer.consumeLifecycleEvent
      defer { PageIssuer.consumeLifecycleEvent = previous }
      PageIssuer.consumeLifecycleEvent = { _, binding, name, payload in
        guard name == "onCommand", payload["command"]?.string == "escape" else { return false }
        return state.dismissZoom(binding.tabId, revision: state.revision(binding.tabId))
      }
      XCTAssertNil(issuer.reserveEvent(binding, name: "onCommand", payload: ["command": "escape"]))
      XCTAssertNil(state.values[tabId])
      XCTAssertNotNil(issuer.reserveEvent(binding, name: "onCommand", payload: ["command": "escape"]))
    }
  }

  func testNativeDismissalRejectsAnOlderPresentationAndReopens() {
    var state = PanePopoverLifecycle()
    state.set("zoom", tabId: "a")
    let first = state.revision("a")
    state.set("zoom", tabId: "b")
    XCTAssertTrue(state.dismissZoom("a", revision: first))
    XCTAssertNil(state.values["a"])
    XCTAssertEqual(state.values["b"], "zoom")
    XCTAssertFalse(state.dismissZoom("a", revision: first))
    state.set("zoom", tabId: "a")
    XCTAssertFalse(state.dismissZoom("a", revision: first))
    XCTAssertEqual(state.values["a"], "zoom")
    state.set("siteControls", tabId: "a")
    XCTAssertFalse(state.dismissZoom("a", revision: state.revision("a")))
    XCTAssertEqual(state.values["a"], "siteControls")
    state.set(nil, tabId: "b")
    XCTAssertNil(state.values["b"])
    state.retainTabs([])
    XCTAssertTrue(state.values.isEmpty)
  }

  func testZoomUpdatesAndDismissalPreserveFieldFocus() async {
    await MainActor.run {
      NSApplication.shared.setActivationPolicy(.prohibited)
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      window.contentView?.addSubview(field)
      XCTAssertTrue(window.makeFirstResponder(field))
      let body = ZoomPanelView(frame: .zero)
      let popover = PopoverView(body: body)
      popover.frame = window.contentView!.bounds
      window.contentView?.addSubview(popover)
      let data = Data(#"{"zoom":1.25,"dark":false,"theme":{}}"#.utf8)
      body.update(try! JSONDecoder().decode(ZoomPanelState.self, from: data))
      popover.set(placement: PopoverPlacement(width: 236, top: 8, right: 8), dark: false)
      popover.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === field)
      popover.close()
      XCTAssertTrue(window.firstResponder === field)
    }
  }

  func testStepAndStalePageAdmission() {
    XCTAssertEqual(ZoomLifecycle.step(-7), -1)
    XCTAssertEqual(ZoomLifecycle.step(0), 0)
    XCTAssertEqual(ZoomLifecycle.step(4), 1)
    XCTAssertNil(ZoomLifecycle.step(.nan))
    XCTAssertNil(ZoomLifecycle.step(.infinity))
    XCTAssertTrue(ZoomLifecycle.accepts(page: "a", currentPage: "a", eligible: true))
    XCTAssertFalse(ZoomLifecycle.accepts(page: "a", currentPage: "b", eligible: true))
    XCTAssertFalse(ZoomLifecycle.accepts(page: "a", currentPage: "a", eligible: false))
  }
}
