import AppKit
import SolaraEngine
import SolaraLive
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeTabMenu {
  #if DEBUG
  private(set) static var handled = 0
  #endif

  static func open(_ tabId: String, windowId: String) -> Bool {
    guard let store = WorkspaceWrites.store, let tab = store.state.tabs[tabId], tab.windowId == windowId else { return false }
    let selected = store.state.viewTabIds(windowId).filter { store.state.selection[windowId]?.ids.contains($0) == true }
    let multi = selected.count > 1 && selected.contains(tabId)
    let calendar = store.state.windows[windowId]?.incognito == false && tab.pinned && Meetings.isCalendarUrl(tab.pinnedUrl ?? tab.url) ? NativeSidebarLive.calendarMenu() : nil
    let planned = multi
      ? TabMenuPlan.multiItems(store.state, windowId: windowId, ids: selected, folders: bookmarkFolderItems(store.state, windowId: windowId))
      : TabMenuPlan.items(store.state, windowId: windowId, tabId: tabId, calendarItem: calendar)
    guard let items = planned else { return false }
    guard !items.isEmpty else { return true }
    if !multi, store.state.selection[windowId]?.ids.isEmpty == false {
      do {
        try store.dispatch(Command("setSelection", [.string(windowId), []]), origin: .native)
      } catch {
        return false
      }
      FrameUpdates.flush()
    }
    #if DEBUG
    handled += 1
    #endif
    choose(items, store: store) { [weak owner = store] choice in
      guard let store = WorkspaceWrites.store, store === owner, store.state.tabs[tabId]?.windowId == windowId, store.state.tabs[tabId]?.profileId == tab.profileId,
        !store.memory.closingWindows.contains(windowId),
        !multi || selected.allSatisfy({ store.state.tabs[$0]?.windowId == windowId && store.state.tabs[$0]?.profileId == tab.profileId }) else {
        return NSLog("[tabs] %@: gone or stood down while its menu was open", tabId)
      }
      if choice == "copy" || choice == "copyMd" || choice.hasPrefix("share:via:") {
        var options: [String: Any] = multi ? ["ids": selected] : ["tabId": tabId]
        if choice.hasPrefix("share:via:") { options["via"] = String(choice.dropFirst(10)) }
        let arg = (try? JSONSerialization.data(withJSONObject: options)).flatMap { String(data: $0, encoding: .utf8) }
        _ = NativeLinkCommands.perform(choice.hasPrefix("share:") ? "share" : choice == "copyMd" ? "copyUrlAsMarkdown" : "copyUrl", arg: arg, windowId: windowId)
        return
      }
      if multi {
        if choice == "close" {
          return NativeWorkspaceCommands.closeTabs(selected, windowId: windowId, store: store)
        }
        if choice == "bar" || choice.hasPrefix("folder:") {
          guard dispatch(store, Command("setSelection", [.string(windowId), []])) != nil else { return }
          return NativeBookmarkCommands.fileTabs(selected, folder: choice == "bar" ? "bar" : String(choice.dropFirst(7)), windowId: windowId, store: store)
        }
        guard let command = TabMenuPlan.multiCommand(choice, windowId: windowId, ids: selected, state: store.state) else { return }
        let before = store.state
        guard let result = dispatch(store, command) else { return }
        NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
        finish(choice, result: result, windowId: windowId, store: store)
      } else {
        run(choice, tabId: tabId, windowId: windowId, store: store)
      }
    }
    return true
  }

  static func sidebarAction(_ action: String, tabId: String, windowId: String) -> Bool {
    guard let store = WorkspaceWrites.store else { return false }
    guard let tab = store.state.tabs[tabId], tab.windowId == windowId else { return true }
    let command: Command
    switch action {
    case "tileDoubleClick":
      guard store.state.activeTabId(windowId) == tabId else { return true }
      NativePinnedPageCommands.request("returnToPinnedUrl", tabId: tabId)
      return true
    case "backToPinned":
      NativePinnedPageCommands.request("returnToPinnedUrl", tabId: tabId)
      return true
    case "toggleMute":
      command = Command("setSiteMuted", [.string(tabId), .bool(!tab.muted)])
    default:
      return false
    }
    _ = dispatch(store, command)
    return true
  }

  private static func run(
    _ choice: String, tabId: String, windowId: String, store: Store
  ) {
    guard let tab = store.state.tabs[tabId], tab.windowId == windowId else { return }
    switch choice {
    case "rename":
      _ = NativeWorkspaceRename.begin(windowId: windowId, kind: .tab, id: tabId)
    case "close":
      NativeWorkspaceCommands.closeFromControl(tabId, store: store)
    case "icon":
      NativeSidebarIconPicker.open(windowId: windowId, kind: "tab", id: tabId)
    case "engine":
      NativeEngineCommands.request(tabId: tabId, action: "toggle", options: [:]) { _ in }
    case "bookmark":
      NativeBookmarkCommands.toggle(tab, profile: store.state.bookmarkProfileId(store.state.windows[windowId]), windowId: windowId, store: store)
    case "newFolder":
      _ = NativeTileFolders.newFolderWithTab(windowId: windowId, tabId: tabId)
    case "leaveFolder":
      _ = NativeTileFolders.leaveFolder(tabId: tabId)
    case "editPin":
      guard store.state.inPinnedContainer(tabId) else { return }
      NativeWorkspaceRename.prompt("Edit Pinned Page", value: tab.pinnedUrl ?? tab.url, placeholder: "Enter Pinned URL",
        windowId: windowId, store: store, confirmTitle: "Save") { url in
        guard store.state.tabs[tabId]?.windowId == windowId, store.state.inPinnedContainer(tabId) else { return }
        _ = dispatch(store, Command("setPinnedUrl", [.string(tabId), .string(url.contains("://") ? url : "https://\(url)")]))
      }
    default:
      if NativeSidebarLive.runCalendarChoice(choice, windowId: windowId) { return }
      if let command = TabMenuPlan.command(choice, windowId: windowId, tabId: tabId, state: store.state) {
        let before = store.state
        guard let result = dispatch(store, command) else { return }
        NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
        finish(choice, result: result, windowId: windowId, store: store)
      } else if choice.hasPrefix("profile:") {
        NativeWorkspaceCommands.moveFromSidebar(tabId, windowId: windowId, target: String(choice.dropFirst(8)), store: store)
      }
    }
  }

  private static func finish(_ choice: String, result: JSONValue, windowId: String, store: Store) {
    if choice == "newGroup", let id = result.string, !id.isEmpty,
      WorkspaceActionRouter.sidebarShows(store.state, windowId: windowId) {
      if !NativeWorkspaceRename.begin(windowId: windowId, kind: .group, id: id) {
        NSLog("[sidebar] rename refused: native store unavailable or target stale")
      }
    }
    if choice.hasPrefix("window:"), let id = result.string, !id.isEmpty { ShellScripting.showWindow(id) }
  }

  private static func bookmarkFolderItems(_ state: BrowserState, windowId: String) -> [TabMenuItem] {
    let bar = TabMenuItem(id: "folder:bar", title: "Bookmarks Bar", symbol: "menubar.rectangle")
    let ending = [TabMenuItem(separator: true), TabMenuItem(id: "folder:new", title: "New Folder…", symbol: "folder.badge.plus")]
    let profile = state.bookmarkProfileId(state.windows[windowId])
    guard let owner = NativeBookmarkOwner.displayCurrent, let projection = try? owner.projection(),
      let engine = projection["profiles"]?[profile]?["engine"]?.string,
      let view = projection["views"]?[engine], view["hasView"]?.truthy == true,
      let nodes = view["document"]?["nodes"]?.object else { return [bar] + ending }
    let roots = BookmarkFlat.roots(engine)
    guard nodes[roots.bar]?["kind"]?.string == "folder", nodes[roots.other]?["kind"]?.string == "folder" else { return [bar] + ending }
    let folders = [roots.bar, roots.other].flatMap { root in
      (nodes[root]?["children"]?.array ?? []).compactMap { child -> TabMenuItem? in
        guard let id = child.string, let node = nodes[id], node["kind"]?.string == "folder" else { return nil }
        return TabMenuItem(id: "folder:\(id)", title: node["title"]?.string ?? "", symbol: "folder")
      }
    }
    return [bar, TabMenuItem(id: "folder:\(roots.other)", title: "Other Bookmarks", symbol: "folder")] + folders + ending
  }

  static func choose(_ items: [TabMenuItem], store: Store, then action: @escaping @MainActor (String) -> Void) {
    let hints = ShortcutsAdapter.hints
    ShellMenus.choose(items.map { dictionary($0, hints: hints) }) { choice in
      if let choice { action(choice) }
    }
  }

  private static func dictionary(_ item: TabMenuItem, hints: [JSKey: String]) -> [String: Any] {
    var row = item.dictionary
    let commands = ["newTab": "newTab", "search": "searchTabs", "clean": "cleanUpTabs", "closeAll": "closeAllTabs", "copy": "copyUrl", "copyMd": "copyUrlAsMarkdown", "backToPin": "returnToPinnedUrl", "newGroup": "newGroupWithTabs", "bookmark": "bookmarkPage", "close": "closeTab"]
    if let id = item.id, let command = commands[id], let hint = hints[JSKey(command)], let key = GroupMenu.menuKey(hint) {
      row["key"] = key.key
      row["modifiers"] = key.modifiers
    }
    if !item.children.isEmpty { row["children"] = item.children.map { dictionary($0, hints: hints) } }
    return row
  }

  private static func dispatch(_ store: Store, _ command: Command) -> JSONValue? {
    defer { FrameUpdates.flush() }
    do {
      return try store.dispatch(command, origin: .native).result ?? .null
    } catch {
      NSLog("[tabs] %@ refused: %@", command.name, String(describing: error))
      return nil
    }
  }
}

