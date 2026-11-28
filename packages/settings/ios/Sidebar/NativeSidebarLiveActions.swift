import AppKit
import SolaraLive
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

extension NativeSidebarLive {
  static func action(_ action: String, windowId: String, folderId: String, id: String?, background: Bool) {
    guard let store = WorkspaceWrites.store, let window = store.state.windows[windowId], !window.incognito, !store.memory.closingWindows.contains(windowId),
      let live = SidebarLiveFeed.shared.live, let folder = live.state.folders[folderId], folder.profileId == window.profileId
    else { return }
    let payload: LiveAnyJSON = .object(["folderId": .string(folderId)])
    let item = id.flatMap { id in live.state.items[folderId]?.first { $0.id == id } }
    switch action {
    case "toggle": patch(folderId, ["collapsed": .bool(!folder.collapsed)])
    case "refresh": perform(.manualRefresh(payload))
    case "settings": openSettings("liveFolders")
    case "folderMenu": folderMenu(folder, live: live, windowId: windowId, store: store)
    case "open":
      if let item { _ = open(item, folder: folder, windowId: windowId, background: background, store: store) }
    case "itemMenu":
      if let item { itemMenu(item, folder: folder, live: live, windowId: windowId, store: store) }
    case "close":
      if let id, let tab = store.state.tabs[id], tab.windowId == windowId, tab.profileId == window.profileId,
        tab.liveItem?["folderId"]?.string == folderId { NativeWorkspaceCommands.closeFromControl(id, store: store) }
    case "stack":
      if let id { perform(.setExpandedStack(.object(["key": .string(id), "expanded": .bool(live.state.expandedStacks[id] == false)]))) }
    case "stackMenu":
      if let id { stackMenu(id, folder: folder, windowId: windowId, store: store) }
    case "more":
      if let id { showMore(folderId: folderId, itemId: id) }
    case "openCompleted":
      if let item = live.state.completed[folderId]?.first(where: { $0.item.id == id })?.item {
        _ = open(item, folder: folder, windowId: windowId, background: false, store: store)
      }
    default: break
    }
  }

  private static func patch(_ folderId: String, _ values: [String: LiveAnyJSON], refresh: Bool = false) {
    let id = LiveAnyJSON.string(folderId)
    perform(.updateFolder(.object(["folderId": id, "patch": .object(values)])),
      then: refresh ? .refreshFolder(.object(["folderId": id])) : nil)
  }

  static func open(_ item: LiveItem, folder: LiveFolder, windowId: String, background: Bool, store: Store) -> String? {
    guard WorkspaceWrites.store === store else { return nil }
    let tabId = try? store.sequence {
      guard store.state.windows[windowId]?.profileId == folder.profileId else { return nil as String? }
      return try store.dispatch(Command("openSidebarLiveItem", [
        .string(windowId), .string(folder.id), .string(item.id), .string(item.url), .bool(background),
      ]), origin: .native).result?.string
    }
    guard let tabId else { return nil }
    perform(.markRead(.object(["folderId": .string(folder.id), "itemIds": .array([.string(item.id)])])))
    FrameUpdates.flush()
    return tabId
  }

  private static func current(_ folder: LiveFolder, windowId: String, store: Store) -> (SidebarLive, LiveFolder)? {
    guard WorkspaceWrites.store === store, let window = store.state.windows[windowId], !window.incognito,
      window.profileId == folder.profileId, !store.memory.closingWindows.contains(windowId),
      let live = SidebarLiveFeed.shared.live, let latest = live.state.folders[folder.id], latest.profileId == folder.profileId else { return nil }
    return (live, latest)
  }

