import CoreGraphics
import SolaraModel
import SolaraStore

public enum SidebarMetrics {
  public static let inset: CGFloat = 6
  public static let rowHeight: CGFloat = 34
  public static let rowGap: CGFloat = 3
  public static let rowPitch: CGFloat = rowHeight + rowGap
  public static let rowRadius: CGFloat = 10
  public static let tileHeight: CGFloat = 41
  public static let tileGap: CGFloat = 6
  public static let tileRadius: CGFloat = 10
  public static let minTile: CGFloat = 50
  public static let balancedMaxColumns = 4
  public static let glowRoom: CGFloat = 24
  public static let edgeGap: CGFloat = 4
  public static let edgeLine: CGFloat = 1
  public static let edgeInset: CGFloat = 1
  public static let groupPad: CGFloat = 2
  public static let groupIndent: CGFloat = 16
  public static let groupBorder: CGFloat = 0.5
  public static let groupRadius: CGFloat = 12
  public static let dividerHeight: CGFloat = 16
  public static let sectionGap: CGFloat = 7
  public static let tilesToPinnedGap: CGFloat = 6
  public static let incognitoBadge: CGFloat = 30
  public static let incognitoBadgeGap: CGFloat = 4
  public static let dockShare: CGFloat = 0.4
  public static let dockedBottom: CGFloat = 6
  public static let inlineNewTabFloor: CGFloat = 24
  public static let dockSlack: CGFloat = 12
  public static let sidebarHeader: CGFloat = 46
  public static let pinnedTop: CGFloat = 54
  public static let addressBarListGap: CGFloat = 6
  public static let upsellGap: CGFloat = 10

  public static func listTopGap(addressBar: Bool) -> CGFloat { addressBar ? addressBarListGap : pinnedTop - sidebarHeader }
}

public enum SidebarItemKind: Hashable, Sendable {
  case tile(String)
  case folder(String)
  case tab(String)
  case split(String)
  case groupHeader(String)
  case groupBox(String)
  case newTab
  case divider
  case incognito
  case upsell
  case live(String)

  public var key: String {
    switch self {
    case .tile(let id): "tile:\(id)"
    case .folder(let id): "folder:\(id)"
    case .tab(let id): "t:\(id)"
    case .split(let id): "s:\(id)"
    case .groupHeader(let id): "gh:\(id)"
    case .groupBox(let id): "gb:\(id)"
    case .newTab: "newTab"
    case .divider: "divider"
    case .incognito: "incognito"
    case .upsell: "upsell"
    case .live(let key): key
    }
  }
}

public enum SidebarRegion: Sendable, Equatable {
  case fixed, scroll, dock
}

public struct SidebarItem: Equatable, Sendable {
  public var kind: SidebarItemKind
  public var frame: CGRect
  public var region: SidebarRegion
  public var groups: [String]
  public var section: Section

  public enum Section: Sendable, Equatable { case tiles, pinned, list, chrome }

  public var key: String { kind.key }
}

public struct SidebarPageLayout: Equatable, Sendable {
  public var items: [SidebarItem] = []
  public var tilesFixed = true
  public var fixedHeight: CGFloat = 0
  public var lineY: CGFloat = 0
  public var scrollTop: CGFloat = 0
  public var scrollBottom: CGFloat = 0
  public var contentHeight: CGFloat = 0
  public var rowsHeight: CGFloat = 0
  public var docked = false
  public var playerFrame: CGRect?
  public var grid = PinGrid(columns: 1, width: 0)

  public func item(_ key: String) -> SidebarItem? { items.first { $0.key == key } }
}

public struct PinGrid: Equatable, Sendable {
  public var columns: Int
  public var width: CGFloat

  public static func of(count: Int, innerWidth: CGFloat, balanced: Bool) -> PinGrid {
    let gap = SidebarMetrics.tileGap
    let fit = max(1, Int(((innerWidth + gap) / (SidebarMetrics.minTile + gap)).rounded(.down)))
    let n = max(count, 1)
    let columns: Int
    if balanced {
      let rows = Int((Double(n) / Double(min(SidebarMetrics.balancedMaxColumns, fit))).rounded(.up))
      columns = Int((Double(n) / Double(rows)).rounded(.up))
    } else {
      columns = min(n, fit)
    }
    let width = (((innerWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)) * 2).rounded(.down) / 2
    return PinGrid(columns: columns, width: width)
  }

