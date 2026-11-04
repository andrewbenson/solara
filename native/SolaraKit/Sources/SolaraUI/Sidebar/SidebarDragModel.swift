import AppKit
import SolaraModel
import SolaraStore

enum DragKind: String { case tile, row, group, split, tail, live }

enum DragSection: String { case tiles, pinnedRows, pinnedGroups, list, folder }

@MainActor
final class DragItem {
  let key: String
  var kind: DragKind
  var tabIds: [String]
  var section: DragSection
  var groupId: String?
  var parentGroup: String?
  var collapsed = false
  var folderId: String?
  var liveFolderId: String?
  var frame: CGRect?
  var headerFrame: CGRect?
  var views: [NSView] = []
  var box: NSView?
  var fixed = false

  init(key: String, kind: DragKind, tabIds: [String], section: DragSection) {
    self.key = key
    self.kind = kind
    self.tabIds = tabIds
    self.section = section
  }

  var blockKind: Bool { kind == .row || kind == .group || kind == .live || kind == .split }
  var pinnedBlock: Bool { (section == .pinnedRows || section == .pinnedGroups) && parentGroup == nil && blockKind }
  var boxed: Bool { kind == .group || kind == .live }

  func apart(_ other: DragItem) -> Bool { section != other.section && (section == .folder || other.section == .folder) }
}

struct DragMarks: Equatable {
  var sources: Set<String> = []
  var dropInto: String?
  var onto: String?
  var landing: String?
  var pins = false
  var pinCount = 0
  var pinBefore: String?
  var folded: String?
  var folderTarget: String?
  var folderAway = false

  var json: [String: Any] {
    [
      "sources": Array(sources), "dropInto": dropInto ?? NSNull(), "onto": onto ?? NSNull(), "landing": landing ?? NSNull(), "pins": pins,
      "pinCount": pinCount, "pinBefore": pinBefore ?? NSNull(), "folded": folded ?? NSNull(), "folderTarget": folderTarget ?? NSNull(),
      "folderAway": folderAway,
    ]
  }
}

struct DragSource {
  enum Kind { case tab, split, group, live }
  var kind: Kind
  var groupId: String?
  var folderId: String?
  var external = false
}

enum DropSpot {
  case tiles(beforeId: String?)
  case pinnedRows(beforeId: String?)
  case list(beforeId: String?)
  case group(groupId: String, beforeId: String?)
  case onto(targetId: String)
  case folder(ontoId: String, beforeId: String?)
}

enum SidebarDrop {
  static let none: JSONValue = ["type": "none"]

  static func tabs(_ placement: [(String, JSONValue)]) -> JSONValue {
    ["type": "tabs", "placement": .object(JSONObject(placement))]
  }

  static func resolve(_ state: BrowserState, _ source: DragSource, _ spot: DropSpot?) -> JSONValue {
    guard let spot else { return none }
    let tabs = source.kind == .tab || source.kind == .split
    func moveGroup(pinned: Bool, parentId: String?, beforeId: String?) -> JSONValue {
      guard source.kind == .group, let group = source.groupId else { return none }
      guard canMoveGroup(state.groups, group, parentId: parentId, beforeId: beforeId) else { return none }
      return ["type": "group", "groupId": .string(group), "placement": ["pinned": .bool(pinned), "parentId": JSONValue(parentId), "beforeId": JSONValue(beforeId)]]
    }
    switch spot {
    case .tiles(let beforeId):
      guard source.kind == .tab else { return none }
      var placement: [(String, JSONValue)] = [("pinned", true), ("row", false), ("beforeId", JSONValue(beforeId))]
      if source.folderId == nil { placement.append(("tileFolder", .null)) }
      return Self.tabs(placement)
    case .pinnedRows(let beforeId):
      if tabs {
        var placement: [(String, JSONValue)] = [("pinned", true), ("row", true), ("beforeId", JSONValue(beforeId))]
        if beforeId == nil { placement.append(("last", true)) }
        return Self.tabs(placement)
      }
      if source.kind == .live { return ["type": "live"] }
      return moveGroup(pinned: true, parentId: nil, beforeId: beforeId)
    case .list(let beforeId):
      if tabs { return Self.tabs([("pinned", false), ("beforeId", JSONValue(beforeId))]) }
      return moveGroup(pinned: false, parentId: nil, beforeId: beforeId)
    case .group(let groupId, let beforeId):
      if tabs { return Self.tabs([("pinned", false), ("groupId", .string(groupId)), ("beforeId", JSONValue(beforeId))]) }
      return moveGroup(pinned: false, parentId: groupId, beforeId: beforeId)
    case .onto(let targetId):
      return source.kind == .tab && !source.external ? ["type": "onto", "targetId": .string(targetId)] : none
    case .folder(let ontoId, let beforeId):
      return source.kind == .tab && !source.external ? ["type": "folder", "ontoId": .string(ontoId), "beforeId": JSONValue(beforeId)] : none
    }
  }