  private static func itemMenu(_ item: LiveItem, folder: LiveFolder, live: SidebarLive, windowId: String, store: Store) {
    let unread = live.state.unread[folder.id]?.contains(item.id) == true
    let tabId = store.state.sidebarLiveTab(windowId: windowId, folderId: folder.id, itemId: item.id)
    var items: [TabMenuItem] = [
      .init(id: "open", title: tabId == nil ? "Open" : "Show Tab", symbol: "arrow.up.forward.square"),
      .init(id: "background", title: "Open in Background", enabled: tabId == nil),
      .init(separator: true),
      .init(id: "copy", title: "Copy Link", symbol: "link"),
      .init(id: "copyMd", title: "Copy Link as Markdown", symbol: "text.badge.checkmark"),
      .init(id: "unread", title: unread ? "Mark as Read" : "Mark as Unread", symbol: unread ? "circle" : "circle.fill"),
    ]
    if item.pr != nil { items.append(.init(id: "hide", title: "Hide Until Refresh", symbol: "eye.slash")) }
    if tabId != nil { items += [.init(separator: true), .init(id: "close", title: "Close Tab", symbol: "xmark")] }
    NativeTabMenu.choose(items, store: store) { [weak store] choice in
      guard let store, let (latest, folder) = current(folder, windowId: windowId, store: store),
        let item = latest.state.items[folder.id]?.first(where: { $0.id == item.id }) else { return }
      switch choice {
      case "open", "background": _ = open(item, folder: folder, windowId: windowId, background: choice == "background", store: store)
      case "copy": SettingsAdapters.copyText(cleanUrl(item.url))
      case "copyMd": SettingsAdapters.copyText(markdownLink(title: item.title, url: item.url))
      case "unread":
        let id = LiveAnyJSON.string(item.id)
        if latest.state.unread[folder.id]?.contains(item.id) == true {
          perform(.markRead(.object(["folderId": .string(folder.id), "itemIds": .array([id])])))
        } else {
          perform(.markUnread(.object(["folderId": .string(folder.id), "itemId": id])))
        }
      case "hide": hide([item], folderId: folder.id)
      case "close":
        if let tab = store.state.sidebarLiveTab(windowId: windowId, folderId: folder.id, itemId: item.id) {
          NativeWorkspaceCommands.closeFromControl(tab, store: store)
        }
      default: break
      }
    }
  }

  private static func stackMenu(_ id: String, folder: LiveFolder, windowId: String, store: Store) {
    NativeTabMenu.choose([.init(id: "hide", title: "Hide Stack Until Refresh", symbol: "eye.slash")], store: store) { [weak store] choice in
      guard choice == "hide", let store, let (live, folder) = current(folder, windowId: windowId, store: store) else { return }
      hide((live.state.items[folder.id] ?? []).filter { $0.pr?.stack?.id == id }, folderId: folder.id)
    }
  }

  private static func hide(_ items: [LiveItem], folderId: String) {
    guard !items.isEmpty, let data = try? LiveJSON.encode(items), let encoded = try? LiveJSON.decode(LiveAnyJSON.self, from: String(decoding: data, as: UTF8.self)) else { return }
    perform(.hideItems(.object(["folderId": .string(folderId), "items": encoded])))
  }

  private static func sequence(_ live: SidebarLive, folder: LiveFolder, windowId: String, store: Store) -> [String] {
    let browser = store.state
    let pinned = SidebarQuery(browser).entries(windowId: windowId, profileId: folder.profileId).pinned
    return live.sequence(pinned, state: browser, windowId: windowId, profileId: folder.profileId)
  }

  private static func sources(_ kind: LiveFolderKind) -> [LiveSourceId] { kind == .pullRequests ? [.github] : [.notion, .gdrive] }

  static func createFolder(_ kind: LiveFolderKind, window: BrowserWindow) {
    guard !window.incognito else { return }
    perform(.newProfileLiveFolder(.object([
      "profileId": .string(window.profileId), "kind": .string(kind.rawValue),
    ])))
  }

