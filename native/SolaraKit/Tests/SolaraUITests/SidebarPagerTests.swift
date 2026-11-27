import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func pagedState() throws -> BrowserState {
  let text = #"""
    {"profileOrder": ["p", "q", "r"],
     "windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b", "c"], "activeTabIds": {"p": "a", "q": "b", "r": "c"}}},
     "windowOrder": ["w1"],
     "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/"},
              "b": {"id": "b", "windowId": "w1", "profileId": "q", "url": "https://b.example/"},
              "c": {"id": "c", "windowId": "w1", "profileId": "r", "url": "https://c.example/"}}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private func host(_ profileId: String) -> SidebarHostState {
  var out = SidebarHostState(profileId: profileId)
  out.pages = ["p", "q", "r"].map {
    SidebarPageLook(profileId: $0, dark: true, theme: [:], border: [], glow: out.glow, tidy: false, incognito: false)
  }
  return out
}

@MainActor
private func shown(_ pager: SidebarPagerView) -> [String] {
  pager.describePages().compactMap { page in
    guard let id = page["id"] as? String, page["hidden"] as? Bool == false, let x = page["x"] as? CGFloat else { return nil }
    return "\(id)@\(Int(x))"
  }
}

@MainActor
@Suite struct SidebarPagerTests {
  private func pager() throws -> SidebarPagerView {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    pager.update(state: try pagedState(), host: host("p"))
    return pager
  }

  private func stacks(_ view: NSView) -> [SidebarPlayerStack] {
    view.subviews.flatMap { ($0 as? SidebarPlayerStack).map { [$0] } ?? stacks($0) }
  }

  private func playerFrame(_ pager: SidebarPagerView) -> [CGFloat] {
    ["x", "y", "width", "height"].compactMap { pager.playerDescription[$0] as? CGFloat }
  }

  @Test func footerProfilesFollowWorkspaceOrderAndHideInPrivateWindows() throws {
    var state = try pagedState()
    #expect(SidebarPagerView.profileIDs(state: state, windowId: "w1") == ["p", "q", "r"])
    state.windows["w1"]?.incognito = true
    #expect(SidebarPagerView.profileIDs(state: state, windowId: "w1").isEmpty)
  }

  @Test func theMiniPlayerStaysPutWhileProfilePagesSlide() throws {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    var home = host("p")
    home.player = SidebarPlayerCoverageTests.playerState()
    pager.update(state: try pagedState(), host: home)
    let resting = playerFrame(pager)
    #expect(resting.count == 4)
    #expect((resting.first ?? -1) >= 0 && (resting.first ?? 0) + resting[2] <= 200)
    for position in [0.5, 0.9, 0.3, 0.0] {
      pager.setPagerPosition(position)
      #expect(playerFrame(pager) == resting)
      #expect(pager.playerDescription["driver"] as? String == "p")
      #expect(stacks(pager).count == 1)
    }
    var next = host("q")
    next.player = SidebarPlayerCoverageTests.playerState()
    pager.setPagerPosition(0.7)
    pager.update(state: try pagedState(), host: next)
    #expect(playerFrame(pager) == resting)
    #expect(pager.playerDescription["driver"] as? String == "q")
    pager.setPagerPosition(1)
    #expect(playerFrame(pager) == resting)
    #expect(pager.playerDescription["hidden"] as? Bool == false)
    #expect(stacks(pager).count == 1)
    #expect(pager.subviews.last is SidebarPlayerStack)
    pager.frame = NSRect(x: 0, y: 0, width: 260, height: 480)
    pager.layoutSubtreeIfNeeded()
    let wider = playerFrame(pager)
    #expect(wider.count == 4 && wider != resting)
    #expect(wider.count == 4 && wider[0] + wider[2] <= 260 && wider[2] > resting[2])
    #expect(wider.count == 4 && wider[1] + wider[3] > resting[1] + resting[3])
  }

  @Test func atRestOnlyTheCurrentProfileShows() throws {
    let pager = try pager()
    #expect(shown(pager) == ["p@0"])
  }

  @Test func neighbouringPagesSlideWithThePager() throws {
    let pager = try pager()
    pager.setPagerPosition(0.5)
    #expect(shown(pager) == ["p@-100", "q@100"])
    pager.setPagerPosition(1.75)
    #expect(shown(pager) == ["q@-150", "r@50"])
  }

  @Test func theEdgesRubberBandPastTheFirstAndLastProfile() throws {
    let pager = try pager()
    pager.setPagerPosition(-0.2)
    #expect(shown(pager) == ["p@40"])
  }

  @Test func aCommitMidSpringKeepsThePagerPosition() throws {
    let pager = try pager()
    pager.setPagerPosition(0.6)
    pager.update(state: try pagedState(), host: host("q"))
    #expect(shown(pager) == ["p@-120", "q@80"])
    pager.setPagerPosition(1)
    #expect(shown(pager) == ["q@0"])
  }

  @Test func aSwitchThatBypassesThePagerShowsTheNewProfile() throws {
    let pager = try pager()
    pager.setPagerPosition(0)
    pager.update(state: try pagedState(), host: host("r"))
    #expect(shown(pager) == ["r@0"])
  }

  @Test func withoutPagesOnlyTheCurrentProfileIsLaidOut() throws {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    pager.update(state: try pagedState(), host: SidebarHostState(profileId: "q"))
    pager.setPagerPosition(0.5)
    #expect(shown(pager) == ["q@0"])
  }
}
