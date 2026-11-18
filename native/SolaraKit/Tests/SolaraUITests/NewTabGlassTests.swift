import AppKit
import SolaraOmnibox
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct NewTabGlassTests {
  private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    view.subviews.flatMap { child in
      (child as? T).map { [$0] } ?? []
    } + view.subviews.flatMap { descendants($0, of: type) }
  }

  @Test func theFullMarkSharesTheGlassCanvasAtItsOriginalOrigin() throws {
    let hero = NewTabHeroView(frame: NSRect(x: 0, y: 0, width: 1201, height: 800))
    hero.layout()
    let glass = try #require(descendants(hero, of: NSGlassEffectView.self).first)
    let mark = try #require(descendants(hero, of: MarkView.self).first)
    let container = try #require(descendants(hero, of: NSGlassEffectContainerView.self).first)
    let frames = NewTabLayout.frames(size: hero.bounds.size, under: 0, headingHeight: 0, barHeight: NewTabLayout.barHeight, scale: 2)
    #expect(glass.style == .regular)
    #expect(glass.frame == frames.bar)
    #expect(glass.cornerRadius == NewTabLayout.barRadius)
    #expect(mark.frame.origin == frames.mark.origin)
    #expect(mark.frame.size == CGSize(width: NewTabLayout.markSize, height: NewTabLayout.markSize))
    #expect(mark.frame.maxY > glass.frame.minY)
    #expect(mark.superview === glass.superview)
    #expect(mark.isDescendant(of: container))
    let children = try #require(mark.superview?.subviews)
    #expect(children.firstIndex(of: mark)! < children.firstIndex(of: glass)!)
  }

  @Test func theHeroContentLivesInsideTheGlass() throws {
    let hero = NewTabHeroView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    hero.configure(NewTabIdentity(windowId: "glass-window", tabId: "glass-tab", profileId: "glass-profile"))
    hero.layoutSubtreeIfNeeded()
    let glass = try #require(descendants(hero, of: NSGlassEffectView.self).first)
    let content = try #require(descendants(hero, of: NSHostingView<AnyView>.self).first)
    #expect(content.isDescendant(of: glass))
    #expect(content.frame == glass.bounds.insetBy(dx: NewTabLayout.barBorder, dy: NewTabLayout.barBorder))
  }

  @Test func thePanelUsesItsProfileAppearanceAndKeepsContentAtTheTargetFrame() throws {
    let bar = OmniboxBarView(frame: .zero)
    bar.theme = .fallbackDark
    let host = OmniboxPanelHostView(bar: bar)
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let target = OmniboxPanelPlacement(left: 100, top: 200, width: 652, from: nil)
    host.show(target, identity: OmniboxBarIdentity(windowId: "glass-window", tabId: "glass-tab", profileId: "glass-profile", variant: .hero, opensTab: true, initialText: ""))
    defer { host.hide() }
    let glass = try #require(descendants(host, of: NSGlassEffectView.self).first)
    #expect(glass.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    #expect(glass.frame.origin == CGPoint(x: target.left, y: target.top))
    #expect(glass.frame.width == target.width)
    #expect(bar.isDescendant(of: glass))
    #expect(bar.convert(bar.bounds, to: host) == glass.frame)
  }

  private func settle(_ view: NSView, until ready: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      view.layoutSubtreeIfNeeded()
      if ready() { return true }
      RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    } while Date() < deadline && view.window != nil
    return ready()
  }

  private func accessibilityValue(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
  }

  private func accessibleButtons(_ root: Any, depth: Int = 0) -> [NSObject] {
    guard depth < 16, let object = root as? NSObject else { return [] }
    let own = accessibilityValue(object, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue ? [object] : []
    let children = accessibilityValue(object, "accessibilityChildren") as? [NSObject] ?? []
    return own + children.flatMap { accessibleButtons($0, depth: depth + 1) }
  }

  private func accessibilityLabel(_ object: NSObject) -> String? {
    accessibilityValue(object, "accessibilityLabel") as? String ?? accessibilityValue(object, "accessibilityTitle") as? String
  }

  @Test(arguments: [false, true]) func tallResultsKeepGlassAndBottomControlsAligned(dark: Bool) throws {
    _ = NSApplication.shared
    let accessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let originalAccessibility = NSApp.accessibilityAttributeValue(accessibility)
    NSApp.accessibilitySetValue(true, forAttribute: accessibility)
    defer { NSApp.accessibilitySetValue(originalAccessibility ?? false, forAttribute: accessibility) }
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: NSRect(origin: .zero, size: window.contentView!.bounds.size))
    window.contentView = hero
    hero.theme = dark ? .fallbackDark : .fallbackLight
    let profile = UUID().uuidString
    hero.configure(NewTabIdentity(windowId: UUID().uuidString, tabId: UUID().uuidString, profileId: profile))
    let model = try #require(hero.model)
    defer { model.sources.setHistory([], profileId: profile) }
    model.sources.setHistory((0..<9).map { i in
      HistoryRow(url: "https://glass-\(i).example/", title: "Glass reference \(i) — a long title for layered material legibility", favicon: nil, visits: Double(20 - i), lastVisit: Date().timeIntervalSince1970 * 1000 - Double(i))
    }, profileId: profile)
    #expect(settle(hero) { hero.barFrame.height == NewTabLayout.barHeight })
    let resting = hero.barFrame
    let glass = try #require(descendants(hero, of: NSGlassEffectView.self).first)
    let mark = try #require(descendants(hero, of: MarkView.self).first)
    let restingMark = mark.frame
    model.driverType("glass")
    #expect(settle(hero) { model.items.count == 8 && hero.barFrame.height == resting.height + 322 })
    #expect(glass.frame == hero.barFrame)
    #expect(glass.frame.origin == resting.origin)
    #expect(glass.cornerRadius == NewTabLayout.barRadius)
    #expect(mark.frame == restingMark)
    #expect(mark.frame.height == NewTabLayout.markSize)
    #expect(mark.frame.maxY > glass.frame.minY)
    let hosting = try #require(descendants(hero, of: NSHostingView<AnyView>.self).first)
    #expect(hosting.frame == glass.bounds.insetBy(dx: NewTabLayout.barBorder, dy: NewTabLayout.barBorder))
    #expect(settle(hero) { accessibleButtons(hosting).contains { accessibilityLabel($0) == model.goLabel } })
    let buttons = accessibleButtons(hosting)
    let go = try #require(buttons.first { accessibilityLabel($0) == model.goLabel })
    let open = try #require(buttons.first { accessibilityLabel($0)?.contains("Open a tab or file") == true })
    for button in [go, open] {
      let selector = NSSelectorFromString("accessibilityFrame")
      try #require(button.responds(to: selector))
      typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
      let frame = unsafeBitCast(button.method(for: selector), to: Frame.self)(button, selector)
      let rect = hero.convert(window.convertFromScreen(frame), from: nil)
      #expect(rect.width > 30)
      #expect(rect.height >= 30)
      #expect(rect.minY > glass.frame.maxY - 60)
      #expect(glass.frame.contains(rect))
      let point = hero.convert(CGPoint(x: rect.midX, y: rect.midY), to: hero.superview)
      #expect(hero.hitTest(point)?.isDescendant(of: hosting) == true)
    }
    model.driverType("")
    #expect(settle(hero) { model.items.isEmpty && hero.barFrame == resting })
    #expect(glass.frame == resting)
    #expect(glass.cornerRadius == NewTabLayout.barRadius)
    #expect(mark.frame == restingMark)
  }

  #if SOLARA_PROBES
  @Test func showingBeforeMountSettlesWithoutStartingAWindowFrameLink() throws {
    let host = OmniboxPanelHostView(bar: OmniboxBarView(frame: .zero))
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let baseline = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int
    let placement = OmniboxPanelPlacement(left: 100, top: 200, width: 652, from: CGRect(x: 50, y: 300, width: 600, height: 112))
    host.show(placement, identity: OmniboxBarIdentity(windowId: "glass-window", tabId: "glass-tab", profileId: "glass-profile", variant: .hero, opensTab: true, initialText: ""))
    defer { host.hide() }
    let glass = try #require(descendants(host, of: NSGlassEffectView.self).first)
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
    #expect(glass.frame.origin == CGPoint(x: placement.left, y: placement.top))
    #expect(glass.frame.width == placement.width)
    #expect(glass.cornerRadius == host.style.radius)
  }

  @Test func resizingAVisibleHostKeepsItsGlassCanvasAndHitRegionCurrent() throws {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
    let host = OmniboxPanelHostView(bar: OmniboxBarView(frame: .zero))
    root.addSubview(host)
    host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let placement = OmniboxPanelPlacement(left: 100, top: 200, width: 652, from: nil)
    let identity = OmniboxBarIdentity(windowId: "glass-window", tabId: "glass-tab", profileId: "glass-profile", variant: .hero, opensTab: true, initialText: "")
    host.show(placement, identity: identity)
    defer { host.hide() }
    root.layoutSubtreeIfNeeded()
    let field = try #require(descendants(host.bar, of: NSTextField.self).first)
    let beforeFrame = host.convert(field.bounds, from: field)
    let before = host.hitTest(host.convert(CGPoint(x: beforeFrame.midX, y: beforeFrame.midY), to: root))
    #expect(before?.isDescendant(of: host.bar) == true)
    host.frame.size = CGSize(width: 1200, height: 900)
    host.show(placement, identity: identity)
    root.layoutSubtreeIfNeeded()
    let container = try #require(descendants(host, of: NSGlassEffectContainerView.self).first)
    let canvas = try #require(container.contentView)
    #expect(container.frame == host.bounds)
    #expect(canvas.frame == container.bounds)
    let fieldFrame = host.convert(field.bounds, from: field)
    let point = CGPoint(x: fieldFrame.maxX - 4, y: fieldFrame.midY)
    #expect(point.x > 700)
    let hit = host.hitTest(host.convert(point, to: root))
    #expect(hit?.isDescendant(of: host.bar) == true)
  }

  @Test func hidingRemountingAndDetachingRetireThePanelFrameLink() throws {
    _ = NSApplication.shared
    weak var retained: OmniboxPanelHostView?
    try autoreleasepool {
      let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let root = NSView(frame: window.contentView!.bounds)
      window.contentView = root
      let bar = OmniboxBarView(frame: .zero)
      var host: OmniboxPanelHostView? = OmniboxPanelHostView(bar: bar)
      retained = host
      host!.frame = root.bounds
      root.addSubview(host!)
      let target = OmniboxPanelPlacement(left: 100, top: 200, width: 652, from: CGRect(x: 50, y: 300, width: 600, height: 112))
      let identity = OmniboxBarIdentity(windowId: "glass-window", tabId: "glass-tab", profileId: "glass-profile", variant: .hero, opensTab: true, initialText: "")
      let baseline = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int
      host!.show(target, identity: identity)
      #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline.map { $0 + 1 })
      host!.hide()
      #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
      host!.show(target, identity: identity)
      #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline.map { $0 + 1 })
      host!.removeFromSuperview()
      #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
      let glass = try #require(descendants(host!, of: NSGlassEffectView.self).first)
      #expect(glass.frame.origin == CGPoint(x: target.left, y: target.top))
      #expect(glass.cornerRadius == host!.style.radius)
      host = nil
    }
    #expect(retained == nil)
  }
  #endif

}
