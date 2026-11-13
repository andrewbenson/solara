import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarGroupBoxTests {
  private func state(colors: [String: String?], collapsed: Set<String> = []) throws -> BrowserState {
    let ids = ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9"]
    var tabs: [String: Any] = [:]
    for id in ids { tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://\(id).example/", "title": id] }
    let members = ["g1": ["t2", "t3"], "g2": ["t4", "t5"], "g3": ["t6", "t7"], "g4": ["t8", "t9"]]
    var groups: [String: Any] = [:]
    for (id, tabIds) in members {
      var group: [String: Any] = ["id": id, "windowId": "w", "name": id, "tabIds": tabIds, "collapsed": collapsed.contains(id)]
      if let color = colors[id] ?? nil { group["color"] = color }
      groups[id] = group
    }
    let root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ids, "activeTabIds": ["p": "t1"]]],
      "groups": groups,
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func box(_ sidebar: SidebarView, _ id: String) throws -> GroupBoxView {
    try #require(sidebar.views["gb:\(id)"] as? GroupBoxView)
  }

  private func shown(_ sidebar: SidebarView) throws -> [String: Bool] {
    var out: [String: Bool] = [:]
    for id in ["g1", "g2", "g3", "g4"] {
      let view = try box(sidebar, id)
      #expect(view.boxShown == (view.fill.opacity == 1))
      out[id] = view.boxShown
    }
    return out
  }

  @Test func aColouredGroupShowsItsBoxAtRestAndNeutralOnesOnlyOnHover() throws {
    let colors: [String: String?] = ["g1": nil, "g2": "blue", "g3": "none", "g4": "grey"]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
    window.contentView = sidebar
    let host = SidebarHostState(profileId: "p")
    sidebar.update(state: try state(colors: colors), host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(try shown(sidebar) == ["g1": false, "g2": true, "g3": false, "g4": true])

    let neutralRow = try #require(sidebar.views["t:t2"] as? SidebarRowView)
    sidebar.pointerEntered(neutralRow)
    #expect(try shown(sidebar) == ["g1": true, "g2": true, "g3": false, "g4": true])
    sidebar.pointerExited(neutralRow)
    #expect(try shown(sidebar) == ["g1": false, "g2": true, "g3": false, "g4": true])

    let colouredRow = try #require(sidebar.views.values.compactMap { $0 as? SidebarRowView }.first { $0.item?.groups.last == "g2" })
    sidebar.pointerEntered(colouredRow)
    sidebar.pointerExited(colouredRow)
    #expect(try shown(sidebar)["g2"] == true)

    sidebar.update(state: try state(colors: ["g1": "red", "g2": nil, "g3": "none", "g4": "grey"]), host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(try shown(sidebar) == ["g1": true, "g2": false, "g3": false, "g4": true])

    let recoloured: [String: String?] = ["g1": "red", "g2": nil, "g3": "none", "g4": "grey"]
    sidebar.update(state: try state(colors: recoloured, collapsed: ["g1", "g2"]), host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(try shown(sidebar) == ["g1": true, "g2": false, "g3": false, "g4": true])
    sidebar.update(state: try state(colors: recoloured), host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(try shown(sidebar) == ["g1": true, "g2": false, "g3": false, "g4": true])
    _ = window
  }

  @Test func onlyRealColoursCountAsTinted() {
    #expect(!SidebarPalette.groupTinted(nil))
    #expect(!SidebarPalette.groupTinted("none"))
    #expect(!SidebarPalette.groupTinted(""))
    #expect(!SidebarPalette.groupTinted("magenta"))
    for color in SidebarPalette.groupColors.keys { #expect(SidebarPalette.groupTinted(color)) }
  }
}