@MainActor
enum NativeSidebarMenus {
  static let commands: Set<String> = ["newTabInGroup", "newGroupWithTabs", "cleanUpTabs", "closeAllTabs", "renameTab", "changeTabIcon", "openProfileMenu"]

  static func perform(_ command: String, windowId: String?) -> Bool {
    guard let store = WorkspaceWrites.store else { return false }
    let state = store.state
    guard let windowId = state.resolveWindowId(windowId), let window = state.windows[windowId],
      !store.memory.closingWindows.contains(windowId) else { return true }
    let active = state.activeTabId(windowId)
    switch command {
    case "newTabInGroup":
      if let active, let group = Groups.innermostGroupOf(state.groups, active) {
        NativeWorkspaceCommands.newTabInGroup(group.id, windowId: windowId, store: store)
      } else { _ = NativeWorkspaceCommands.perform("newTab", windowId: windowId) }
    case "newGroupWithTabs":
      let ids = state.viewTabIds(windowId)
      let selected = ids.filter { state.selection[windowId]?.ids.contains($0) == true }
      let eligible = (selected.isEmpty ? active.map { [$0] } ?? [] : selected).filter { state.tabs[$0]?.pinSection != .tile }
      if !eligible.isEmpty, let group = (try? store.dispatch(Command("groupTabs", [JSONValue(eligible)]), origin: .native))?.result?.string,
        WorkspaceActionRouter.sidebarShows(store.state, windowId: windowId) {
        _ = NativeWorkspaceRename.begin(windowId: windowId, kind: .group, id: group)
      }
      FrameUpdates.flush()
    case "renameTab":
      if let active { _ = NativeWorkspaceRename.begin(windowId: windowId, kind: .tab, id: active) }
    case "changeTabIcon":
      if let active { NativeSidebarIconPicker.open(windowId: windowId, kind: "tab", id: active) }
    case "openProfileMenu":
      if window.isSmall {
        Task { @MainActor in NativeWorkspaceCommands.littleProfileMenu(windowId: windowId, store: store) }
      } else { profiles(windowId: windowId) }
    case "cleanUpTabs": run("clean", window: window, devices: [], store: store)
    case "closeAllTabs": run("closeAll", window: window, devices: [], store: store)
    default: return false
    }
    return true
  }