  private static func folderMenu(_ folder: LiveFolder, live: SidebarLive, windowId: String, store: Store) {
    let order = sequence(live, folder: folder, windowId: windowId, store: store)
    let i = order.firstIndex(of: SidebarLive.prefix + folder.id)
    let id = folder.id
    let pr = folder.kind == .pullRequests
    var items: [TabMenuItem] = [
      .init(title: status(live, folder: folder), enabled: false),
      .init(id: "refresh", title: "Refresh", symbol: "arrow.clockwise", enabled: live.state.status[id]?.state != .updating),
      .init(separator: true),
    ]
    if pr {
      items += [
        .init(id: "authored", title: "Created by Me", checked: folder.filters.authored),
        .init(id: "reviewRequests", title: "Awaiting My Review", checked: folder.filters.reviewRequests),
        .init(separator: true),
        .init(id: "groupStacks", title: "Group Stacked Pull Requests", checked: folder.groupStacks),
        .init(id: "showCompleted", title: "Show Completed", checked: folder.showCompleted),
        .init(separator: true),
      ]
    }
    items += [
      .init(id: "sources", title: pr ? "Pull Requests" : "Documents", symbol: pr ? "arrow.triangle.pull" : "doc.text",
        children: sources(folder.kind).map { source in
          .init(id: "source:\(source.rawValue)", title: source.name + (live.state.accounts[source] == nil ? " (Not Connected)" : ""),
            checked: folder.sources.contains(source))
        }),
      .init(separator: true),
      .init(id: "rename", title: "Rename…", symbol: "character.cursor.ibeam"),
      .init(id: "icon", title: folder.icon == nil ? "Add Icon…" : "Change Icon…", symbol: "face.smiling"),
      .init(id: "read", title: "Mark All as Read", symbol: "circle", enabled: live.state.unread[id]?.isEmpty == false),
      .init(id: "collapse", title: folder.collapsed ? "Expand" : "Collapse", symbol: folder.collapsed ? "chevron.down" : "chevron.up"),
      .init(id: "up", title: "Move Up", enabled: i.map { $0 > 0 } ?? false),
      .init(id: "down", title: "Move Down", enabled: i.map { $0 < order.count - 1 } ?? false),
      .init(separator: true),
      .init(id: "settings", title: "Live Folder Settings…", symbol: "gearshape"),
      .init(id: "delete", title: "Delete Live Folder", symbol: "trash"),
    ]
    NativeTabMenu.choose(items, store: store) { [weak store] choice in
      guard let store, let (live, latest) = current(folder, windowId: windowId, store: store) else { return }
      folderChoice(choice, folder: latest, live: live, windowId: windowId, store: store)
    }
  }

  private static func folderChoice(_ choice: String, folder: LiveFolder, live: SidebarLive, windowId: String, store: Store) {
    let id = folder.id
    let payload: LiveAnyJSON = .object(["folderId": .string(id)])
    switch choice {
    case "refresh": perform(.manualRefresh(payload))
    case "read": perform(.markRead(payload))
    case "collapse": patch(id, ["collapsed": .bool(!folder.collapsed)])
    case "groupStacks": patch(id, ["groupStacks": .bool(!folder.groupStacks)])
    case "showCompleted": patch(id, ["showCompleted": .bool(!folder.showCompleted)])
    case "authored", "reviewRequests":
      patch(id, ["filters": .object([
        "authored": .bool(choice == "authored" ? !folder.filters.authored : folder.filters.authored),
        "reviewRequests": .bool(choice == "reviewRequests" ? !folder.filters.reviewRequests : folder.filters.reviewRequests),
      ])], refresh: true)
    case "settings": openSettings("liveFolders")
    case "delete": perform(.removeFolder(payload))
    case "rename":
      NativeWorkspaceRename.prompt("Rename Live Folder", value: folder.name, placeholder: "Live folder name",
        windowId: windowId, store: store, confirmTitle: "Rename") { name in
        if current(folder, windowId: windowId, store: store) != nil { patch(id, ["name": .string(name)]) }
      }
    case "icon":
      NativeSidebarIconPicker.open(windowId: windowId, kind: "live", id: "livefolder|\(id)")
    case "up", "down":
      arrange(live.movedFolder(id, by: choice == "up" ? -1 : 1, browser: store.state, windowId: windowId))
    default:
      guard choice.hasPrefix("source:"), let source = LiveSourceId(rawValue: String(choice.dropFirst(7))),
        sources(folder.kind).contains(source) else { return }
      guard live.state.accounts[source] != nil else { return openSettings("liveFolders") }
      let picked = folder.sources.contains(source) ? folder.sources.filter { $0 != source } : folder.sources + [source]
      patch(id, ["sources": .array((picked.isEmpty ? folder.sources : picked).map { .string($0.rawValue) })], refresh: true)
    }
  }

  private static func status(_ live: SidebarLive, folder: LiveFolder) -> String {
    let status = live.state.status[folder.id]
    let text: String
    if status == nil || status?.state == .initializing { text = "Loading…" }
    else if status?.state == .updating { text = "Updating…" }
    else if let error = status?.error { text = error.message }
    else if let last = status?.lastFetch, last > 0 {
      let minute = floor((live.now - last) / 60_000)
      text = minute < 1 ? "Updated just now" : minute < 60 ? "Updated \(Int(minute)) min ago" : "Updated \(Int(minute / 60)) hr ago"
    } else { text = "Not updated yet" }
    let hidden = live.state.hidden[folder.id]?.count ?? 0
    return hidden == 0 ? text : "\(text) · \(hidden) hidden until you refresh"
  }
}
