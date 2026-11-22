import AppKit
import QuartzCore
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@Suite @MainActor struct NewTabPlaceholderUITests {
  private func state(position: String = "top", grouped: Bool = false, collapsed: Bool = false) throws -> BrowserState {
    let group = grouped ? #"{"g":{"id":"g","windowId":"w","profileId":"p","name":"Group","tabIds":["a","b"],"collapsed":\#(collapsed)}}"# : "{}"
    let text = #"""
      {"settings":{"newTabPosition":"\#(position)","newTabOpens":"commandBar"},
      "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","empty","b"],"activeTabIds":{"p":"empty"}}},
      "windowOrder":["w"],"groups":\#(group),
      "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"},
      "empty":{"id":"empty","windowId":"w","profileId":"p","url":"","title":"","newTabPlaceholder":true},
      "b":{"id":"b","windowId":"w","profileId":"p","url":"","title":"","navigation":{"url":"about:blank","seq":1}}}}
      """#
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func layout(_ state: BrowserState, rail: Bool = false, height: CGFloat = 600) -> SidebarPageLayout {
    let query = SidebarQuery(state)
    var input = SidebarLayoutInput(windowId: "w", profileId: "p", width: rail ? 54 : 200, height: height)
    input.rail = rail
    input.newTabAtTop = state.settings.string("newTabPosition") == "top"
    return SidebarLayout(query: query, input: input).layout(query.entries(windowId: "w", profileId: "p"))
  }

  @Test func placeholderUsesThePlusRowAndSettledEmptyCommandBarTabsStayVisible() throws {
    let state = try state()
    let query = SidebarQuery(state)
    #expect(query.newTabPlaceholder(windowId: "w") == "empty")
    #expect(query.entries(windowId: "w").list == ["t:a", "t:b"])
    #expect(StripQuery(state).keys(windowId: "w", profileId: "p") == ["tab:a:", "tab:b:"])
    #expect(query.numberedRows(windowId: "w").map(\.tabId) == ["a", "b"])
    for rail in [false, true] {
      let out = layout(state, rail: rail)
      #expect(out.items.filter { $0.kind == .newTab }.count == 1)
      #expect(out.item("t:empty") == nil)
      #expect(out.item("newTab")!.frame.minY < out.item("t:a")!.frame.minY)
    }
  }

  @Test func belowCurrentPlacesThePlusImmediatelyBelowTheSourceEvenInAShortViewport() throws {
    let state = try state(position: "nextToCurrent")
    for rail in [false, true] {
      let out = layout(state, rail: rail, height: 70)
      #expect(!out.docked)
      #expect(out.item("newTab")!.frame.minY > out.item("t:a")!.frame.minY)
      #expect(out.item("newTab")!.frame.maxY < out.item("t:b")!.frame.minY)
    }
  }

  @Test func groupedBelowCurrentKeepsTheSourceAndPlusTogether() throws {
    for collapsed in [false, true] {
      let state = try state(position: "nextToCurrent", grouped: true, collapsed: collapsed)
      let out = layout(state)
      #expect(out.items.filter { $0.kind == .newTab }.count == 1)
      #expect(out.item("newTab")!.groups == ["g"])
      #expect(out.item("newTab")!.frame.minY > out.item("t:a")!.frame.minY)
      if !collapsed { #expect(out.item("newTab")!.frame.maxY < out.item("t:b")!.frame.minY) }
      let rail = layout(state, rail: true)
      #expect(rail.items.filter { $0.kind == .newTab }.count == 1)
      #expect(rail.item("newTab")!.frame.minY > rail.item("gh:g")!.frame.minY)
    }
  }

  @Test func theHorizontalPlusUsesTheBelowCurrentSlotWithoutAnExtraChip() throws {
    let state = try state(position: "nextToCurrent")
    let query = SidebarQuery(state)
    let out = StripPageLayout(entries: StripQuery(state).entries(windowId: "w", profileId: "p"), activeId: "empty", pageWidth: 800,
      flare: StripMetrics.flare, chipWidth: { _ in 50 }, folderWidth: { _ in 50 },
      newTabAfter: query.newTabPlaceholderPredecessor(windowId: "w", profileId: "p"))
    #expect(out.items.map(\.key) == ["tab:a", "newTab", "tab:b"])
    #expect(out.items[1].x > out.items[0].x)
    #expect(out.items[1].x + out.items[1].width < out.items[2].x)
    #expect(out.topStart + out.top.lefts[1] == out.items[2].x)
  }

  @Test func theHorizontalPlusSitsAfterTheSourceInsideExpandedAndCollapsedGroups() throws {
    for collapsed in [false, true] {
      let state = try state(position: "nextToCurrent", grouped: true, collapsed: collapsed)
      let out = StripPageLayout(entries: StripQuery(state).entries(windowId: "w", profileId: "p"), activeId: "a", pageWidth: 800,
        flare: StripMetrics.flare, chipWidth: { _ in 50 }, folderWidth: { _ in 50 }, newTabAfter: "a")
      let plus = out.items.first { $0.key == "newTab" }!
      guard let placed = out.items.first(where: { $0.key == "group:g" }), case .group(let group) = placed.kind else {
        Issue.record("Missing group")
        return
      }
      let source = out.span(of: "a")!
      #expect(plus.x == source.x + source.width + StripMetrics.gap)
      #expect(group.newTabAfterIndex == 0)
      #expect(plus.x + plus.width < placed.x + group.width)
      if !collapsed {
        let next = out.span(of: "b")!
        #expect(plus.x + plus.width + StripMetrics.gap == next.x)
        #expect(group.geometry.lefts[1] == group.members[1].offset)
      } else {
        #expect(group.shown == 0)
      }
    }
  }

  @Test func thePlusRowAndIconExposeTheSelectedPlaceholder() throws {
    let state = try state()
    let host = SidebarHostState(profileId: "p")
    let context = SidebarContext(state: state, host: host, windowId: "w", favicons: SidebarFavicons(), ownsWorkspace: true)
    #expect(context.newTabSelected)
    let item = layout(state).item("newTab")!
    for row in [NewTabRowView(frame: .zero), RailNewTabView(frame: .zero)] as [SidebarRowView] {
      row.update(item, context)
      #expect((row.accessibilityValue() as? NSNumber)?.boolValue == true)
    }
  }

  @Test func settlingAnimatesTheNewRowWithTheExistingSlideSpring() throws {
    let before = try state()
    var after = before
    after.tabs["empty"]!.newTabPlaceholder = nil
    #expect(NewTabOpening.settled(before, after) == ["empty"])
    #expect(NewTabOpening.settled(nil, after).isEmpty)
    #expect(NewTabOpening.settled(before, before).isEmpty)
    var discarded = before
    discarded.tabs.remove(["empty"])
    #expect(NewTabOpening.settled(before, discarded).isEmpty)
    for horizontal in [false, true] {
      let view = NSView(frame: .zero)
      view.wantsLayer = true
      NewTabOpening.apply(view, horizontal: horizontal)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let spring = view.layer?.animation(forKey: NewTabOpening.scaleKey) as? CASpringAnimation
        #expect(spring?.keyPath == (horizontal ? "transform.scale.x" : "transform.scale.y"))
        #expect(spring.map { Double($0.stiffness) } == Double(StripSpring.slide.stiffness))
        #expect(spring.map { Double($0.damping) } == Double(StripSpring.slide.damping))
        #expect(view.layer?.animation(forKey: NewTabOpening.fadeKey) != nil)
      }
    }
  }

  @Test func fieldEditsNotifyWithoutWaitingForNavigation() {
    let model = HeroBarModel(windowId: "w", tabId: "edited-placeholder-ui", profileId: "p", incognito: false, settings: { Settings(values: [:]) })
    var edits: [String] = []
    model.events.edited = { edits.append($0) }
    model.textChanged("hello", edit: nil)
    model.textChanged("", edit: nil)
    #expect(edits == ["hello", ""])
  }

  @Test func aMountedNewTabFieldTakesFirstResponderInItsAttachmentLayout() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    hero.configure(NewTabIdentity(windowId: "w", tabId: "mounted-placeholder-field", profileId: "p"))
    window.contentView?.addSubview(hero)
    hero.layoutSubtreeIfNeeded()
    let field = try #require(hero.model?.field)
    #expect(field.hasFocus)
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)
  }

  @Test func aNewTabConfiguredAfterMountTakesFirstResponderInItsAttachmentLayout() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView?.addSubview(hero)
    hero.configure(NewTabIdentity(windowId: "w", tabId: "configured-placeholder-field", profileId: "p"))
    hero.layoutSubtreeIfNeeded()
    let field = try #require(hero.model?.field)
    #expect(field.hasFocus)
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)
  }

  private final class LayoutCounter: NSView {
    var layouts = 0
    override func layout() {
      layouts += 1
      super.layout()
    }
  }

  @Test func configuringAnAttachedHeroDoesNotForceItsSubtreeToLayOut() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    let counter = LayoutCounter(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    hero.addSubview(counter)
    window.contentView?.addSubview(hero)
    counter.layouts = 0
    counter.needsLayout = true
    hero.configure(NewTabIdentity(windowId: "w", tabId: "no-eager-placeholder-layout", profileId: "p"))
    #expect(counter.layouts == 0)
    hero.layoutSubtreeIfNeeded()
    #expect(counter.layouts > 0)
  }

  @Test func aDetachedOrStaleFieldCannotConsumeTheNewTabsFocus() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = PlaceholderKeyWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    hero.panelOpen = true
    hero.configure(NewTabIdentity(windowId: "w", tabId: "reattached-placeholder-field", profileId: "p"))
    window.contentView?.addSubview(hero)
    hero.layoutSubtreeIfNeeded()
    let model = try #require(hero.model)
    let coordinator = try #require(model.field as? HeroFieldCoordinator)
    let field = try #require(coordinator.field)
    let parent = try #require(field.superview)
    field.removeFromSuperview()
    hero.panelOpen = false
    hero.focusAttachedField(field)
    #expect(!coordinator.hasFocus)
    let stale = HeroTextField(frame: .zero)
    stale.model = model
    window.contentView?.addSubview(stale)
    hero.focusAttachedField(stale)
    #expect(!coordinator.hasFocus)
    parent.addSubview(field)
    #expect(coordinator.hasFocus)
    #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
  }

  @Test func anAttachingHeroInAWindowThatIsNotKeyFocusesOnlyThatWindow() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let key = PlaceholderKeyWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    key.isReleasedWhenClosed = false
    defer { key.close() }
    let address = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
    key.contentView?.addSubview(address)
    #expect(key.makeFirstResponder(address))
    let keyResponder = key.firstResponder
    let window = PlaceholderKeyWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.key = false
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    hero.configure(NewTabIdentity(windowId: "w", tabId: "placeholder-in-background-window", profileId: "p"))
    window.contentView?.addSubview(hero)
    hero.layoutSubtreeIfNeeded()
    let coordinator = try #require(hero.model?.field as? HeroFieldCoordinator)
    let field = try #require(coordinator.field)
    hero.focusAttachedField(field)
    #expect(coordinator.hasFocus)
    #expect(key.firstResponder === keyResponder)
  }

  @Test func anAttachingHeroNeverTakesFocusFromAnotherFieldBeingTypedIn() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = PlaceholderKeyWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let address = NSTextField(frame: CGRect(x: 0, y: 660, width: 300, height: 24))
    window.contentView?.addSubview(address)
    #expect(window.makeFirstResponder(address))
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertText("typing", replacementRange: NSRange(location: NSNotFound, length: 0))
    let hero = NewTabHeroView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    hero.configure(NewTabIdentity(windowId: "w", tabId: "placeholder-under-address-field", profileId: "p"))
    window.contentView?.addSubview(hero)
    hero.layoutSubtreeIfNeeded()
    let coordinator = try #require(hero.model?.field as? HeroFieldCoordinator)
    let field = try #require(coordinator.field)
    hero.focusAttachedField(field)
    #expect(!coordinator.hasFocus)
    #expect(window.firstResponder === editor)
    #expect(address.stringValue == "typing" || editor.string == "typing")
  }
}

@MainActor
private final class PlaceholderKeyWindow: NSWindow {
  var key = true
  override var isKeyWindow: Bool { key }
  override var canBecomeKey: Bool { true }
}