  public static func height(count: Int, innerWidth: CGFloat, balanced: Bool) -> CGFloat {
    let grid = of(count: count, innerWidth: innerWidth, balanced: balanced)
    let rows = max(1, Int((Double(count) / Double(grid.columns)).rounded(.up)))
    return CGFloat(rows) * SidebarMetrics.tileHeight + CGFloat(rows - 1) * SidebarMetrics.tileGap
  }
}

public struct SidebarLayoutInput: Sendable {
  public var windowId: String
  public var profileId: String
  public var width: CGFloat
  public var height: CGFloat
  public var addressBar = false
  public var newTabAtTop = false
  public var balanced = false
  public var divided = false
  public var incognitoBadge = false
  public var playerHeight: CGFloat = 0
  public var upsellHeight: CGFloat = 0
  public var live: SidebarLiveBlocks?
  public var rail = false

  public init(windowId: String, profileId: String, width: CGFloat, height: CGFloat) {
    self.windowId = windowId
    self.profileId = profileId
    self.width = width
    self.height = height
  }
}

public struct SidebarLayout {
  let query: SidebarQuery
  let input: SidebarLayoutInput

  public init(query: SidebarQuery, input: SidebarLayoutInput) {
    self.query = query
    self.input = input
  }

  typealias M = SidebarMetrics

  public static func headGap(_ first: String?) -> CGFloat { first?.hasPrefix("g:") == true ? M.rowGap : 0 }

  public func entryHeight(_ entry: String) -> CGFloat {
    if input.rail { return M.rowHeight }
    if entry.hasPrefix(SidebarLive.prefix) { return liveHeight(entry) }
    guard entry.hasPrefix("g:") else { return M.rowHeight }
    return M.groupBorder * 2 + M.rowHeight + membersHeight(String(entry.dropFirst(2)))
  }

  public func entriesHeight(_ entries: [String]) -> CGFloat {
    entries.reduce(0) { $0 + entryHeight($1) + M.rowGap } - (entries.isEmpty ? 0 : M.rowGap)
  }

  func membersHeight(_ groupId: String) -> CGFloat {
    let entries = query.groupEntries(groupId)
    if query.state.groups[groupId]?.collapsed != true {
      return entries.isEmpty ? M.groupPad : Self.headGap(entries.first) + entriesHeight(entries) + M.groupPad
    }
    guard let kept = query.keptEntry(windowId: input.windowId, profileId: input.profileId, entries) else { return 0 }
    return Self.headGap(kept) + entryHeight(kept) + M.groupPad
  }

