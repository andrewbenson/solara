import AppKit
import SolaraEngine
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeBookmarkCommands {
  #if DEBUG
  static var cancelConfirmation = false
  static var confirmations: [[String: String]] = []
  #endif
  private static var menuObserver: NSObjectProtocol?
  private static var menuProfile: String?
  private static var menuEngine: String?

  static func installMenu() {
    guard menuObserver == nil else { return }
    ShellMenus.setBookmarkMenuSource { menu() }
    menuObserver = NotificationCenter.default.addObserver(forName: NativeBookmarkOwner.projectionChanged, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { ShellMenus.refreshBookmarkMenus() }
    }
  }

  static func setMenuProfile(_ profile: String?, engine: String?) {
    guard menuProfile != profile || menuEngine != engine else { return }
    menuProfile = profile
    menuEngine = engine
    ShellMenus.refreshBookmarkMenus()
  }

  private static func menu() -> NativeBookmarkMenu {
    guard let profile = menuProfile, let engine = menuEngine, let owner = NativeBookmarkOwner.displayCurrent,
      let snapshot = try? owner.snapshot(profile: profile), snapshot.hasView, snapshot.binding.engine == engine else { return NativeBookmarkMenu() }
    let rows = BookmarkMenuProjection(document: snapshot.document, profile: profile, engine: engine)
    func row(_ value: BookmarkMenuProjection.Row) -> NativeBookmarkMenu.Row {
      NativeBookmarkMenu.Row(id: value.id, title: value.title, url: value.url, children: value.children?.map(row))
    }
    return NativeBookmarkMenu(folders: rows.folders.map(row), recent: rows.recent.map(row),
      bar: rows.bar.map(row), other: rows.other.map(row))
  }

  static func isBookmarked(_ url: String?, windowId: String?) -> Bool {
    guard let url, !url.isEmpty, let windowId, let editing = NativeBookmarkEditing(windowId: windowId),
      let view = editing.snapshot() else { return false }
    return BookmarkMenuProjection.contains(url: url, document: view.document, profile: editing.profile, engine: view.binding.engine)
  }

  private struct ToggleKey: Hashable {
    let profile: String
    let url: String
  }

  private static var toggling: Set<ToggleKey> = []

  static func toggle(_ tab: Tab, profile: String, windowId: String, store: Store) {
    let key = ToggleKey(profile: profile, url: tab.url)
    guard !tab.url.isEmpty, toggling.insert(key).inserted else { return }
    let owner = NativeBookmarkOwner.writableCurrent
    let generation = NativeStoreHandle.ownershipGeneration
    let mutation = BookmarkMutation(method: "toggleBookmark", args: [.string(profile), [
      "url": .string(tab.url), "title": .string(tab.title), "favicon": tab.favicon.map(JSONValue.string) ?? .null,
    ]])
    Task { @MainActor in
      defer { toggling.remove(key) }
      do {
        guard NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation else { return }
        guard let owner else { throw BookmarkWriterError.notOwned }
        guard NativeBookmarkOwner.writableCurrent === owner else { return }
        let binding = try owner.binding(profile: profile)
        _ = try await owner.submitAsync(profile: profile, mutations: [mutation], binding: binding, requestID: nil)
      } catch BookmarkWriterError.expired {
      } catch {
        guard NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation else { return }
        NSLog("[toolbar] bookmark toggle failed: %@", String(describing: error))
        if let host = WindowHost.contentView(windowId) {
          let title: String
          if case .savedUnconfirmed? = error as? BookmarkPendingStoreError { title = "Bookmark save unconfirmed" }
          else { title = "Bookmark not saved" }
          LinkToast.show(in: host, title: title)
        }
      }
    }
  }

  private static func plan(_ command: String, arg: String?, windowId: String?, store: Store) -> BookmarkOpenPlan? {
    let state = store.state
    let route = CommandRoute.resolve("openBookmark", windowId: windowId, state: state, closing: store.memory.closingWindows)
    let profile = state.bookmarkProfileId(route.windowId.flatMap { state.windows[$0] })
    let snapshot = try? NativeBookmarkOwner.displayCurrent?.snapshot(profile: profile)
    return BookmarkMenuCommand.plan(command: command, arg: arg, windowId: windowId, state: state,
      closing: store.memory.closingWindows, snapshot: snapshot)
  }

  static func openURL(_ url: String, mode: String, windowId: String) {
    let options: JSONValue = ["url": .string(url), "mode": .string(mode)]
    guard let data = try? JSONSerialization.data(withJSONObject: options.foundation) else { return }
    _ = perform("openBookmarkItems", arg: String(decoding: data, as: UTF8.self), windowId: windowId)
  }

  static let formCommands: Set<String> = ["bookmarkPage", "bookmarkTab", "bookmarkAllTabs", "editBookmark"]

  static func showForm(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard let store = NativeStoreHandle.store, NativeStoreHandle.ownsWorkspace else { return true }
    if let windowId, store.state.windows[windowId] == nil, !CommandRoute.utilityWindowIds.contains(windowId) { return true }
    let route = CommandRoute.resolve(command, windowId: windowId, state: store.state, closing: store.memory.closingWindows)
    switch command {
    case "bookmarkPage":
      if let id = route.windowId, let tab = route.tabId { NativeBookmarkForms.bookmarkTab(windowId: id, tabId: tab) }
    case "bookmarkTab":
      if let windowId, let arg { NativeBookmarkForms.bookmarkTab(windowId: windowId, tabId: arg) }
    case "bookmarkAllTabs":
      if let id = route.windowId { NativeBookmarkForms.bookmarkTabs(windowId: id) }
    case "editBookmark":
      if let windowId, let arg, let options = try? JSONValue.parse(arg) {
        NativeBookmarkForms.edit(windowId: windowId, id: options["id"]?.string, folder: options["folder"]?.truthy == true,
          parent: options["parentId"]?.string, index: options["index"]?.number.flatMap(Int.init(exactly:)), profile: options["profileId"]?.string)
      }
    default: break
    }
    return true
  }

  static func openItem(_ id: String, mode: String, folder: Bool = false, windowId: String) {
    let options: JSONValue = ["id": .string(id), "mode": .string(mode), "folder": .bool(folder)]
    guard let data = try? JSONSerialization.data(withJSONObject: options.foundation) else { return }
    _ = perform("openBookmarkItems", arg: String(decoding: data, as: UTF8.self), windowId: windowId)
  }

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return true }
    guard let wanted = plan(command, arg: arg, windowId: windowId, store: store) else { return true }
    let ownership = NativeStoreHandle.ownershipGeneration
    let owner = NativeBookmarkOwner.displayCurrent
    let finish: @MainActor @Sendable () -> Void = {
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == ownership,
        NativeBookmarkOwner.displayCurrent === owner,
        plan(command, arg: arg, windowId: windowId, store: store) == wanted else { return }
      let before = store.state
      do {
        var target = wanted.window?.id ?? ""
        var after: String?
        if wanted.window == nil || wanted.mode == "window" || wanted.mode == "incognito" {
          let options: JSONValue = ["url": .string(wanted.urls[0]), "profileId": .string(wanted.profile),
            "incognito": .bool(wanted.mode == "incognito" || wanted.window?.incognito == true)]
          guard let created = try store.dispatch(Command("createWindow", [options]), origin: .native).result?.string else { return }
          target = created
          after = store.state.activeTabId(target)
        }
        for (index, url) in wanted.urls.enumerated() {
          if index == 0, target != wanted.window?.id { continue }
          if wanted.mode == "current", let tab = wanted.tab {
            try store.dispatch(Command("navigate", [.string(tab.id), .string(url)]), origin: .native)
          } else if wanted.mode == "split" {
            let result = try store.dispatch(Command("openSplitPane", [.string(target), ["url": .string(url)]]), origin: .native)
            if result.result?["ok"]?.truthy == true { continue }
            try store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
          } else {
            var options: JSONObject = ["url": .string(url), "background": .bool(index > 0 || wanted.mode == "background")]
            if wanted.mode == "background", let tab = wanted.tab { options["openerId"] = .string(tab.id) }
            if let after, let position = store.state.windows[target]?.tabIds.firstIndex(of: after) {
              options["index"] = .number(Double(position + 1))
            }
            after = try store.dispatch(Command("newTab", [.string(target), .object(options)]), origin: .native).result?.string
          }
        }
        NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
        FrameUpdates.flush()
      } catch { NSLog("[commands] open bookmark failed: %@", String(describing: error)) }
    }
    if wanted.urls.count > 15 {
      #if DEBUG
      confirmations.append(["title": "Open \(wanted.urls.count) tabs?", "message": "This folder has a lot of bookmarks.", "confirmTitle": "Open All", "windowId": wanted.window?.id ?? ""])
      if cancelConfirmation { return true }
      #endif
      let alert = NSAlert()
      alert.messageText = "Open \(wanted.urls.count) tabs?"
      alert.informativeText = "This folder has a lot of bookmarks."
      alert.addButton(withTitle: "Open All")
      alert.addButton(withTitle: "Cancel")
      NativeWorkspaceCommands.askGuarded(alert, windowId: wanted.window?.id ?? "", setting: nil, store: store, then: finish)
    } else { finish() }
    return true
  }
}

