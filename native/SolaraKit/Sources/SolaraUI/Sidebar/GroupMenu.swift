import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct GroupMenuItem: Equatable, Sendable {
  public var id: String?
  public var title = ""
  public var symbol: String?
  public var swatch: String?
  public var swatchDark: String?
  public var checked = false
  public var enabled = true
  public var key: String?
  public var modifiers: [String] = []
  public var children: [GroupMenuItem] = []
  public var separator = false

  static var divider: Self { Self(separator: true) }

  public var dictionary: [String: Any] {
    if separator { return ["separator": true] }
    var row: [String: Any] = ["title": title, "checked": checked, "enabled": enabled]
    if let id { row["id"] = id }
    if let symbol { row["symbol"] = symbol }
    if let swatch { row["swatch"] = swatch }
    if let swatchDark { row["swatchDark"] = swatchDark }
    if let key {
      row["key"] = key
      row["modifiers"] = modifiers
    }
    if !children.isEmpty { row["children"] = children.map(\.dictionary) }
    return row
  }
}

public enum GroupMenuChoice: Equatable, Sendable {
  case rename, icon, newTab, nest, pin, duplicate, collapse, ungroup, bookmarkBar, close, delete
  case color(String?)
  case copy(markdown: Bool)

  public init?(_ id: String) {
    if id.hasPrefix("color:") {
      let value = String(id.dropFirst(6))
      self = .color(value.isEmpty ? nil : value)
      return
    }
    switch id {
    case "rename": self = .rename
    case "icon": self = .icon
    case "newTab": self = .newTab
    case "nest": self = .nest
    case "pin": self = .pin
    case "duplicate": self = .duplicate
    case "collapse": self = .collapse
    case "copy": self = .copy(markdown: false)
    case "copyMd": self = .copy(markdown: true)
    case "ungroup": self = .ungroup
    case "bookmarkBar": self = .bookmarkBar
    case "close": self = .close
    case "delete": self = .delete
    default: return nil
    }
  }
}

public enum GroupMenu {
  public static let tints: [(id: String, name: String, hex: String)] = [
    ("grey", "Grey", "#8E8E93"), ("blue", "Blue", "#4C8DF6"), ("red", "Red", "#E5534B"),
    ("yellow", "Yellow", "#E3B341"), ("green", "Green", "#3FB06C"), ("pink", "Pink", "#DB61A2"),
    ("purple", "Purple", "#9B6CF0"), ("cyan", "Cyan", "#35B8C6"), ("orange", "Orange", "#EE8434"),
  ]
  public static let neutralSwatch = (light: "#0000004D", dark: "#FFFFFF4D")
  static let menuOrder = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

  public static func items(_ state: BrowserState, groupId: String, newTabShortcut: String? = nil) -> [GroupMenuItem] {
    guard let g = state.groups[groupId] else { return [] }
    let siteColor = g.tabIds.lazy.compactMap { state.live[$0]?.themeColor }.first { !$0.isEmpty }
    let matched = siteColor.flatMap(nearestColor)
    let hex = Dictionary(uniqueKeysWithValues: tints.map { ($0.id, $0) })
    let hasIcon = g.icon.map { !$0.isEmpty && $0 != SidebarIconPickerMetrics.noGroupIcon } ?? false
    var colors: [GroupMenuItem] = [
      GroupMenuItem(id: "color:none", title: "None", swatch: "#00000000", checked: g.color == "none"),
      GroupMenuItem(id: "color:", title: "Neutral", swatch: neutralSwatch.light, swatchDark: neutralSwatch.dark, checked: g.color == nil || g.color == ""),
      GroupMenuItem(id: "color:\(matched ?? "")", title: "Match Site Color", swatch: matched.flatMap { hex[$0]?.hex }, enabled: matched != nil),
      .divider,
    ]
    colors += menuOrder.compactMap { id in hex[id].map { GroupMenuItem(id: "color:\(id)", title: $0.name, swatch: $0.hex, checked: g.color == id) } }
    var newTab = GroupMenuItem(id: "newTab", title: "New Tab in Group", symbol: "plus")
    if let shortcut = newTabShortcut.flatMap(menuKey) {
      newTab.key = shortcut.key
      newTab.modifiers = shortcut.modifiers
    }
    var rows: [GroupMenuItem] = [
      GroupMenuItem(id: "rename", title: "Rename…", symbol: "character.cursor.ibeam"),
      GroupMenuItem(id: "icon", title: hasIcon ? "Change Icon…" : "Add Icon…", symbol: "face.smiling"),
      GroupMenuItem(id: "color", title: "Color", symbol: "paintpalette", children: colors),
      .divider,
      newTab,
      GroupMenuItem(id: "nest", title: "New Nested Group", symbol: "plus.rectangle.on.rectangle"),
    ]
    if g.parentId == nil {
      rows.append(GroupMenuItem(id: "pin", title: g.pinned ? "Unpin Group" : "Pin Group", symbol: g.pinned ? "pin.slash" : "pin"))
    }
    rows += [
      GroupMenuItem(id: "duplicate", title: "Duplicate Group", symbol: "plus.square.on.square"),
      GroupMenuItem(id: "collapse", title: g.collapsed ? "Expand Group" : "Collapse Group", symbol: g.collapsed ? "chevron.down" : "chevron.up"),
      .divider,
      GroupMenuItem(id: "copy", title: "Copy All Links", symbol: "link"),
      GroupMenuItem(id: "copyMd", title: "Copy All Links as Markdown", symbol: "text.badge.checkmark"),
      .divider,
      GroupMenuItem(id: "ungroup", title: "Ungroup", symbol: "folder.badge.minus"),
      GroupMenuItem(id: "bookmarkBar", title: "Move to Bookmark Bar", symbol: "bookmark"),
      GroupMenuItem(id: "close", title: "Close Group", symbol: "xmark"),
      GroupMenuItem(id: "delete", title: "Delete Group", symbol: "trash"),
    ]
    return rows
  }

