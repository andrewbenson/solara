import AppKit
import QuartzCore
import SolaraModel
import XCTest
@testable import SolaraUI

@MainActor
final class KeycapRedesignTests: XCTestCase {
  private func show(_ window: NSWindow, text: String = "⌘1") {
    NotificationCenter.default.post(name: .init("SolaraTabNumberHintsChanged"), object: window, userInfo: ["visible": true, "bindings": ["selectTab:1": text]])
  }

  func testEveryCommandDigitSnapshotHasThreePointGlyphMargins() throws {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
    let hint = TabNumberHintView()
    parent.addSubview(hint)
    let target = HintKeyWindow(contentRect: parent.bounds, styleMask: [], backing: .buffered, defer: true)
    target.contentView = parent
    defer { TabNumberHintFeed.shared.cancel() }
    hint.configure(actions: ["selectTab:1"], enabled: true)
    for digit in 1...9 {
      show(target, text: "⌘\(digit)")
      hint.layoutSubtreeIfNeeded()
      let label = try XCTUnwrap(hint.subviews.compactMap { $0 as? NSTextField }.first)
      let bitmap = try XCTUnwrap(label.bitmapImageRepForCachingDisplay(in: label.bounds))
      label.cacheDisplay(in: label.bounds, to: bitmap)
      var columns: [Int] = []
      for x in 0..<bitmap.pixelsWide {
        if (0..<bitmap.pixelsHigh).contains(where: { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.2 }) { columns.append(x) }
      }
      let first = try XCTUnwrap(columns.first)
      let last = try XCTUnwrap(columns.last)
      let scale = CGFloat(bitmap.pixelsWide) / label.bounds.width
      XCTAssertGreaterThanOrEqual(label.frame.minX + CGFloat(first) / scale, 3, "⌘\(digit)")
      XCTAssertGreaterThanOrEqual(hint.bounds.width - label.frame.minX - CGFloat(last + 1) / scale, 3, "⌘\(digit)")
      XCTAssertEqual(label.font?.pointSize, 10)
      XCTAssertEqual(hint.frame.height, 18)
      XCTAssertEqual(hint.frame.maxX, 192)
    }
  }

  func testRailNudgeAndFadeUseTheSameAnimationClockAndReleaseDuration() throws {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    let icon = NSView(frame: CGRect(x: 7, y: 7, width: 16, height: 16))
    icon.wantsLayer = true
    parent.addSubview(icon)
    let hint = TabNumberHintView()
    parent.addSubview(hint)
    let target = HintKeyWindow(contentRect: parent.bounds, styleMask: [], backing: .buffered, defer: true)
    target.contentView = parent
    defer { TabNumberHintFeed.shared.cancel() }
    hint.configure(actions: ["selectTab:1"], enabled: true, style: .rail)
    hint.present(icon: icon)
    show(target)
    let fade = try XCTUnwrap(hint.layer?.animation(forKey: "tabNumberHintOpacity") as? CABasicAnimation)
    let nudge = try XCTUnwrap(icon.layer?.animation(forKey: "tabNumberHintNudge") as? CABasicAnimation)
    XCTAssertEqual(fade.duration, 0.12)
    XCTAssertEqual(fade.beginTime, nudge.beginTime)
    XCTAssertEqual(fade.timingFunction, nudge.timingFunction)
    XCTAssertEqual(icon.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat, -5)
    XCTAssertTrue(hint.blocksClose)
    XCTAssertTrue(hint.hitTest(hint.frame.origin) === parent)
    TabNumberHintFeed.shared.cancel()
    XCTAssertEqual(hint.layer?.animation(forKey: "tabNumberHintOpacity")?.duration, 0.08)
    XCTAssertEqual(icon.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat, 0)
    show(target)
    XCTAssertFalse(hint.isHidden)
    XCTAssertTrue(hint.blocksClose)
    hint.configure(actions: [], enabled: false)
    XCTAssertNil(hint.layer?.animation(forKey: "tabNumberHintOpacity"))
    XCTAssertFalse(hint.blocksClose)
    XCTAssertEqual(icon.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat, 0)
  }