extension NativeBookmarkCommands {
  private static let filing = BookmarkGroupFiling()

  static func addFolderToSidebar(_ id: String, editing: NativeBookmarkEditing, snapshot: BookmarkWriterSnapshot) {
    guard editing.live, SettingsDirectWrites.store === editing.store,
      let draft = BookmarkGroupDraft.folder(id, nodes: snapshot.document["nodes"]?.object ?? [:]) else { return }
    let store = editing.store
    let state = store.state
    let regular = { (id: String) in
      state.windows[id].map { !$0.incognito && !$0.isSmall } == true && !store.memory.closingWindows.contains(id)
    }
    let windows = (state.ui.focusOrder + state.windowOrder).filter(regular)
    let target = regular(editing.windowId) ? editing.windowId : windows.first { state.windows[$0]?.profileId == editing.profile } ?? windows.first
    guard let windowId = target ?? SettingsDirectWrites.write(store, Command("createWindow", [["profileId": .string(editing.profile)]]))?.result?.string else { return }
    let result = SettingsDirectWrites.write(store, Command("openDraftGroups", [.string(windowId), .string(editing.profile), [draft]]))?.result
    NativeWorkspaceCommands.materializeChanges(before: state, after: store.state)
    FrameUpdates.flush()
    if let skipped = result?["skipped"]?.number, skipped > 0, let host = WindowHost.contentView(windowId) {
      let count = Int(skipped).formatted(.number.locale(Locale(identifier: "en_US")))
      LinkToast.show(in: host, title: "\(count) \(skipped == 1 ? "link" : "links") left out", message: "A folder brings up to 5,000 links.")
    }
  }