  static func profiles(windowId: String) {
    guard let store = WorkspaceWrites.store, let window = store.state.windows[windowId], !window.incognito else { return }
    let hints = ShortcutsAdapter.hints
    let resolved = hints.values.compactMap(GroupMenu.menuKey)
    let profiles = WorkspaceMenuDestinations.profileRows(state: store.state, window: window)
    var menu: [[String: Any]] = []
    for profile in profiles {
      var row: [String: Any] = ["id": "switch:\(profile.id)", "title": profile.title, "checked": profile.current,
                                 "swatch": NativeLayoutAppearance.profileSwatch(store.state.profiles[profile.id])]
      let key = hints[JSKey("switchProfile:\(profile.id)")].flatMap(GroupMenu.menuKey)
      if let key {
        row["key"] = key.key
        row["modifiers"] = key.modifiers
      }
      menu.append(row)
      if key?.modifiers.contains("command") != true {
        let modifiers = (key?.modifiers ?? []) + ["command"]
        if !resolved.contains(where: { $0.key == key?.key && Set($0.modifiers) == Set(modifiers) }) {
          row["id"] = "window:\(profile.id)"
          row["title"] = "\(profile.title) ↗"
          row["alternate"] = true
          row["checked"] = false
          row["modifiers"] = modifiers
          menu.append(row)
        }
      }
    }
    menu += [
      ["separator": true],
      ["id": "new", "title": "New Profile", "symbol": "plus"],
      ["id": "edit", "title": "Edit Profiles…", "symbol": "pencil"],
    ]
    ShellMenus.choose(menu) { [weak store] choice in
      guard let choice, let store, WorkspaceWrites.store === store, store.state.windows[windowId]?.incognito == false,
        !store.memory.closingWindows.contains(windowId) else { return }
      switch choice {
      case "edit": editProfiles(windowId: windowId)
      case "new":
        Task { @MainActor [weak store] in
          guard let store, let profile = await SettingsAdapters.js("sidebar.profileForm", windowId) as? String,
            WorkspaceWrites.store === store else { return }
          switchProfile(profile, windowId: windowId, store: store)
        }
      default:
        if choice.hasPrefix("switch:") { switchProfile(String(choice.dropFirst(7)), windowId: windowId, store: store) }
        else if choice.hasPrefix("window:"), store.state.profiles[String(choice.dropFirst(7))] != nil {
          let before = store.state
          _ = try? store.dispatch(Command("createWindow", [["profileId": .string(String(choice.dropFirst(7)))]]), origin: .native)
          NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
          FrameUpdates.flush()
        }
      }
    }
  }

