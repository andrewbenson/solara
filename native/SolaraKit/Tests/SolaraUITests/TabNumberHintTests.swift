import AppKit
import XCTest
@testable import SolaraUI

final class TabNumberHintTests: XCTestCase {
  func testLastRowUsesLastActionAndFallsBackWhenUnbound() {
    let actions = TabNumberHintActions.mapping(rowKeys: ["t:a", "s:b", "t:c"])
    XCTAssertEqual(actions["t:a"], ["selectTab:1"])
    XCTAssertEqual(actions["s:b"], ["selectTab:2"])
    XCTAssertEqual(actions["t:c"], ["selectLastTab", "selectTab:3"])
    XCTAssertEqual(TabNumberHintActions.label(actions["t:c"] ?? [], bindings: ["selectTab:3": "⌃X"]), "⌃X")
    XCTAssertNil(TabNumberHintActions.label(actions["s:b"] ?? [], bindings: [:]))
  }

  func testOnlyFirstEightAndLastReceiveActions() {
    let rows = (1...12).map { "t:\($0)" }
    let actions = TabNumberHintActions.mapping(rowKeys: rows)
    XCTAssertEqual(actions["t:8"], ["selectTab:8"])
    XCTAssertNil(actions["t:9"])
    XCTAssertNil(actions["t:11"])
    XCTAssertEqual(actions["t:12"], ["selectLastTab"])
  }

  @MainActor
  func testSelectionRequestsCancellationBeforeHintsHaveAppeared() {
    let feed = TabNumberHintFeed.shared
    feed.cancel()
    let target = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    let recorder = HintCancellationRecorder()
    NotificationCenter.default.addObserver(recorder, selector: #selector(HintCancellationRecorder.receive(_:)), name: Notification.Name("SolaraTabNumberHintsCancelled"), object: nil)
    defer { NotificationCenter.default.removeObserver(recorder) }
    feed.cancel(in: target)
    XCTAssertEqual(recorder.targets.count, 1)
    XCTAssertTrue(recorder.targets.first === target)
    NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsChanged"), object: target, userInfo: ["visible": false])
    XCTAssertEqual(recorder.targets.count, 1)
  }

  @MainActor
  func testRailKeepsTheEntireRemappedBinding() {
    let feed = TabNumberHintFeed.shared
    let target = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsChanged"), object: target, userInfo: ["visible": true, "bindings": ["selectTab:1": "⌃⇧⌘K"]])
    defer { feed.cancel() }
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    let view = TabNumberHintView()
    parent.addSubview(view)
    view.configure(actions: ["selectTab:1"], enabled: true, compact: true)
    view.layoutSubtreeIfNeeded()
    let label = view.subviews.compactMap { $0 as? NSTextField }.first
    XCTAssertEqual(label?.stringValue, "⌃⇧⌘K")
    XCTAssertLessThanOrEqual(view.frame.width, parent.bounds.width)
    if let label, let font = label.font {
      let textWidth = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
      XCTAssertLessThanOrEqual(textWidth, label.frame.width)
      XCTAssertLessThan(font.pointSize, 10)
    } else {
      XCTFail("The keycap must contain its label")
    }
  }

  @MainActor
  func testVisibleFolderMembersReceiveNewNumbersWithoutBeingReopened() {
    let feed = TabNumberHintFeed.shared
    let target = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsChanged"), object: target, userInfo: ["visible": true, "bindings": ["selectTab:1": "⌘1", "selectTab:2": "⌘2"]])
    defer { feed.cancel() }
    let panel = SidebarFolderPanelView()
    panel.updateHintActions(["a": ["selectTab:1"]], enabled: true)
    panel.update(label: "Folder", members: [FolderPanelMember(tabId: "a", title: "A", active: false)], colors: FolderPanelColors(dark: true, tokens: [:]), anchor: .zero, width: 190)
    func hints(in view: NSView) -> [TabNumberHintView] {
      view.subviews.flatMap { child in
        if let hint = child as? TabNumberHintView { return [hint] }
        return hints(in: child)
      }
    }
    let hint = hints(in: panel).first
    let label = hint?.subviews.compactMap { $0 as? NSTextField }.first
    XCTAssertEqual(label?.stringValue, "⌘1")
    panel.updateHintActions(["a": ["selectTab:2"]], enabled: true)
    XCTAssertTrue(hints(in: panel).first === hint)
    XCTAssertEqual(label?.stringValue, "⌘2")
  }

  @MainActor
  func testKeycapCannotInterceptPointerOrEnterAccessibility() {
    let view = TabNumberHintView()
    XCTAssertNil(view.hitTest(.zero))
    XCTAssertFalse(view.isAccessibilityElement())
  }
}

@MainActor
private final class HintCancellationRecorder: NSObject {
  var targets: [NSWindow] = []

  @objc func receive(_ notification: Notification) {
    if let target = notification.object as? NSWindow { targets.append(target) }
  }
}
