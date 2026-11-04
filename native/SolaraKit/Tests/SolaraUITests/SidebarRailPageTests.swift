import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite(.serialized) struct SidebarRailPageTests {
  private func state(split: Bool = true) throws -> BrowserState {
    let splits = split ? #", "splits":{"s":{"id":"s","windowId":"rail-pages","tabIds":["a","b"],"orientation":"horizontal","sizes":[0.5,0.5]}}"# : ""
    let text = #"""
      {"windows":{"rail-pages":{"id":"rail-pages","profileId":"p","tabIds":["a","b"],"activeTabIds":{"p":"a"}}},
       "windowOrder":["rail-pages"],"tabs":{"a":{"id":"a","windowId":"rail-pages","profileId":"p","url":"https://a.example/"},
       "b":{"id":"b","windowId":"rail-pages","profileId":"p","url":"https://b.example/"}}\#(splits)}
      """#
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func shell(width: CGFloat = CGFloat(SidebarRail.width)) -> WindowShellView {
    let shell = WindowShellView(windowId: "rail-pages")
    shell.frame = CGRect(x: 0, y: 0, width: 1201, height: 800)
    shell.update { $0.sidebarWidth = width }
    return shell
  }

  @Test func splitPagesAndOverlaySlotsStartBesideTheRailBelowTheToolbar() throws {
    let shell = shell()
    let panes = SplitPanesView(windowId: "rail-pages")
    panes.frame = shell.card.bounds
    shell.card.addSubview(panes)
    let overlays = PaneOverlaysView(windowId: "rail-pages")
    overlays.frame = shell.card.bounds
    shell.card.addSubview(overlays)
    defer { overlays.removeFromSuperview() }
    let state = try state()
    panes.update(state: state)
    overlays.update(state: state)
    shell.layoutSubtreeIfNeeded()
    let a = try #require(panes.container("a"))
    let b = try #require(panes.container("b"))
    #expect(a.convert(a.bounds, to: shell.card) == CGRect(x: 42, y: 47, width: 573, height: 746))
    #expect(b.convert(b.bounds, to: shell.card) == CGRect(x: 622, y: 47, width: 573, height: 746))
    for id in ["a", "b"] {
      let page = try #require(panes.container(id))
      let overlay = try #require(overlays.container(id, layer: .native))
      #expect(page.convert(page.bounds, to: shell.card) == overlay.convert(overlay.bounds, to: shell.card))
    }
  }

  @Test func splitChromePublishesTheSamePageBoundsAsThePaneContainers() throws {
    let shell = shell()
    let chrome = SplitChromeView(windowId: "rail-pages")
    shell.mount(.splitChrome, chrome)
    chrome.update(state: try state())
    shell.layoutSubtreeIfNeeded()
    #expect(chrome.panes["a"] == CGRect(x: 42, y: 47, width: 573, height: 746))
    #expect(chrome.panes["b"] == CGRect(x: 622, y: 47, width: 573, height: 746))
  }

  @Test func aSinglePooledPageOverlayUsesTheRailsPageArea() throws {
    let shell = shell()
    let overlays = PaneOverlaysView(windowId: "rail-pages")
    overlays.frame = shell.card.bounds
    shell.card.addSubview(overlays)
    defer { overlays.removeFromSuperview() }
    overlays.update(state: try state(split: false))
    overlays.pageTops = ["a": 41]
    shell.layoutSubtreeIfNeeded()
    let overlay = try #require(overlays.container("a", layer: .native))
    #expect(overlay.convert(overlay.bounds, to: shell.card) == CGRect(x: 42, y: 47, width: 1152, height: 746))
  }

  @Test func theActiveSplitToolbarSpansTheCardAndReturnsToItsPaneInFullMode() throws {
    let shell = shell()
    let panes = SplitPanesView(windowId: "rail-pages")
    panes.frame = shell.card.bounds
    panes.autoresizingMask = [.width, .height]
    shell.card.addSubview(panes)
    panes.update(state: try state())
    let toolbar = #"""
      {"tabId":"a","height":41,"bare":false,"focused":true,"accent":"#3478F6",
       "palette":{"text":"#000000","secondary":"#00000080","icon":"#000000D4","iconDisabled":"#0000006E","hover":"#0000000D","pressed":"#0000001A","pill":"#0000000A","divider":"#0000001A"},
       "geometry":{"back":21,"forward":57,"reload":92,"urlLeft":110,"urlRight":8},
       "left":[],"url":null,"right":[],"rightInset":8,"hairline":false}
      """#
    panes.setToolbars(["a": toolbar, "b": toolbar.replacingOccurrences(of: #""tabId":"a""#, with: #""tabId":"b""#)])
    shell.layoutSubtreeIfNeeded()
    let active = try #require(panes.toolbar("a"))
    let other = try #require(panes.toolbar("b"))
    #expect(panes.layer?.masksToBounds == true)
    #expect(panes.layer?.cornerRadius == 0)
    #expect(active.superview === panes)
    #expect(active.frame == CGRect(x: 0, y: 0, width: 1201, height: 47))
    #expect(!active.isHidden)
    #expect(other.isHidden || other.alphaValue == 0)
    shell.update { $0.sidebarWidth = 190 }
    shell.layoutSubtreeIfNeeded()
    #expect(panes.layer?.masksToBounds == false)
    #expect(panes.layer?.cornerRadius == 0)
    #expect(active.superview === panes.container("a")?.superview)
    #expect(active.frame == CGRect(x: 0, y: 0, width: 499, height: 41))
    #expect(other.alphaValue == 1)
  }

  @Test func fullSidebarSplitPagesKeepTheirExistingToolbarAndPageFrames() throws {
    let shell = shell(width: 190)
    let panes = SplitPanesView(windowId: "rail-pages")
    panes.frame = shell.card.bounds
    shell.card.addSubview(panes)
    panes.update(state: try state())
    shell.layoutSubtreeIfNeeded()
    let a = try #require(panes.container("a"))
    #expect(a.convert(a.bounds, to: shell.card) == CGRect(x: 0, y: 41, width: 499, height: 746))
    #expect(panes.toolbar("a")?.superview === a.superview)
  }
}
