import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

struct DragCarrySpringTests {
  @Test func motionWithinOneTargetKeepsTheSystemHoverTimer() {
    var spring = DragCarrySpring()
    let firstChanged = spring.update(.tab("b"), sequence: 1)
    let motionChanged = spring.update(.tab("b"), sequence: 1)
    #expect(firstChanged)
    #expect(!motionChanged)
    #expect(spring.activate(.tab("b"), sequence: 1) == .tab("b"))
    let activatedChanged = spring.update(.tab("b"), sequence: 1)
    #expect(!activatedChanged)
    #expect(spring.activate(.tab("b"), sequence: 1) == nil)
  }

  @Test func crossingTargetsResetsTheSystemHoverTimerAndRejectsItsOldActivation() {
    var spring = DragCarrySpring()
    spring.update(.tab("b"), sequence: 1)
    let crossed = spring.update(.profile("work"), sequence: 1)
    #expect(crossed)
    #expect(spring.activate(.tab("b"), sequence: 1) == nil)
    #expect(spring.activate(.profile("work"), sequence: 1) == .profile("work"))
  }

  @Test func emptySpaceAndExitCancelPendingActivation() {
    var spring = DragCarrySpring()
    spring.update(.tab("b"), sequence: 1)
    let cleared = spring.update(nil, sequence: 1)
    #expect(cleared)
    #expect(spring.activate(.tab("b"), sequence: 1) == nil)
    spring.update(.tab("b"), sequence: 1)
    spring.cancel()
    #expect(spring.target == nil)
    #expect(spring.activate(.tab("b"), sequence: 1) == nil)
    let rearmed = spring.update(.tab("b"), sequence: 1)
    #expect(rearmed)
    #expect(spring.activate(.tab("b"), sequence: 1) == .tab("b"))
  }

  @Test func aNewDragRearmsTheSameTargetAndRejectsAnOldDrag() {
    var spring = DragCarrySpring()
    spring.update(.tab("b"), sequence: 1)
    #expect(spring.activate(.tab("b"), sequence: 1) == .tab("b"))
    let changedSequence = spring.update(.tab("b"), sequence: 2)
    #expect(changedSequence)
    #expect(spring.activate(.tab("b"), sequence: 1) == nil)
    #expect(spring.activate(.tab("b"), sequence: 2) == .tab("b"))
  }

  @Test func activationRevalidatesThePointerTarget() {
    var spring = DragCarrySpring()
    spring.update(.tab("b"), sequence: 1)
    #expect(spring.activate(nil, sequence: 1) == nil)
    #expect(spring.activate(.tab("c"), sequence: 1) == nil)
    #expect(spring.activate(.tab("b"), sequence: 1) == .tab("b"))
  }
}

@MainActor
@Suite(.serialized)
struct DragCarryTargetTests {
  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse("""
      {"profileOrder":["p","q"],"windowOrder":["w"],
      "windows":{"w":{"id":"w","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"a"}}},
      "tabs":{"a":{"id":"a","windowId":"w","profileId":"p","url":"https://a.example/","title":"A"},
      "b":{"id":"b","windowId":"w","profileId":"p","url":"https://b.example/","title":"B"}}}
      """).object ?? [:])
  }

  @Test func sidebarTargetsOnlyInactiveVisibleTabsAndStopsAfterRetirement() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let sidebar = SidebarView(windowId: "w")
    window.contentView = sidebar
    sidebar.update(state: try state(), host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    defer { sidebar.stop(); window.contentView = nil; window.close() }
    let a = try #require(sidebar.frameOf("a"))
    let b = try #require(sidebar.frameOf("b"))
    let aPoint = sidebar.convert(CGPoint(x: a.midX, y: a.midY), to: nil)
    let bPoint = sidebar.convert(CGPoint(x: b.midX, y: b.midY), to: nil)
    #expect(sidebar.dragCarryTab(at: aPoint) == nil)
    #expect(sidebar.dragCarryTab(at: bPoint) == "b")
    #expect(sidebar.dragCarryTab(at: CGPoint(x: -20, y: -20)) == nil)
    sidebar.isHidden = true
    #expect(sidebar.dragCarryTab(at: bPoint) == nil)
    sidebar.isHidden = false
    sidebar.stop()
    #expect(sidebar.dragCarryTab(at: bPoint) == nil)
  }

  @Test func profileSlotsRevalidateSelectionRemovalAndVisibility() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let chrome = SidebarChromeView()
    window.contentView = chrome
    var look = SidebarChromeState(
      controls: StripControlsState(title: "P", incognito: false, profiles: 2, nameColor: "#000000", downloadsOpen: false, downloadsTooltip: nil),
      downloads: false, addressBar: false, dark: false, theme: [:],
      dots: [SidebarChromeDot(id: "p", name: "P", slot: 0), SidebarChromeDot(id: "q", name: "Q", slot: 1)],
      savedWidth: 240, currentProfileId: "p")
    chrome.update(look)
    chrome.layoutSubtreeIfNeeded()
    defer { window.contentView = nil; window.close() }
    func dot(_ view: NSView) -> SidebarProfileDot? {
      if let dot = view as? SidebarProfileDot, dot.profileId == "q" { return dot }
      return view.subviews.compactMap(dot).first
    }
    let q = try #require(dot(chrome))
    let point = q.convert(CGPoint(x: q.bounds.midX, y: q.bounds.midY), to: nil)
    #expect(chrome.dragCarryProfile(at: point) == "q")
    look.currentProfileId = "q"
    chrome.update(look)
    #expect(chrome.dragCarryProfile(at: point) == nil)
    look.currentProfileId = "p"
    chrome.update(look)
    chrome.isHidden = true
    #expect(chrome.dragCarryProfile(at: point) == nil)
    chrome.isHidden = false
    look.dots.removeLast()
    chrome.update(look)
    #expect(chrome.dragCarryProfile(at: point) == nil)
  }

  @Test func stripTargetsTheHoveredTabWithoutSelectingIt() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 42), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let strip = TopStripView(windowId: "w")
    window.contentView = strip
    strip.update(state: try state(), host: StripHostState(profileId: "p"))
    strip.layoutSubtreeIfNeeded()
    defer { strip.stop(); window.contentView = nil; window.close() }
    func chip(_ view: NSView) -> StripTabChip? {
      if let chip = view as? StripTabChip, chip.tabId == "b" { return chip }
      return view.subviews.compactMap(chip).first
    }
    let b = try #require(chip(strip))
    let point = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    #expect(strip.current?.dragCarryTab(at: point) == "b")
    #expect(b.accessibleSelected == false)
    #expect(strip.current?.dragCarryTab(at: CGPoint(x: -20, y: -20)) == nil)
  }
}