  static func editProfiles(windowId: String) {
    guard let window = WorkspaceWrites.store?.state.windows[windowId], !window.incognito else { return }
    NativeSettingsWindow.navigate(pane: "profiles", profileId: window.profileId, detail: nil)
    WindowHost.openAuxiliary(id: NativeSettingsWindow.windowId, kind: "settings", title: "Settings")
  }

  private static func switchProfile(_ profile: String, windowId: String, store: Store) {
    guard store.state.windows[windowId]?.incognito == false, store.state.profiles[profile] != nil,
      !store.memory.closingWindows.contains(windowId) else { return }
    if let pager = NativeProfilePager.hosts[windowId] { pager.switchTo(profile) }
    else { _ = try? store.dispatch(Command("switchProfile", [.string(windowId), .string(profile)]), origin: .native) }
    FrameUpdates.flush()
  }

  static func open(windowId: String, overflow: Bool) {
    guard let store = WorkspaceWrites.store, let window = store.state.windows[windowId] else { return }
    let state = store.state
    let ids = state.viewTabIds(windowId)
    var items: [TabMenuItem] = []
    if !overflow { items.append(.init(id: "newTab", title: "New Tab", symbol: "plus")) }
    items += [.init(id: "search", title: "Search Tabs…", symbol: "magnifyingglass"), .init(separator: true)]
    let devices = window.incognito ? [] : syncRoutes(window.profileId)
    if overflow { items += overflowItems(state, window: window, ids: ids, devices: devices) }
    let muted = allMuted(ids, state: state)
    items.append(.init(id: "clean", title: "Clean Up Tabs", symbol: "wand.and.stars"))
    if overflow {
      items += [.init(id: "daily", title: "Clean Up Daily", checked: state.settings.number("cleanUpInactiveTabsAfterHours") != nil), .init(separator: true)]
    }
    items += [
      .init(id: "mute", title: muted ? "Unmute All Tabs" : "Mute All Tabs", symbol: muted ? "speaker.wave.2" : "speaker.slash"),
      .init(id: "closeAll", title: "Close All Tabs", symbol: "xmark"),
    ]
    if !overflow {
      items.append(.init(separator: true))
      if NativeWindowShell.host(windowId)?.ownsNativeLayout == true {
        let editable = state.settings.fileLayer?.sets("sidebarPosition") != true
        let current = window.effectiveSidebarPosition(state.settings)
        items.append(.init(id: "sidebarPosition", title: "Sidebar Position", children: ["left", "right"].map { position in
          .init(id: "position:\(position)", title: position.capitalized, enabled: editable, checked: current == position)
        }))
      }
      items.append(.init(id: "live", title: "New Live Folder", symbol: "dot.radiowaves.left.and.right", enabled: !window.incognito, children: [
        .init(id: "live:pullRequests", title: "Pull Requests", symbol: "arrow.triangle.pull"),
        .init(id: "live:documents", title: "Documents", symbol: "doc.text"),
      ]))
    }
    NativeTabMenu.choose(items, store: store) { [weak store] choice in
      guard let store, WorkspaceWrites.store === store, let current = store.state.windows[windowId],
        current.profileId == window.profileId, !store.memory.closingWindows.contains(windowId) else { return }
      run(choice, window: current, devices: devices, store: store)
    }
  }