  func testTitleFadeStopsSixPointsBeforeKeycapAndSharesItsClock() throws {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
    let title = FadeLabel()
    title.frame = CGRect(x: 30, y: 7, width: 162, height: 18)
    title.text = String(repeating: "Long title ", count: 10)
    parent.addSubview(title)
    let hint = TabNumberHintView()
    parent.addSubview(hint)
    let target = HintKeyWindow(contentRect: parent.bounds, styleMask: [], backing: .buffered, defer: true)
    target.contentView = parent
    defer { TabNumberHintFeed.shared.cancel() }
    hint.configure(actions: ["selectTab:1"], enabled: true)
    hint.present(title: title)
    show(target)
    let mask = try XCTUnwrap(title.layer?.mask)
    XCTAssertEqual(title.frame.minX + mask.frame.maxX, hint.frame.minX - 6, accuracy: 0.01)
    let fade = try XCTUnwrap(hint.layer?.animation(forKey: "tabNumberHintOpacity"))
    let slide = try XCTUnwrap(mask.animation(forKey: "tabNumberHintTitle"))
    XCTAssertEqual(fade.beginTime, slide.beginTime)
    XCTAssertEqual(fade.duration, slide.duration)
    XCTAssertEqual(fade.timingFunction, slide.timingFunction)
    let group = try XCTUnwrap(slide as? CAAnimationGroup)
    for animation in group.animations ?? [] { XCTAssertEqual(animation.duration, 0.12) }
    TabNumberHintFeed.shared.cancel()
    XCTAssertEqual(mask.animation(forKey: "tabNumberHintTitle")?.duration, 0.08)
    XCTAssertEqual(mask.frame.width, title.bounds.width)
    hint.configure(actions: [], enabled: false)
    XCTAssertNil(mask.animation(forKey: "tabNumberHintTitle"))
  }

  func testCommandClickOnSidebarRailAndStripHintsNeverReachesClose() throws {
    var state = BrowserState()
    let profile = BrowserState.defaultProfile.id
    var modelWindow = BrowserWindow(id: "w", profileId: profile, incognito: false, frame: nil, createdAt: 0)
    modelWindow.tabIds = ["a", "b"]
    state.windows["w"] = modelWindow
    state.windowOrder = ["w"]
    for id in ["a", "b"] {
      state.tabs[id] = Tab(id: id, windowId: "w", profileId: profile, url: "", now: 0)
    }
    let context = SidebarContext(state: state, host: SidebarHostState(profileId: profile), windowId: "w", favicons: SidebarFavicons())
    let stripContext = StripContext(state: state, host: StripHostState(profileId: profile), windowId: "w", favicons: SidebarFavicons(), previous: nil)
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
    let target = HintKeyWindow(contentRect: parent.bounds, styleMask: [], backing: .buffered, defer: true)
    target.contentView = parent
    defer { TabNumberHintFeed.shared.cancel() }
    let row = TabRowView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
    let rail = RailTabView(frame: CGRect(x: 0, y: 40, width: 30, height: 30))
    for view in [row, rail] as [SidebarRowView] {
      parent.addSubview(view)
      view.update(SidebarItem(kind: .tab("a"), frame: view.frame, region: .scroll, groups: [], section: .list), context)
      view.hovered = true
      view.layoutSubtreeIfNeeded()
    }
    let strip = StripTabChip(frame: CGRect(x: 0, y: 80, width: 150, height: 36))
    parent.addSubview(strip)
    strip.update("a", stripContext)
    strip.hovered = true
    strip.layoutSubtreeIfNeeded()
    var selected = 0
    var closed = 0
    let record: (SidebarAction) -> Void = { action in
      switch action {
      case .click: selected += 1
      case .close: closed += 1
      default: break
      }
    }
    context.send = record
    stripContext.send = { action in
      switch action {
      case .click: selected += 1
      case .close: closed += 1
      default: break
      }
    }
    show(target)
    for (view, hint) in [(row as NSView, row.numberHint), (rail as NSView, rail.numberHint), (strip as NSView, strip.numberHint)] {
      let point = CGPoint(x: hint.frame.midX, y: hint.frame.midY)
      let hit = view.hitTest(view.convert(point, to: parent))
      XCTAssertTrue(hit === view)
      for child in view.subviews + row.body.subviews {
        if let button = child as? SidebarIconButton { XCTAssertTrue(button.isHidden) }
      }
      let location = view.convert(point, to: nil)
      let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: .command, timestamp: 0, windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: .command, timestamp: 0.01, windowNumber: target.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
      hit?.mouseDown(with: down)
      hit?.mouseUp(with: up)
    }
    XCTAssertEqual(selected, 3)
    XCTAssertEqual(closed, 0)
  }

  func testTileCornerKeepsIconStationary() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 90, height: 60))
    let icon = NSView(frame: CGRect(x: 37, y: 22, width: 16, height: 16))
    parent.addSubview(icon)
    let hint = TabNumberHintView()
    parent.addSubview(hint)
    let target = HintKeyWindow(contentRect: parent.bounds, styleMask: [], backing: .buffered, defer: true)
    target.contentView = parent
    defer { TabNumberHintFeed.shared.cancel() }
    hint.configure(actions: ["selectTab:1"], enabled: true, style: .tile)
    hint.present(icon: icon)
    show(target)
    XCTAssertEqual(hint.frame.maxX, 82)
    XCTAssertEqual(hint.frame.maxY, 56)
    XCTAssertEqual(icon.frame, CGRect(x: 37, y: 22, width: 16, height: 16))
    XCTAssertNil(icon.layer?.animation(forKey: "tabNumberHintNudge"))
  }
}

@MainActor
private final class HintKeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