  static func canMoveGroup(_ groups: Table<TabGroup>, _ groupId: String, parentId: String?, beforeId: String?) -> Bool {
    guard let g = groups[groupId] else { return false }
    if let beforeId, !beforeId.isEmpty, g.tabIds.contains(beforeId) { return false }
    if let parentId, !parentId.isEmpty, groups[parentId] == nil || !Groups.canNest(groups, groupId, parentId) { return false }
    let staying = Set(parentId.flatMap { $0.isEmpty ? nil : [$0] + Groups.ancestorIds(groups, $0) } ?? [])
    let moving = Set(g.tabIds)
    return Groups.ancestorIds(groups, groupId).allSatisfy { a in staying.contains(a) || groups[a].map { $0.tabIds.contains { !moving.contains($0) } } ?? false }
  }

  static func isTabs(_ drop: JSONValue) -> Bool { drop["type"]?.string == "tabs" }
  static func type(_ drop: JSONValue) -> String { drop["type"]?.string ?? "none" }
  static func pins(_ drop: JSONValue) -> Bool { isTabs(drop) && drop["placement"]?["pinned"]?.truthy == true && drop["placement"]?["row"]?.truthy != true }
  static func rowPins(_ drop: JSONValue) -> Bool { isTabs(drop) && drop["placement"]?["pinned"]?.truthy == true && drop["placement"]?["row"]?.truthy == true }
}

enum PinZone {
  static let tileGap = SidebarMetrics.tileGap
  static let tileHeight = SidebarMetrics.tileHeight
  static let slot = SidebarMetrics.tileHeight + SidebarMetrics.tileGap
  static let hysteresis: CGFloat = 6

  static func slot(grid: CGRect, count: Int, x: CGFloat, y: CGFloat, balanced: Bool, rail: Bool = false) -> Int {
    let g = rail ? PinGrid(columns: 1, width: grid.width) : PinGrid.of(count: count, innerWidth: grid.width, balanced: balanced)
    let tileGap = rail ? SidebarRail.rowGap : Self.tileGap
    let tileHeight = rail ? SidebarRail.rowHeight : Self.tileHeight
    let rows = max(1, Int((Double(count) / Double(g.columns)).rounded(.up)))
    let row = clamp(Int(((y - grid.minY + tileGap / 2) / (tileHeight + tileGap)).rounded(.down)), 0, rows - 1)
    let column = clamp(Int(((x - grid.minX + tileGap / 2) / (g.width + tileGap)).rounded(.down)), 0, g.columns - 1)
    return clamp(row * g.columns + column, 0, max(0, count - 1))
  }

  static func over(_ y: CGFloat, listTop: CGFloat, wasOver: Bool) -> Bool {
    y < listTop + (wasOver ? hysteresis : -hysteresis)
  }

  static func height(_ count: Int, _ width: CGFloat, _ balanced: Bool, rail: Bool = false) -> CGFloat {
    rail ? CGFloat(max(1, count)) * SidebarRail.rowHeight + CGFloat(max(0, count - 1)) * SidebarRail.rowGap
      : PinGrid.height(count: count, innerWidth: width, balanced: balanced)
  }

  static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }
}

extension CGRect {
  func holds(_ x: CGFloat, _ y: CGFloat, slop: CGFloat = 0) -> Bool {
    x >= minX - slop && x <= maxX + slop && y >= minY - slop && y <= maxY + slop
  }

  var dragJSON: [String: Double] { ["x": minX, "y": minY, "w": width, "h": height] }
}

extension JSONValue {
  public var foundation: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let v): return v
    case .number(let v): return v
    case .string(let v): return v
    case .array(let v): return v.map(\.foundation)
    case .object(let o):
      var out: [String: Any] = [:]
      for (key, value) in o { out[key] = value.foundation }
      return out
    }
  }

  public var dragText: String {
    (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }
}