  private static func allMuted(_ ids: [String], state: BrowserState) -> Bool {
    let tabs = ids.compactMap { state.tabs[$0] }.filter { !$0.url.isEmpty }
    return !tabs.isEmpty && tabs.allSatisfy(\.muted)
  }

  private static func overflowItems(_ state: BrowserState, window: BrowserWindow, ids: [String], devices: [[String: Any]]) -> [TabMenuItem] {
    let now = Date().timeIntervalSince1970 * 1000
    let selected = state.activeTabId(window.id)
    let open = ids.compactMap { id in
      state.tabs[id].map { TabMenuItem(id: "tab:\(id)", title: TileFolderPanel.title($0), checked: selected == id) }
    }
    let closed = state.closedTabs.filter { $0.tab.profileId == window.profileId }.map {
      ($0.closedAt, TabMenuItem(id: "restore:\($0.id)", title: archiveTitle($0), symbol: "clock.arrow.circlepath"))
    }
    let groups = state.closedGroups.filter { window.incognito ? $0.windowId == window.id : !$0.tabs.contains(where: { Ids.isIncognitoProfile($0.profileId) }) }.map {
      ($0.closedAt, TabMenuItem(id: "restore:\($0.id)", title: groupTitle($0), symbol: "rectangle.stack"))
    }
    let recent = (closed + groups).sorted { $0.0 > $1.0 }.prefix(15).map(\.1)
    let cleaned = WorkspaceCleanup.cleanedEntries(state: state, windowId: window.id, now: now)
    var cleanedItems = cleaned.suffix(20).reversed().map { TabMenuItem(id: "cleaned:\($0.id)", title: archiveTitle($0)) }
    if !cleanedItems.isEmpty { cleanedItems += [.init(separator: true), .init(id: "restoreAll", title: "Restore \(countLabel(cleaned.count))")] }
    let deleted = WorkspaceCleanup.deletedEntries(state: state, now: now).filter {
      window.incognito ? $0.windowId == window.id : !$0.tabs.contains(where: { Ids.isIncognitoProfile($0.profileId) })
    }.reversed().map { TabMenuItem(id: "restore:\($0.id)", title: groupTitle($0), symbol: "trash") }
    let empty = [TabMenuItem(title: "Empty", enabled: false)]
    var items = [TabMenuItem(id: "open", title: "Open Tabs", symbol: "square.stack", enabled: !open.isEmpty, children: open)]
    if !window.incognito, let devices = syncedDevices(devices) { items.append(devices) }
    items += [
      .init(id: "closed", title: "Recently Closed", symbol: "clock.arrow.circlepath", enabled: !recent.isEmpty, children: recent.isEmpty ? empty : recent),
      .init(id: "cleaned", title: "Recently Cleaned", symbol: "wand.and.stars", enabled: !cleanedItems.isEmpty, children: cleanedItems.isEmpty ? empty : cleanedItems),
    ]
    if !deleted.isEmpty { items.append(.init(id: "deleted", title: "Recently Deleted Groups", symbol: "trash", children: deleted)) }
    items.append(.init(separator: true))
    return items
  }

