import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct SidebarAddressBarsTests {
  @Test func clearingTheStateKeepsAClaimedViewUntilItsRelease() {
    let bars = SidebarAddressBars()
    let view = bars.view("w1")
    bars.claim("w1")
    bars.set("w1", json: nil)
    #expect(bars.existing("w1") === view)
    #expect(bars.view("w1") === view)
    bars.release("w1")
    #expect(bars.existing("w1") == nil)
  }

  static let json = """
    {"palette":\(ToolbarWebKitPillTests.palette),"accent":"#D37B8B",
     "look":{"resting":"#FFFFFF","stroke":"#FFFFFF","hover":"#FFFFFF","placeholder":"#000000","prompt":"Search"},
     "buttons":[],"extensions":[]}
    """

  static func hosted(_ bar: SidebarAddressBarView, width: CGFloat = 84) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    bar.frame = CGRect(x: 0, y: 0, width: width, height: SidebarHeaderMetrics.height)
    window.contentView?.addSubview(bar)
    bar.layoutSubtreeIfNeeded()
    return window
  }

  @Test func aBarLaidOutBeforeAnyoneListenedReportsItsFieldWhenItsStateFirstArrives() throws {
    let bars = SidebarAddressBars()
    let bar = bars.view("w1")
    bars.claim("w1")
    let window = Self.hosted(bar)
    defer { bar.removeFromSuperview(); _ = window }
    var published: [[String: CGRect]] = []
    bars.onAnchors = { windowId, anchors in
      #expect(windowId == "w1")
      published.append(anchors)
    }
    bar.layoutSubtreeIfNeeded()
    #expect(published.isEmpty, "an unchanged layout reports nothing")
    bars.set("w1", json: Self.json)
    let field = try #require(published.last?["field"])
    #expect(published.count == 1)
    #expect(field.width == 84 - 2 * SidebarMetrics.inset && field.height > 0)
    bars.set("w1", json: Self.json)
    #expect(published.count == 1, "later state updates for a mounted bar don't report again")
    bars.set("w1", json: nil)
    bars.set("w1", json: Self.json)
    #expect(published.count == 2, "a remounted bar reports again")
    #expect(published.last?["field"] == field)
  }

  @Test func afterAReconnectTheNextStateReportsAgainOnce() throws {
    let bars = SidebarAddressBars()
    let bar = bars.view("w1")
    let window = Self.hosted(bar)
    defer { bar.removeFromSuperview(); _ = window }
    var published: [String] = []
    bars.onAnchors = { windowId, _ in published.append(windowId) }
    bars.set("w1", json: Self.json)
    #expect(published == ["w1"])
    bars.set("w1", json: Self.json)
    #expect(published == ["w1"])
    bars.reannounceOnNextSet()
    #expect(published == ["w1"], "nothing reports until the reconnected side sets its state")
    bars.set("w1", json: Self.json)
    #expect(published == ["w1", "w1"])
    bars.set("w1", json: Self.json)
    #expect(published == ["w1", "w1"])
  }

  @Test func clearingTheStateDropsAnUnclaimedView() {
    let bars = SidebarAddressBars()
    _ = bars.view("w1")
    bars.set("w1", json: nil)
    #expect(bars.existing("w1") == nil)
  }

  @Test func navigationMirrorUsesTheLiveSidebarStateWithoutItsField() throws {
    let bars = SidebarAddressBars()
    let row = bars.navigationView("w1")
    let json = """
      {"palette":\(ToolbarWebKitPillTests.palette),"accent":"#D37B8B",
       "look":{"resting":"#FFFFFF","stroke":"#FFFFFF","hover":"#FFFFFF","placeholder":"#000000","prompt":"Search"},
       "buttons":[{"id":"sidebar","icon":"sidebar.left"},{"id":"back","icon":"chevron.left","enabled":false},
         {"id":"forward","icon":"chevron.right"},{"id":"reload","icon":"arrow.clockwise"}],"extensions":[]}
      """
    bars.set("w1", json: json)
    let state = try #require(row.state)
    #expect(state.buttons.first { $0.id == "back" }?.enabled == false)
    bars.set("w1", json: json.replacingOccurrences(of: "false", with: "true"))
    #expect(row.state?.buttons.first { $0.id == "back" }?.enabled == true)
    row.frame = CGRect(x: 0, y: 0, width: 900, height: ShellMetrics.toolbarHeight)
    row.layoutSubtreeIfNeeded()
    #expect(row.navigationOnly)
    let hiddenFields = row.subviews.filter { $0 is ToolbarUrlFieldView }.allSatisfy(\.isHidden)
    #expect(hiddenFields)
    let buttons = row.subviews.compactMap { $0 as? ToolbarButtonView }.filter { !$0.isHidden }
    #expect(!buttons.isEmpty)
    for button in buttons {
      #expect(abs(button.frame.midY - ShellMetrics.toolbarHeight / 2) <= 0.5)
      #expect(button.frame.minX >= ShellMetrics.railLightsTrailing + 8)
    }
    bars.set("w1", json: nil)
    #expect(row.state == nil)
    #expect(row.navigationFrames.isEmpty)
    bars.set("w1", json: json.replacingOccurrences(of: "false", with: "true"))
    #expect(row.state?.buttons.first { $0.id == "back" }?.enabled == true)
    let parent = FlippedContainerView()
    parent.addSubview(row)
    bars.removeNavigationView("w1")
    #expect(row.superview == nil)
    #expect(bars.navigationView("w1") !== row)
    #expect(bars.navigationView("w1").state?.buttons.first { $0.id == "back" }?.enabled == true)
  }
}
