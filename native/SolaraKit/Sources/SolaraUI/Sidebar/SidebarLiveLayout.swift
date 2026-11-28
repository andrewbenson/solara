import CoreGraphics
import SolaraLive
import SolaraModel
import SolaraStore

extension SidebarLayout {
  func liveBlock(_ folderId: String) -> SidebarLiveBlock? {
    input.live?.block(folderId)
  }

  func liveHeight(_ entry: String) -> CGFloat {
    liveBlock(String(entry.dropFirst(SidebarLive.prefix.count)))?.height ?? 0
  }

  func placeLive(_ entry: String, top: CGFloat, x: CGFloat, width: CGFloat, section: SidebarItem.Section, into items: inout [SidebarItem]) -> CGFloat {
    let folderId = String(entry.dropFirst(SidebarLive.prefix.count))
    guard let block = liveBlock(folderId) else { return top }
    typealias L = SidebarLiveMetrics
    let groups: [String] = []
    items.append(SidebarItem(kind: .live(L.boxKey(folderId)), frame: CGRect(x: x, y: top, width: width, height: block.height), region: .scroll, groups: groups, section: section))
    let innerX = x + L.border
    let innerWidth = width - L.border * 2
    let headerTop = top + L.border
    items.append(SidebarItem(kind: .live(L.headerKey(folderId)), frame: CGRect(x: innerX, y: headerTop, width: innerWidth, height: L.headerHeight), region: .scroll, groups: groups, section: section))
    var y = headerTop + L.headerHeight
    let rowX = innerX + L.pad
    let rowWidth = innerWidth - L.pad * 2
    for (i, entry) in block.entries.enumerated() {
      if i > 0 { y += L.gap }
      for row in entry.rows {
        y += row.gapBefore
        let kind: SidebarItemKind = if case .stray(let id) = row.kind { .tab(id) } else { .live(row.key) }
        items.append(SidebarItem(kind: kind, frame: CGRect(x: rowX, y: y, width: rowWidth, height: row.height), region: .scroll, groups: groups, section: section))
        y += row.height
      }
    }
    return top + block.height
  }
}

extension SidebarLive {
  public func movedFolder(_ folderId: String, by offset: Int, browser: BrowserState, windowId: String) -> [FolderPlacement] {
    guard let window = browser.windows[windowId], !window.incognito else { return [] }
    let pinned = SidebarQuery(browser).entries(windowId: windowId, profileId: window.profileId).pinned
    var order = sequence(pinned, state: browser, windowId: windowId, profileId: window.profileId)
    guard let index = order.firstIndex(of: Self.prefix + folderId), order.indices.contains(index + offset) else { return [] }
    order.swapAt(index, index + offset)
    return placements(order, browser: browser, windowId: windowId)
  }
}

public final class SidebarLiveBlocks: @unchecked Sendable {
  public let live: SidebarLive
  let state: BrowserState
  let windowId: String
  let profileId: String
  private var made: [String: SidebarLiveBlock?] = [:]

  public init(_ live: SidebarLive, state: BrowserState, windowId: String, profileId: String) {
    self.live = live
    self.state = state
    self.windowId = windowId
    self.profileId = profileId
  }

  public func sequence(_ pinned: [String]) -> [String] {
    live.sequence(pinned, state: state, windowId: windowId, profileId: profileId)
  }

  public func block(_ folderId: String) -> SidebarLiveBlock? {
    if let known = made[folderId] { return known }
    let block = live.block(folderId, browser: state, windowId: windowId, profileId: profileId)
    made[folderId] = block
    return block
  }

  func row(_ key: String) -> SidebarLiveRow? {
    guard key.hasPrefix("li:") || key.hasPrefix("live|") else { return nil }
    let rest = key.hasPrefix("li:") ? key.dropFirst(3) : key.dropFirst(5)
    guard let bar = rest.firstIndex(of: "|") else { return nil }
    return block(String(rest[..<bar]))?.row(key)
  }

  func header(_ key: String) -> SidebarLiveHeaderSpec? {
    let prefix = "livefolder|"
    guard key.hasPrefix(prefix) else { return nil }
    return block(String(key.dropFirst(prefix.count)))?.header
  }
}