  private static func archiveTitle(_ entry: ClosedTab) -> String {
    if let title = entry.tab.customTitle, !title.isEmpty { return title }
    if !entry.tab.title.isEmpty { return entry.tab.title }
    return displayUrl(entry.tab.url)
  }

  private static func groupTitle(_ entry: ClosedGroup) -> String { "\(entry.group.name) (\(countLabel(entry.tabs.count)))" }
  private static func countLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "Tab" : "Tabs")" }

  private static func syncRoutes(_ profile: String) -> [[String: Any]] {
    (SettingsJS.shared.latestValue("sidebar.syncedDevices") as? [String: [[String: Any]]])?[profile] ?? []
  }

  private static func syncedDevices(_ devices: [[String: Any]]) -> TabMenuItem? {
    guard !devices.isEmpty else { return nil }
    func tabs(_ index: Int, _ device: [String: Any]) -> [TabMenuItem] {
      [.init(title: "Recent Tabs", enabled: false)] + (device["tabs"] as? [[String: String]] ?? []).enumerated().map {
        .init(id: "synced:\(index):\($0.offset)", title: $0.element["title"] ?? $0.element["url"] ?? "")
      }
    }
    if devices.count == 1 {
      let name = devices[0]["name"] as? String ?? ""
      let kind = name.replacingOccurrences(of: "’", with: "'").components(separatedBy: "'s ").dropFirst().joined(separator: "'s ").jsTrim()
      return .init(id: "synced", title: "Your \(kind.isEmpty ? name : kind) Tabs", symbol: "macbook.and.iphone", children: tabs(0, devices[0]))
    }
    return .init(id: "synced", title: "Your Devices", symbol: "macbook.and.iphone", children: devices.enumerated().map {
      .init(title: $0.element["name"] as? String ?? "", symbol: "laptopcomputer", children: tabs($0.offset, $0.element))
    })
  }

  private static func run(_ choice: String, window: BrowserWindow, devices: [[String: Any]], store: Store) {
    let id = JSONValue.string(window.id)
    let command: Command
    switch choice {
    case "newTab": _ = NativeWorkspaceCommands.perform("newTab", windowId: window.id); return
    case "search": _ = NativeWorkspaceCommands.perform("searchTabs", windowId: window.id); return
    case "clean": command = Command("cleanUpTabs", [id])
    case "closeAll": return NativeSidebarUndo.clear(windowId: window.id, store: store)
    case "mute":
      let ids = store.state.viewTabIds(window.id)
      command = Command("setMuted", [JSONValue(ids), .bool(!allMuted(ids, state: store.state))])
    case "daily":
      let daily = store.state.settings.number("cleanUpInactiveTabsAfterHours") != nil
      command = Command("updateSettings", [["cleanUpInactiveTabsAfterHours": daily ? .null : 24]])
    case "restoreAll": command = Command("restoreCleaned", [.null, id])
    case "position:left", "position:right": command = Command("setSidebarPosition", [id, .string(String(choice.dropFirst(9)))])
    default:
      if choice.hasPrefix("tab:"), let tab = store.state.tabs[String(choice.dropFirst(4))], tab.windowId == window.id, tab.profileId == window.profileId {
        command = Command("activate", [.string(tab.id)])
      } else if choice.hasPrefix("restore:") {
        command = Command("restoreClosed", [.string(String(choice.dropFirst(8))), id])
      } else if choice.hasPrefix("cleaned:") {
        command = Command("restoreCleaned", [.string(String(choice.dropFirst(8))), id])
      } else if choice.hasPrefix("live:"), let kind = LiveFolderKind(rawValue: String(choice.dropFirst(5))) {
        return NativeSidebarLive.createFolder(kind, window: window)
      } else if !window.incognito, choice.hasPrefix("synced:") {
        let indices = choice.split(separator: ":").dropFirst().compactMap { Int($0) }
        guard indices.count == 2, devices.indices.contains(indices[0]),
          let tabs = devices[indices[0]]["tabs"] as? [[String: String]], tabs.indices.contains(indices[1]),
          let url = tabs[indices[1]]["url"] else { return }
        command = Command("newTab", [id, ["url": .string(url)]])
      } else { return }
    }
    let before = store.state
    _ = try? store.dispatch(command, origin: .native)
    NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
    FrameUpdates.flush()
  }
}