  public func layout(_ entries: SidebarEntries) -> SidebarPageLayout {
    var out = SidebarPageLayout()
    let innerWidth = input.width - M.inset * 2
    let topGap = M.listTopGap(addressBar: input.addressBar)
    let tiles = entries.cells
    out.grid = PinGrid.of(count: tiles.count, innerWidth: innerWidth, balanced: input.balanced)
    let gridHeight = tiles.isEmpty ? 0 : PinGrid.height(count: tiles.count, innerWidth: innerWidth, balanced: input.balanced)
    let pageHeight = max(0, input.height - (input.addressBar ? M.glowRoom : 0))
    let dockRoom = pageHeight > 0 ? (pageHeight - (input.rail ? 0 : input.playerHeight)) * M.dockShare - topGap - M.edgeGap - M.edgeLine : .infinity
    out.tilesFixed = tiles.isEmpty || gridHeight <= dockRoom

    if out.tilesFixed && !tiles.isEmpty {
      placeTiles(tiles, top: M.glowRoom + topGap, region: .fixed, grid: out.grid, into: &out.items)
      out.lineY = M.glowRoom + topGap + gridHeight + M.edgeGap
    } else {
      out.lineY = M.glowRoom + topGap - M.edgeInset - M.edgeLine
    }
    out.fixedHeight = out.lineY + M.edgeLine
    out.scrollTop = out.fixedHeight - M.glowRoom

    var rows: [SidebarItem] = []
    var y: CGFloat = 0
    if input.incognitoBadge && !input.rail {
      rows.append(SidebarItem(kind: .incognito, frame: CGRect(x: 0, y: y, width: innerWidth, height: M.incognitoBadge), region: .scroll, groups: [], section: .chrome))
      y += M.incognitoBadge + M.incognitoBadgeGap
    }
    let scrolledTiles = !out.tilesFixed && !tiles.isEmpty
    if scrolledTiles {
      placeTiles(tiles, top: y, region: .scroll, grid: out.grid, into: &rows)
      y += gridHeight
    }
    let pinnedSection = !entries.pinned.isEmpty
    y += scrolledTiles ? M.tilesToPinnedGap : 0
    if pinnedSection { y = place(entries.pinned, top: y, x: 0, width: innerWidth, groups: [], section: .pinned, into: &rows) }
    if input.divided && (pinnedSection || scrolledTiles) {
      y += pinnedSection ? M.sectionGap : 0
      rows.append(SidebarItem(kind: .divider, frame: CGRect(x: 0, y: y, width: innerWidth, height: M.dividerHeight), region: .scroll, groups: [], section: .chrome))
      y += M.dividerHeight
    } else if pinnedSection {
      y += M.sectionGap
    }

    let listHeightWithoutNewTab = y + listHeight(entries.list, newTab: false)
    let listForDock = out.fixedHeight + listHeightWithoutNewTab + M.edgeInset
    let playerHeight = input.rail ? 0 : input.playerHeight
    out.docked = !input.newTabAtTop && input.height > 0 && listForDock + playerHeight + M.rowPitch + M.dockSlack > input.height
    let inlineNewTab = !out.docked

    var listItems: [(kind: String, entry: String?)] = []
    if input.newTabAtTop && inlineNewTab { listItems.append(("newTab", nil)) }
    for entry in entries.list { listItems.append(("entry", entry)) }
    if !input.newTabAtTop && inlineNewTab { listItems.append(("newTab", nil)) }
    var first = true
    for item in listItems {
      if !first { y += M.rowGap }
      first = false
      if let entry = item.entry {
        y = place([entry], top: y, x: 0, width: innerWidth, groups: [], section: .list, into: &rows)
      } else {
        rows.append(SidebarItem(kind: .newTab, frame: CGRect(x: 0, y: y, width: innerWidth, height: M.rowHeight), region: .scroll, groups: [], section: .list))
        y += M.rowHeight
      }
    }
    out.rowsHeight = y
    if input.upsellHeight > 0 && !input.rail {
      y += M.upsellGap
      rows.append(SidebarItem(kind: .upsell, frame: CGRect(x: 0, y: y, width: innerWidth, height: input.upsellHeight), region: .scroll, groups: [], section: .chrome))
      y += input.upsellHeight
    }
    let pad = M.glowRoom + M.edgeInset
    for i in rows.indices { rows[i].frame.origin.y += pad }
    out.items.append(contentsOf: rows)
    out.contentHeight = pad + y + (inlineNewTab ? M.inlineNewTabFloor : 0)
    out.scrollBottom = input.height
    if out.docked {
      let dockTop = input.height - M.dockedBottom - M.rowHeight
      out.items.append(SidebarItem(kind: .newTab, frame: CGRect(x: M.inset, y: dockTop, width: innerWidth, height: M.rowHeight), region: .dock, groups: [], section: .list))
      out.scrollBottom = dockTop - M.rowGap
    }
    if input.playerHeight > 0 && !input.rail {
      let playerBody = input.playerHeight - SidebarPlayerView.gap
      let playerTop = out.docked ? out.scrollBottom - playerBody : input.height - input.playerHeight
      out.playerFrame = CGRect(x: M.inset, y: playerTop, width: innerWidth, height: playerBody)
      out.scrollBottom = out.docked ? playerTop - SidebarPlayerView.gap : playerTop
    }
    return out
  }

