import Foundation
import SolaraModel

public enum ExtensionToolbarProjection {
  public static func make(rows: [JSONObject], states: JSONObject, popup: String?, limit: Int, routes: [JSONObject], webkit: Bool, accent: String) -> JSONValue {
    if webkit {
      return ["width": 84, "buttons": [["id": "webkit", "icon": "safari", "label": "WebKit", "size": 12, "box": 24,
        "tooltip": "This page is open in WebKit", "info": ["title": "This page is open in WebKit", "message": "Extensions, password autofill and casting don't run here.", "action": "Open Page in Chromium", "actionId": "webkit:openInChromium"]]]]
    }
    let all = rows.filter { $0["pinned"]?.truthy == true }
    let room = max(0, limit - (routes.isEmpty ? 0 : 1))
    let overflow = all.count > room
    let pinned = overflow ? Array(all.prefix(max(0, room - 1))) : all
    var buttons: [JSONValue] = []
    if !routes.isEmpty {
      var cast = button("ext-cast", icon: "tv.and.mediabox.fill", tooltip: routes.map {
        let sink = $0["sink"]?.string ?? ""
        return $0["description"]?.truthy == true ? "\($0["description"]?.string ?? "") on \(sink)" : "Casting to \(sink)"
      }.joined(separator: "\n"))
      cast["color"] = .string(accent)
      cast["menu"] = true
      buttons.append(.object(cast))
    }
    for ext in pinned {
      let id = ext["id"]?.string ?? ""
      let state = states[id]?.object
      var item = button("ext:\(id)", tooltip: nonempty(state?["title"], ext["actionTitle"], ext["name"])?.string ?? "")
      item["anchor"] = .string(id)
      item["image"] = nonempty(state?["icon"], ext["actionIcon"], ext["icon"]) ?? .null
      item["imageSize"] = 16
      item["dimmed"] = .bool(state != nil && state?["enabled"]?.truthy != true)
      item["active"] = .bool(popup == id)
      item["menu"] = true
      if let text = state?["badgeText"], text.truthy {
        let color = state?["badgeColor"]?.string
        let fill = color != nil && color != "" && color != "#000000" ? color! : "#5F6368"
        item["badge"] = ["text": text, "color": .string(fill), "textColor": state?["badgeTextColor"] ?? .string(contrast(fill))]
      } else { item["badge"] = .null }
      buttons.append(.object(item))
    }
    if overflow {
      var item = button("ext-overflow", tooltip: "Extensions")
      item["anchor"] = "*"
      buttons.append(.object(item))
    }
    return ["width": .number(buttons.isEmpty ? 0 : Double(buttons.count * 30 - 2 + 6)), "buttons": .array(buttons)]
  }

  private static func nonempty(_ values: JSONValue?...) -> JSONValue? { values.compactMap { $0 }.first { $0.truthy } }
  private static func button(_ id: String, icon: String = "puzzlepiece.extension", tooltip: String) -> JSONObject {
    ["id": .string(id), "icon": .string(icon), "size": 14, "box": 28, "radius": 7, "tooltip": .string(tooltip)]
  }
  private static func contrast(_ color: String) -> String {
    let value = Int(color.dropFirst().prefix(6), radix: 16) ?? 0
    return 0.299 * Double((value >> 16) & 255) + 0.587 * Double((value >> 8) & 255) + 0.114 * Double(value & 255) > 160 ? "#000000" : "#FFFFFF"
  }

  public static func menu(_ ext: JSONObject, panelOpen: Bool) -> [JSONObject] {
    let enabled = ext["enabled"]?.truthy == true
    let pinned = ext["pinned"]?.truthy == true
    var items: [JSONObject] = [["id": "name", "title": ext["name"] ?? "", "enabled": false], ["separator": true],
      ["id": "options", "title": "Options", "enabled": .bool(ext["optionsUrl"]?.truthy == true && enabled)]]
    if enabled && ext["sidePanel"]?.truthy == true { items.append(["id": "sidePanel", "title": .string(panelOpen ? "Close Side Panel" : "Open Side Panel")]) }
    items += [["id": "pin", "title": .string(pinned ? "Unpin from Toolbar" : "Pin to Toolbar"), "symbol": .string(pinned ? "pin.slash" : "pin")],
      ["id": "enable", "title": .string(enabled ? "Turn Off" : "Turn On")], ["separator": true],
      ["id": "remove", "title": "Remove Extension…", "enabled": ext["mayModify"] ?? false], ["id": "manage", "title": "Manage Extensions…"]]
    return items
  }

  public static func overflow(_ rows: [JSONObject]) -> [JSONObject] {
    var items = rows.map { ext -> JSONObject in
      var item: JSONObject = ["id": .string("open:\(ext["id"]?.string ?? "")"), "title": ext["name"] ?? ""]
      if ext["pinned"]?.truthy == true { item["symbol"] = "pin.fill" }
      return item
    }
    if !items.isEmpty { items.append(["separator": true]) }
    items += [["id": "pin", "title": "Pin Extensions…", "symbol": "pin"], ["id": "manage", "title": "Manage Extensions…", "symbol": "puzzlepiece.extension"], ["id": "add", "title": "Add Extension…", "symbol": "plus"]]
    return items
  }
}