@MainActor
enum NativeSidebarUndo {
  private static var serial = -300_000
  private static var watches: [String: (store: Store, subscription: Int, id: Int)] = [:]

  static func tidy(windowId: String, profileId: String? = nil, store: Store) {
    guard store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId),
      let result = (try? store.dispatch(Command("tidyPins", [.string(windowId), JSONValue(profileId)]), origin: .native))?.result,
      let tidied = try? TidiedPins(json: result) else { return }
    FrameUpdates.flush()
    func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
    let pins = tidied.pins, folders = tidied.folders, duplicates = tidied.duplicates
    let closed = duplicates > 0 ? "Closed \(count(duplicates, pins > 0 ? "duplicate" : "Duplicate Pin"))" : nil
    let title = pins > 0 ? "Tidied \(count(pins, "Pin")) into \(count(folders, "Folder"))" : closed ?? ""
    guard !title.isEmpty else { return }
    stop(windowId)
    serial -= 1
    let id = serial
    let generation = NativeStoreHandle.ownershipGeneration
    NativeSplitChrome.showNativeToast(.init(id: id, title: title, message: pins > 0 ? closed : nil, icon: "sparkles", action: "Undo"), windowId: windowId) { [weak store] in
      guard let store, WorkspaceWrites.store === store, NativeStoreHandle.ownershipGeneration == generation,
        store.state.windows[windowId] != nil, !store.memory.closingWindows.contains(windowId) else { return }
      _ = try? store.dispatch(Command("untidyPins", [result]), origin: .native)
      FrameUpdates.flush()
    }
  }

  static func clear(windowId: String, store: Store) {
    guard store.state.windows[windowId] != nil,
      let cleared = (try? store.dispatch(Command("clearUnpinnedTabs", [.string(windowId)]), origin: .native))?.result,
      let entries = cleared["entries"]?.array, !entries.isEmpty else { return }
    FrameUpdates.flush()
    let noun = entries.count == 1 ? "Tab" : "Tabs"
    show(cleared, title: "Cleared \(entries.count) \(noun)", icon: "arrow.down", store: store)
  }

  static func show(_ cleared: JSONValue, title: String, icon: String, store: Store) {
    guard let windowId = cleared["windowId"]?.string, cleared["entries"]?.array?.isEmpty == false else { return }
    stop(windowId)
    serial -= 1
    let id = serial
    let subscription = store.subscribe { [weak store] commit in
      let changes = commit.changes
      guard !changes.windows.isEmpty || !changes.tabs.isEmpty || !changes.groups.isEmpty || !changes.splits.isEmpty
        || changes.lists.contains("closedTabs") else { return }
      Task { @MainActor in
        guard watches[windowId]?.id == id, let store else { return }
        if WorkspaceWrites.store !== store || !store.canUndoSidebarClear(cleared) { stop(windowId, id: id) }
      }
    }
    watches[windowId] = (store, subscription, id)
    NativeSplitChrome.showNativeToast(.init(id: id, title: title, icon: icon, action: "Undo"), windowId: windowId) { [weak store] in
      guard let store, WorkspaceWrites.store === store, watches[windowId]?.id == id else { return }
      stop(windowId, id: id)
      _ = try? store.dispatch(Command("undoClearTabs", [cleared]), origin: .native)
      FrameUpdates.flush()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { stop(windowId, id: id) }
  }

  private static func stop(_ windowId: String, id: Int? = nil) {
    guard let watch = watches[windowId], id == nil || watch.id == id else { return }
    watches[windowId] = nil
    watch.store.unsubscribe(watch.subscription)
    NativeSplitChrome.hideNativeToast(watch.id, windowId: windowId)
  }
}