  static func fileTabs(_ ids: [String], folder: String, windowId: String, store: Store) {
    guard let window = store.state.windows[windowId] else { return }
    let profile = store.state.bookmarkProfileId(window)
    func file(_ name: String?) {
      guard WorkspaceWrites.store === store, store.state.windows[windowId]?.profileId == window.profileId,
        ids.allSatisfy({ store.state.tabs[$0]?.windowId == windowId }) else { return }
      let pages = ids.compactMap { store.state.tabs[$0] }.filter { !$0.url.isEmpty }
      let mutations: [BookmarkMutation]
      if let name {
        let children: [JSONValue] = pages.map { ["title": .string(title($0)), "url": .string($0.url)] }
        mutations = [BookmarkMutation(method: "addBookmarkTree", args: [.string(profile), [["title": .string(name), "children": .array(children)]]])]
      } else {
        mutations = pages.map {
          BookmarkMutation(method: "addBookmark", args: [[
            "profileId": .string(profile), "title": .string(title($0)), "url": .string($0.url),
            "favicon": $0.favicon.map(JSONValue.string) ?? .null, "parentId": folder == "bar" ? .null : .string(folder),
          ]])
        }
      }
      guard !mutations.isEmpty else { return }
      Task { @MainActor in
        do {
          guard WorkspaceWrites.store === store, let owner = NativeBookmarkOwner.writableCurrent else { return }
          let binding = try owner.binding(profile: profile)
          if name == nil, folder != "bar" {
            let snapshot = try owner.snapshot(profile: profile)
            guard snapshot.document["nodes"]?[folder]?["kind"]?.string == "folder" else { return }
          }
          let receipt = try await owner.submitAsync(profile: profile, mutations: mutations, binding: binding)
          if name != nil { try await restoreIcons(pages.map(\.favicon), receipt: receipt, owner: owner, profile: profile, binding: binding) }
        } catch { failed(error, windowId: windowId) }
      }
    }
    if folder == "new" {
      NativeWorkspaceRename.prompt("New Folder", value: "", placeholder: "Folder name", windowId: windowId, store: store, confirmTitle: "Create") { file($0) }
    } else { file(nil) }
  }

