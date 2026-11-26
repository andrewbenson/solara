import AppKit
import XCTest
@testable import SolaraUI

final class SelectionLifecycleTests: XCTestCase {
  func testDelayReplacementDisableAndStalePage() {
    var lifecycle = SelectionLifecycle()
    lifecycle.update(enabled: true)
    lifecycle.receive(text: "first", page: "a", now: 0)
    XCTAssertNil(lifecycle.shown(page: "a", now: 0.149))
    XCTAssertEqual(lifecycle.shown(page: "a", now: 0.15), "first")
    lifecycle.receive(text: "second", page: "a", now: 0.2)
    XCTAssertNil(lifecycle.shown(page: "b", now: 1))
    XCTAssertEqual(lifecycle.shown(page: "a", now: 0.25), "first")
    lifecycle.receive(text: nil, page: "a", now: 0.3)
    XCTAssertNil(lifecycle.shown(page: "a", now: 1))
    lifecycle.receive(text: "second", page: "a", now: 2)
    lifecycle.update(enabled: false)
    lifecycle.update(enabled: true)
    XCTAssertNil(lifecycle.shown(page: "a", now: 3))
    lifecycle.receive(text: "new", page: "b", now: 4)
    XCTAssertNil(lifecycle.shown(page: "a", now: 5))
    XCTAssertEqual(lifecycle.shown(page: "b", now: 5), "new")
  }

  func testClampedPlacementUsesTheNativeBar() async {
    await MainActor.run {
      let bar = SelectionBarView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
      func state(_ top: Double, _ bottom: Double, _ center: Double) -> SelectionBarState {
        SelectionBarState(key: "k", top: top, bottom: bottom, center: center, dark: false, icon: "#000000", textPrimary: "#000000", tooltip: "Search", label: "Search")
      }
      bar.update(state(20, 40, -100))
      XCTAssertEqual(bar.barFrame?.minX, 8)
      XCTAssertEqual(bar.barFrame?.minY, 46)
      XCTAssertFalse(bar.above)
      bar.update(state(180, 190, 1000))
      XCTAssertEqual(bar.barFrame?.maxX, 312)
      XCTAssertEqual(bar.barFrame?.minY, 142)
      bar.update(state(30, 195, 160))
      XCTAssertEqual(bar.barFrame?.minY, 164)
      bar.update(state(210, 230, 160))
      XCTAssertNil(bar.barFrame)
    }
  }

  func testSelectionPublicationAndDismissalPreserveFieldFocus() async {
    await MainActor.run {
      NSApplication.shared.setActivationPolicy(.prohibited)
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
      window.contentView?.addSubview(field)
      XCTAssertTrue(window.makeFirstResponder(field))
      let bar = SelectionBarView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
      window.contentView?.addSubview(bar)
      var lifecycle = SelectionLifecycle()
      lifecycle.update(enabled: true)
      lifecycle.receive(text: "selected", page: "a", now: 0)
      XCTAssertEqual(lifecycle.shown(page: "a", now: 0.15), "selected")
      bar.update(SelectionBarState(key: "k", top: 80, bottom: 100, center: 160, dark: false, icon: "#000000", textPrimary: "#000000", tooltip: "Search", label: "Search"))
      XCTAssertTrue(window.firstResponder === field)
      bar.update(nil)
      XCTAssertTrue(window.firstResponder === field)
    }
  }

  func testModifierPrecedenceAndWhitespace() {
    XCTAssertEqual(SelectionLifecycle.disposition(meta: false, shift: false, alt: false, middle: false), "foreground")
    XCTAssertEqual(SelectionLifecycle.disposition(meta: true, shift: false, alt: true, middle: false), "background")
    XCTAssertEqual(SelectionLifecycle.disposition(meta: true, shift: true, alt: true, middle: false), "foreground")
    XCTAssertEqual(SelectionLifecycle.disposition(meta: false, shift: true, alt: true, middle: false), "split")
    XCTAssertEqual(SelectionLifecycle.disposition(meta: false, shift: true, alt: false, middle: false), "window")
    XCTAssertEqual(SelectionLifecycle.disposition(meta: false, shift: false, alt: false, middle: true), "background")
    XCTAssertEqual(SelectionLifecycle.query("  a\n b\t c  "), "a b c")
    XCTAssertEqual(SelectionLifecycle.query("\u{FEFF}a\u{00A0}b\u{FEFF}"), "a b")
    XCTAssertEqual(SelectionLifecycle.query("\u{0085}a\u{0085}"), "\u{0085}a\u{0085}")
  }
}
