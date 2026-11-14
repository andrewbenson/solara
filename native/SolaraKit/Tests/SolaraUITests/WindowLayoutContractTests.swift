import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct WindowLayoutContractTests {
  @Test func placementKeepsPageAndGuestIdentityAcrossLayoutModes() {
    let shell = WindowShellView(windowId: "contract")
    shell.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let page = NSView(), sidebar = NSView(), strip = NSView()
    shell.cardPage.addSubview(page)
    shell.mount(.sidebar, sidebar)
    shell.mount(.topStrip, strip)
    #expect(shell.frames.card == CGRect(x: 190, y: 6, width: 803, height: 687))
    #expect(shell.frames.sidebar == CGRect(x: 0, y: 0, width: 190, height: 700))
    shell.update { $0.topTabs = true }
    #expect(sidebar.isHidden)
    #expect(!strip.isHidden)
    #expect(shell.cardPage.subviews.first === page)
    shell.update { $0.fullscreen = true }
    #expect(sidebar.isHidden && strip.isHidden)
    #expect(shell.cardPage.subviews.first === page)
    shell.update { $0.fullscreen = false; $0.topTabs = false; $0.dock = 0 }
    #expect(shell.view(in: .sidebar) === sidebar)
    #expect(shell.view(in: .topStrip) === strip)
    #expect(shell.cardPage.subviews.first === page)
    #expect(shell.subviews.filter { $0 === sidebar }.count == 1)
  }

  #if SOLARA_PROBES
  private final class LinkTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {}
  }

  @Test func activeLinkGaugeFollowsPauseResumeResetAndInvalidation() {
    let view = NSView(), target = LinkTarget()
    let link = view.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
    let baseline = NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int ?? -1
    NativeWorkCounters.link(link)
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline + 1)
    link.isPaused = true
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
    NativeWorkCounters.reset()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
    link.isPaused = false
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline + 1)
    NativeWorkCounters.unlink(link)
    link.invalidate()
    #expect(NativeWorkCounters.snapshot()["activeAnimationLinks"] as? Int == baseline)
  }

  @Test func resetPreservesLiveIdentityAndAggregatesEveryScope() throws {
    NativeWorkCounters.reset()
    let first = NSView(), second = NSView()
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    NativeWorkCounters.bind(second, windowId: "counter-b", profileId: "q", kind: "tile")
    let before = NativeWorkCounters.snapshot()
    #expect(before["version"] as? Int == 1)
    let rows = try #require(before["rows"] as? [String: Int])
    #expect(rows["created"] == 2)
    #expect(rows["bound"] == 3)
    #expect(rows["reused"] == 1)
    let groups = try #require(before["groups"] as? [[String: Any]])
    for field in ["created", "bound", "reused", "live"] {
      #expect(groups.reduce(0) { $0 + ($1[field] as? Int ?? -1) } == rows[field])
    }
    NativeWorkCounters.reset()
    let after = try #require(NativeWorkCounters.snapshot()["rows"] as? [String: Int])
    #expect(after["created"] == 0 && after["bound"] == 0 && after["reused"] == 0)
    #expect(after["live"] == rows["live"])
    NativeWorkCounters.bind(first, windowId: "counter-a", profileId: "p", kind: "tab")
    #expect((NativeWorkCounters.snapshot()["rows"] as? [String: Int])?["reused"] == 1)
  }

  @Test func liveRowsIncludeDetachedObjectsAndDisappearAtDeallocation() throws {
    NativeWorkCounters.reset()
    var view: NSView? = NSView()
    NativeWorkCounters.bind(view!, windowId: "detached", profileId: "p", kind: "tab")
    func count() -> Int {
      (NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == "detached" }?["live"] as? Int ?? 0
    }
    #expect(count() == 1)
    NativeWorkCounters.reset()
    #expect(count() == 1)
    view = nil
    #expect(count() == 0)
  }

  @Test func fixedViewportCurrentlyCreatesEverySidebarRow() throws {
    for total in [200, 2000] {
      NativeWorkCounters.reset()
      let windowId = "eager-\(total)"
      let tabs = (0..<total).map { "\"t\($0)\":{\"id\":\"t\($0)\",\"windowId\":\"\(windowId)\",\"profileId\":\"p\",\"url\":\"https://fixture.test/\($0)\",\"title\":\"Tab \($0)\"}" }.joined(separator: ",")
      let ids = (0..<total).map { "\"t\($0)\"" }.joined(separator: ",")
      let json = "{\"windows\":{\"\(windowId)\":{\"id\":\"\(windowId)\",\"profileId\":\"p\",\"tabIds\":[\(ids)],\"activeTabIds\":{\"p\":\"t0\"}}},\"tabs\":{\(tabs)}}"
      let state = try BrowserState(stateJSON: try JSONValue.parse(json).object ?? [:])
      let sidebar = SidebarView(windowId: windowId)
      sidebar.frame = CGRect(x: 0, y: 0, width: 190, height: 400)
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      let group = try #require((NativeWorkCounters.snapshot()["groups"] as? [[String: Any]])?.first { $0["windowId"] as? String == windowId && $0["kind"] as? String == "sidebar.tab.full" })
      #expect(group["created"] as? Int == total)
      #expect(group["live"] as? Int == total)
      #expect(sidebar.pageLayout.items.filter { if case .tab = $0.kind { true } else { false } }.count == total)
      let views = sidebar.views
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      #expect(views.allSatisfy { sidebar.views[$0.key] === $0.value })
      #expect(sidebar.pageLayout.docked)
    }
  }
  #endif
}
