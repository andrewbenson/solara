import Foundation

public struct BookmarksBarMenuItem: Equatable, Sendable {
  public var title: String
  public var symbol: String?
  public var enabled = true
  public var checked = false
  public var children: [BookmarksBarMenuItem] = []
  public var separator = false
  public var choiceId: String?
  var action: String?
  var id: String?

  static var divider: Self { Self(title: "", separator: true) }

  static func choice(_ action: String, _ title: String, id: String? = nil, enabled: Bool = true, checked: Bool = false, symbol: String? = nil) -> Self {
    Self(title: title, symbol: symbol, enabled: enabled, checked: checked, choiceId: id.map { "\(action):\($0)" } ?? action, action: action, id: id)
  }
}

public struct BookmarksBarMenu: Sendable {
  public struct Choice: Equatable, Sendable {
    public var action: String
    public var id: String?
  }

  let snapshot: BookmarksBarSnapshot
  let overflowIds: [String]

  public init(snapshot: BookmarksBarSnapshot, overflowIds: [String]) {
    self.snapshot = snapshot
    self.overflowIds = overflowIds
  }

  public func items(trigger: String, id: String?) -> [BookmarksBarMenuItem] {
    switch trigger {
    case "item":
      guard let id, let node = find(id) else { return [] }
      return context(node)
    case "blank": return context(nil)
    case "folder":
      guard let id, let folder = find(id), folder.kind == .folder else { return [] }
      return tree(folder.children, parent: folder)
    case "overflow":
      var byId: [String: BookmarksBarItem] = [:]
      for item in snapshot.items where byId[item.id] == nil { byId[item.id] = item }
      return tree(overflowIds.compactMap { byId[$0] })
    case "other":
      guard let folder = snapshot.otherFolder else { return [] }
      return tree(folder.children, parent: folder)
    case "import": return [.choice("hide", "Hide Import Bookmarks Button")]
    default: return []
    }
  }

  public func choice(trigger: String, id: String?, choiceId: String) -> Choice? {
    func findChoice(_ items: [BookmarksBarMenuItem]) -> Choice? {
      for item in items where item.enabled && !item.separator {
        if item.choiceId == choiceId, let action = item.action { return Choice(action: action, id: item.id) }
        if let choice = findChoice(item.children) { return choice }
      }
      return nil
    }
    return findChoice(items(trigger: trigger, id: id))
  }

  func find(_ id: String) -> BookmarksBarItem? {
    func search(_ items: [BookmarksBarItem]) -> BookmarksBarItem? {
      for item in items {
        if item.id == id { return item }
        if let found = search(item.children) { return found }
      }
      return nil
    }
    return search(snapshot.items) ?? snapshot.otherFolder.flatMap { search([$0]) }
  }

  private func context(_ node: BookmarksBarItem?) -> [BookmarksBarMenuItem] {
    var items: [BookmarksBarMenuItem] = []
    if let node, node.kind == .url {
      items += [
        .choice("tab", "Open in New Tab", id: node.id),
        .choice("window", "Open in New Window", id: node.id),
        .choice("incognito", "Open in Incognito Window", id: node.id),
        .choice("split", "Open in Split View", id: node.id),
        .divider,
        .choice("edit", "Edit…", id: node.id),
        .choice("copy", "Copy Link", id: node.id),
        .choice("delete", "Delete", id: node.id),
        .divider,
      ]
    } else if let node {
      items += footer(node, includeDisabled: true)
      if node.restorableArcHolder { items.append(.choice("restoreArc", "Restore Arc Folders as Groups", id: node.id)) }
      items += [.divider, .choice("rename", "Rename…", id: node.id), .choice("delete", "Delete", id: node.id), .divider]
    }
    items += [
      .choice("addPage", "Add Page…", id: node?.id),
      .choice("addFolder", "Add Folder…", id: node?.id),
      .divider,
      .choice("manage", "Manage Bookmarks"),
      BookmarksBarMenuItem(title: "Show Bookmarks Bar", children: [
        .choice("bar", "Always", id: "always", checked: snapshot.bookmarksBar == "always"),
        .choice("bar", "On New Tab Only", id: "newTab", checked: snapshot.bookmarksBar == "newTab"),
        .choice("bar", "Never", id: "never", checked: snapshot.bookmarksBar == "never"),
      ], choiceId: "show"),
    ]
    return items
  }

  private func footer(_ folder: BookmarksBarItem, includeDisabled: Bool = false) -> [BookmarksBarMenuItem] {
    guard includeDisabled || folder.folderLinks > 0 else { return [] }
    return [
      .choice("openAll", "Open All (\(folder.folderLinks))", id: folder.id, enabled: folder.folderLinks > 0),
      .choice("openAllWindow", "Open All in New Window", id: folder.id, enabled: folder.folderLinks > 0),
      .choice("openAllIncognito", "Open All in Incognito Window", id: folder.id, enabled: folder.folderLinks > 0),
      .choice("addGroup", "Add to Sidebar as Group", id: folder.id, enabled: folder.makesGroup),
    ]
  }

  private func tree(_ nodes: [BookmarksBarItem], parent: BookmarksBarItem? = nil, depth: Int = 0) -> [BookmarksBarMenuItem] {
    var items = nodes.map { node in
      node.kind == .url
        ? BookmarksBarMenuItem.choice("open", node.displayTitle, id: node.id, symbol: "globe")
        : BookmarksBarMenuItem(title: node.title, symbol: "folder", children: depth < 8 ? tree(node.children, parent: node, depth: depth + 1) : [], choiceId: "folder:\(node.id)")
    }
    if items.isEmpty { items = [BookmarksBarMenuItem(title: "Empty", enabled: false, choiceId: "empty")] }
    if let parent, parent.folderLinks > 0 { items += [.divider] + footer(parent) }
    return items
  }
}

#if DEBUG
extension BookmarksBarMenuItem {
  var json: [String: Any] {
    ["title": title, "symbol": symbol as Any? ?? NSNull(), "enabled": enabled, "checked": checked, "children": children.map(\.json), "separator": separator, "choiceId": choiceId as Any? ?? NSNull()]
  }
}
#endif