  public static func command(_ choice: GroupMenuChoice, groupId: String, state: BrowserState) -> Command? {
    guard let g = state.groups[groupId] else { return nil }
    switch choice {
    case .color(let color): return Command("updateGroup", [.string(groupId), ["color": color.map(JSONValue.string) ?? .null]])
    case .pin: return Command("moveGroup", [.string(groupId), ["pinned": .bool(!g.pinned)]])
    case .duplicate: return Command("duplicateGroup", [.string(groupId)])
    case .collapse: return GroupActions.collapse(groupId, !g.collapsed)
    case .ungroup: return Command("ungroup", [.string(groupId)])
    case .delete: return Command("deleteGroup", [.string(groupId)])
    default: return nil
    }
  }

  public static func newTabOpensBar(_ state: BrowserState, windowId: String) -> Bool {
    state.settings["newTabOpens"]?.string == "commandBar" && state.windows[windowId].map { !$0.isSmall } == true
  }

  public static func copiedText(_ state: BrowserState, ids: [String], markdown: Bool) -> String? {
    let tabs = ids.compactMap { state.tabs[$0] }.filter { !$0.url.isEmpty }
    guard !tabs.isEmpty else { return nil }
    let lines = tabs.map { markdown ? markdownLink(title: title($0.customTitle, $0.title, url: $0.url), url: $0.url) : cleanUrl($0.url) }
    return markdown && lines.count > 1 ? lines.map { "- \($0)" }.joined(separator: "\n") : lines.joined(separator: "\n")
  }

  static func title(_ custom: String?, _ title: String, url: String) -> String {
    if let custom, !custom.isEmpty { return custom }
    if !title.isEmpty { return title }
    if !url.isEmpty { return urlLabel(url) }
    return "New Tab"
  }

  static func urlLabel(_ url: String) -> String {
    var label = url.replacingOccurrences(of: "^[a-z][\\w+.-]*://", with: "", options: [.regularExpression, .caseInsensitive])
    if label.hasPrefix("www.") { label.removeFirst(4) }
    if label.hasSuffix("/") { label.removeLast() }
    return label
  }

  static func menuKey(_ hint: String) -> (key: String, modifiers: [String])? {
    let names: [Character: String] = ["⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command"]
    var modifiers: [String] = []
    var rest = Substring(hint)
    while let first = rest.first, let name = names[first] {
      modifiers.append(name)
      rest = rest.dropFirst()
    }
    guard !rest.isEmpty, !hint.contains("🌐") else { return nil }
    let named: [String: String] = [
      "⇥": "\t", "↩": "\r", "⌤": "\u{3}", "⌫": "\u{8}", "⌦": "\u{F728}", "⎋": "\u{1B}", "Space": " ",
      "↑": "\u{F700}", "↓": "\u{F701}", "←": "\u{F702}", "→": "\u{F703}",
      "↖": "\u{F729}", "↘": "\u{F72B}", "⇞": "\u{F72C}", "⇟": "\u{F72D}",
    ]
    let name = String(rest)
    if let key = named[name] { return (key, modifiers) }
    if name.range(of: "^F[0-9]{1,2}$", options: .regularExpression) != nil, let number = Int(name.dropFirst()), (1...35).contains(number),
      let scalar = Unicode.Scalar(0xF704 + number - 1) {
      return (String(Character(scalar)), modifiers)
    }
    guard name.count == 1 else { return nil }
    return (name.lowercased(), modifiers)
  }

  public static func nearestColor(_ color: String) -> String? {
    guard let parsed = rgb(color) else { return nil }
    let target = hsl(parsed)
    if target.s < 0.18 || target.l < 0.12 || target.l > 0.92 { return nil }
    var best: String?
    var bestDistance = Double.infinity
    for tint in tints where tint.id != "grey" {
      guard let c = rgb(tint.hex).map(hsl) else { continue }
      let dh = min(abs(c.h - target.h), 360 - abs(c.h - target.h))
      if dh < bestDistance { (best, bestDistance) = (tint.id, dh) }
    }
    return best
  }

  static func rgb(_ color: String) -> (Double, Double, Double)? {
    let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines)
    if let m = trimmed.range(of: "^#?[0-9a-fA-F]{6}", options: .regularExpression) {
      let hex = trimmed[m].replacingOccurrences(of: "#", with: "")
      guard let n = Int(hex, radix: 16) else { return nil }
      return (Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
    }
    guard let m = color.range(of: "rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)", options: .regularExpression) else { return nil }
    let parts = color[m].split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
    return parts.count >= 3 ? (parts[0], parts[1], parts[2]) : nil
  }

  static func hsl(_ rgb: (Double, Double, Double)) -> (h: Double, s: Double, l: Double) {
    let (r, g, b) = rgb
    let max = Swift.max(r, g, b) / 255
    let min = Swift.min(r, g, b) / 255
    let l = (max + min) / 2
    let d = max - min
    if d == 0 { return (0, 0, l) }
    let s = d / (1 - abs(2 * l - 1))
    var h: Double
    if max == r / 255 {
      h = ((g - b) / 255 / d + 6).truncatingRemainder(dividingBy: 6)
    } else if max == g / 255 {
      h = (b - r) / 255 / d + 2
    } else {
      h = (r - g) / 255 / d + 4
    }
    h *= 60
    return (h, s, l)
  }
}
