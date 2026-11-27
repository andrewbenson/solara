import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct SidebarRowPreferencesTests {
  @Test func aSidebarFeedDecodesWithoutWorkspaceRowPreferences() throws {
    let feed = ##"{"profileId":"p","dark":true,"theme":{},"border":[],"glow":{"color":"#fff","opacity":1,"radius":15},"loading":[],"playing":[],"sleeping":[],"addressBar":true,"tidy":false,"cleaned":0,"engines":{},"developer":[],"newTabMark":"mark"}"##
    let host = try #require(SidebarHostState.decode(feed))
    #expect(host.addressBar)
    #expect(host.newTabMark == "mark")
  }

  @Test func eachRefreshUsesTheCurrentWindowSelectionAndPreferences() throws {
    let fixture = #"{"windows":{"one":{"id":"one","profileId":"p"},"two":{"id":"two","profileId":"private","incognito":true}},"selection":{"one":["a","b"],"two":["c"]},"settings":{"showClearButton":false,"classicPinnedTabs":true,"newTabButtonPosition":"top"}}"#
    var state = try BrowserState(stateJSON: try #require(JSONValue.parse(fixture).object))
    var host = SidebarHostState(profileId: "p")
    host.selection = ["stale"]
    host.clear = true
    host.iconRing = true

    host.applyRowPreferences(state: state, windowId: "one")
    #expect(host.selection == ["a", "b"])
    #expect(!host.incognito)
    #expect(!host.clear)
    #expect(!host.iconRing)
    #expect(host.newTabAtTop)

    try state.applySlice("settings", .object(["showClearButton": .bool(true), "classicPinnedTabs": .bool(false), "newTabButtonPosition": .string("bottom")]))
    host.applyRowPreferences(state: state, windowId: "two")
    #expect(host.selection == ["c"])
    #expect(host.incognito)
    #expect(host.clear)
    #expect(host.iconRing)
    #expect(!host.newTabAtTop)

    state.selection["two"] = nil
    host.applyRowPreferences(state: state, windowId: "two")
    #expect(host.selection.isEmpty)
  }
}