  func listHeight(_ entries: [String], newTab: Bool) -> CGFloat {
    entriesHeight(entries) + (newTab ? M.rowPitch : 0)
  }

  func placeTiles(_ cells: [String], top: CGFloat, region: SidebarRegion, grid: PinGrid, into items: inout [SidebarItem]) {
    let x0 = region == .fixed ? M.inset : 0
    for (i, cell) in cells.enumerated() {
      let x = x0 + CGFloat(i % grid.columns) * (grid.width + M.tileGap)
      let y = top + CGFloat(i / grid.columns) * (M.tileHeight + M.tileGap)
      let kind: SidebarItemKind = SidebarQuery.folderId(ofCell: cell).map { .folder($0) } ?? .tile(cell)
      items.append(SidebarItem(kind: kind, frame: CGRect(x: x, y: y, width: grid.width, height: M.tileHeight), region: region, groups: [], section: .tiles))
    }
  }

  func place(_ entries: [String], top: CGFloat, x: CGFloat, width: CGFloat, groups: [String], section: SidebarItem.Section, into items: inout [SidebarItem]) -> CGFloat {
    var y = top
    for (i, entry) in entries.enumerated() {
      if i > 0 { y += M.rowGap }
      if entry.hasPrefix(SidebarLive.prefix) {
        if input.rail {
          let folderId = String(entry.dropFirst(SidebarLive.prefix.count))
          items.append(SidebarItem(kind: .live(SidebarLiveMetrics.headerKey(folderId)), frame: CGRect(x: x, y: y, width: width, height: M.rowHeight), region: .scroll, groups: groups, section: section))
          y += M.rowHeight
        } else {
          y = placeLive(entry, top: y, x: x, width: width, section: section, into: &items)
        }
        continue
      }
      let id = String(entry.dropFirst(2))
      if entry.hasPrefix("g:") && input.rail {
        let frame = CGRect(x: x, y: y, width: width, height: M.rowHeight)
        items.append(SidebarItem(kind: .groupBox(id), frame: frame, region: .scroll, groups: groups + [id], section: section))
        items.append(SidebarItem(kind: .groupHeader(id), frame: frame, region: .scroll, groups: groups + [id], section: section))
        y += M.rowHeight
      } else if entry.hasPrefix("g:") {
        y = placeGroup(id, top: y, x: x, width: width, groups: groups, section: section, into: &items)
      } else if entry.hasPrefix("s:") {
        items.append(SidebarItem(kind: .split(id), frame: CGRect(x: x, y: y, width: width, height: M.rowHeight), region: .scroll, groups: groups, section: section))
        y += M.rowHeight
      } else {
        items.append(SidebarItem(kind: .tab(id), frame: CGRect(x: x, y: y, width: width, height: M.rowHeight), region: .scroll, groups: groups, section: section))
        y += M.rowHeight
      }
    }
    return y
  }

  func placeGroup(_ groupId: String, top: CGFloat, x: CGFloat, width: CGFloat, groups: [String], section: SidebarItem.Section, into items: inout [SidebarItem]) -> CGFloat {
    let height = entryHeight("g:\(groupId)")
    let inside = groups + [groupId]
    items.append(SidebarItem(kind: .groupBox(groupId), frame: CGRect(x: x, y: top, width: width, height: height), region: .scroll, groups: inside, section: section))
    let headerTop = top + M.groupBorder
    items.append(SidebarItem(kind: .groupHeader(groupId), frame: CGRect(x: x, y: headerTop, width: width, height: M.rowHeight), region: .scroll, groups: inside, section: section))
    let members = query.groupEntries(groupId)
    let shown: [String]
    if query.state.groups[groupId]?.collapsed == true {
      shown = query.keptEntry(windowId: input.windowId, profileId: input.profileId, members).map { [$0] } ?? []
    } else {
      shown = members
    }
    if !shown.isEmpty {
      let start = headerTop + M.rowHeight + Self.headGap(shown.first)
      _ = place(shown, top: start, x: x + M.groupIndent, width: width - M.groupIndent, groups: inside, section: section, into: &items)
    }
    return top + height
  }
}