  static func fileGroup(_ id: String, windowId: String, store: Store) {
    let state = store.state
    guard let editing = NativeBookmarkEditing(windowId: windowId), editing.store === store,
      let group = state.groups[id], group.windowId == windowId, group.profileId == state.windows[windowId]?.profileId,
      let owner = NativeBookmarkOwner.writableCurrent, let binding = try? owner.binding(profile: editing.profile) else { return }
    let original = groupTree(group, state: state)
    let mutation = BookmarkMutation(method: "addBookmarkTree", args: [.string(editing.profile), [original.draft]])
    Task {
      do {
        try await filing.run(id, save: {
          guard NativeBookmarkOwner.writableCurrent === owner else { throw BookmarkWriterError.staleBinding }
          return try await editing.write([mutation], binding: binding)
        }, didSave: { receipt in
          if editing.live, let current = store.state.groups[id], current.windowId == windowId, current.profileId == group.profileId,
            groupTree(current, state: store.state).members == original.members {
            _ = try? store.dispatch(Command("closeGroup", [.string(id)]), origin: .native)
            FrameUpdates.flush()
          }
          try await restoreIcons(original.icons, receipt: receipt, owner: owner, profile: editing.profile, binding: binding)
        })
      } catch { editing.report(error) }
    }
  }

  private static func title(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    return tab.title.isEmpty ? TabMenuPlan.tabLabel(tab) : tab.title
  }

  private static func groupTree(_ group: TabGroup, state: BrowserState) -> (draft: JSONValue, members: [String], icons: [String?]) {
    let nested = state.groups.values.filter { $0.parentId == group.id }
    var seen: Set<String> = []
    var members = [group.id]
    var children: [JSONValue] = []
    var icons: [String?] = []
    for id in group.tabIds {
      if let child = nested.first(where: { $0.tabIds.contains(id) }) {
        if seen.insert(child.id).inserted {
          let branch = groupTree(child, state: state)
          children.append(branch.draft)
          members += branch.members
          icons += branch.icons
        }
      } else if let tab = state.tabs[id] {
        members += [tab.id, tab.url]
        if !tab.url.isEmpty {
          children.append(["title": .string(title(tab)), "url": .string(tab.url)])
          icons.append(tab.favicon)
        }
      }
    }
    return (["title": .string(SidebarQuery(state).groupLabel(group.id)), "children": .array(children)], members, icons)
  }

  private static func restoreIcons(_ icons: [String?], receipt: BookmarkReceipt, owner: NativeBookmarkOwner,
    profile: String, binding: BookmarkWriterBinding) async throws
  {
    let nodes = receipt.view.document["nodes"]
    func links(_ id: String) -> [String] {
      guard let node = nodes?[id] else { return [] }
      return node["kind"]?.string == "url" ? [id] : (node["children"]?.array ?? []).compactMap(\.string).flatMap(links)
    }
    let ids = (receipt.results.first?.array ?? []).compactMap(\.string).flatMap(links)
    let updates = zip(ids, icons).compactMap { id, icon in
      icon.map { BookmarkMutation(method: "updateBookmark", args: [.string(id), ["favicon": .string($0)]]) }
    }
    if !updates.isEmpty { _ = try await owner.submitAsync(profile: profile, mutations: updates, binding: binding) }
  }

  private static func failed(_ error: Error, windowId: String) {
    NSLog("[sidebar] Bookmark save failed: %@", String(describing: error))
    if let host = WindowHost.contentView(windowId) { LinkToast.show(in: host, title: "Bookmark not saved") }
  }
}
