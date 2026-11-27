import AppKit
import Foundation
import SolaraEngine
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeBookmarksBar {
  nonisolated static let kind = "bookmarksBar"

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeBookmarksBar)
  }

  static func registerMenuSource() {
    NativeBookmarkMenuSource.read = { profile in
      nonisolated(unsafe) var result: [String: Any]?
      MainActor.assumeIsolated {
        guard let owner = NativeBookmarkOwner.displayCurrent, let snapshot = try? owner.snapshot(profile: profile), snapshot.hasView else { return }
        result = bookmarkMenus(snapshot.document, profile: profile, engine: snapshot.binding.engine)
      }
      return result
    }
  }

  static func bookmarkMenus(_ document: JSONValue, profile: String, engine: String) -> [String: Any] {
    let nodes = document["nodes"]?.object ?? [:]
    let roots = BookmarkFlat.roots(engine)
    let bar = document["roots"]?[profile]?["bar"]?.string ?? roots.bar
    let other = document["roots"]?[profile]?["other"]?.string ?? roots.other
    func children(_ id: String) -> [String] { nodes[id]?["children"]?.array?.compactMap(\.string).filter { nodes[$0] != nil } ?? [] }
    func tree(_ parent: String, depth: Int = 0) -> [[String: Any]] {
      children(parent).compactMap { id in
        guard let node = nodes[id] else { return nil }
        let title = node["title"]?.string ?? ""
        if node["kind"] == "url" { return ["id": id, "title": title.isEmpty ? node["url"]?.string ?? "" : title, "url": node["url"]?.string ?? ""] }
        return ["id": id, "title": title, "children": depth < 6 ? tree(id, depth: depth + 1) : []]
      }
    }
    let rootKeys: Set<JSKey> = [JSKey(bar), JSKey(other)]
    func belongs(_ id: String) -> Bool {
      var current: String? = id
      var seen = Set<JSKey>()
      var depth = 0
      while let id = current, depth < 64, seen.insert(JSKey(id)).inserted {
        depth += 1
        if rootKeys.contains(JSKey(id)) { return true }
        current = nodes[id]?["parentId"]?.string
      }
      return false
    }
    let recent = nodes.enumerated().filter { $0.element.value["kind"] == "url" && belongs($0.element.key) }.sorted {
      let a = $0.element.value["addedAt"]?.number ?? 0, b = $1.element.value["addedAt"]?.number ?? 0
      return a == b ? $0.offset < $1.offset : a > b
    }.prefix(5).map { entry -> [String: Any] in
      let node = entry.element.value, url = node["url"]?.string ?? "", title = node["title"]?.string ?? ""
      return ["id": entry.element.key, "title": title.isEmpty ? url : title, "url": url]
    }
    let folders: [[String: Any]] = [["id": bar, "title": "Bookmarks Bar"], ["id": other, "title": "Other Bookmarks"]]
      + (children(bar) + children(other)).filter { nodes[$0]?["kind"] == "folder" }.map { ["id": $0, "title": nodes[$0]?["title"]?.string ?? ""] }
    return ["bookmarkFolders": folders, "recentBookmarks": recent, "bookmarksBar": tree(bar), "otherBookmarks": tree(other)]
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId, state in
      let host = BookmarksBarHost(windowId: windowId)
      host.observeStore()
      host.apply(state)
      #if DEBUG
      devHosts[windowId] = BookmarksBarDevHost(host)
      return HostedContent(view: host.view, onUnmount: { [weak host] in
        if devHosts[windowId]?.value === host { devHosts[windowId] = nil }
      }, takesFocus: false, onState: { host.apply($0) })
      #else
      return HostedContent(view: host.view, takesFocus: false, onState: { host.apply($0) })
      #endif
    }
  }
}

@MainActor
final class BookmarksBarHost {
  let view: BookmarksBarView
  private var metadata: BookmarksBarSnapshot?
  private var bookmarkObserver: NSObjectProtocol?
  private var storeListener: (Store, Int)?
  private var theme = SplitChromeTheme.fallback
  private var binding: BookmarkWriterBinding?
  private var engine: String?

  init(windowId: String) {
    view = BookmarksBarView(favicons: PageNetwork.favicons)
    view.windowId = windowId
    view.resolveTab = { id, sourceWindow in
      guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId],
        state.windows[sourceWindow]?.profileId == window.profileId, let tab = state.tabs[id],
        BookmarksBarEdits.acceptsTab(sourceWindow: sourceWindow, targetProfile: window.profileId,
          tabWindow: tab.windowId, tabProfile: tab.profileId) else { return nil }
      return BookmarksBarDroppedLink(url: tab.url, title: tab.title)
    }
    view.onFocusPage = {
      guard let state = NativeStoreHandle.store?.state,
        let tab = state.peeks[windowId]?.tabId ?? state.activeTabId(windowId) else { return }
      _ = SidePanelFocus.focus(windowId: windowId, tabId: tab)
    }
    view.onAction = { [weak self] name, payload in
      self?.perform(name, payload: payload)
    }
    bookmarkObserver = NotificationCenter.default.addObserver(forName: NativeBookmarkOwner.projectionChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    NativeBookmarksBar.registerScaleHost(self, windowId: windowId)
  }

  func observeStore() {
    guard let store = NativeStoreHandle.store else { return }
    let windowId = view.windowId
    let token = store.subscribe { [weak self] commit in
      let changes = commit.changes
      guard changes.settings || changes.windows.upserted.contains(windowId) || changes.windows.removed.contains(windowId) || !changes.profiles.isEmpty else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, let state = NativeStoreHandle.store?.state else { return }
        updateNative(state, theme: theme)
      }
    }
    storeListener = (store, token)
  }

  func updateNative(_ state: BrowserState, theme: SplitChromeTheme) {
    self.theme = theme
    guard let window = state.windows[view.windowId] else { return }
    let sidebarEdge = window.sidebarOpen && (window.tabLayout ?? state.settings.string("tabLayout")) != "top"
      ? CGFloat(window.effectiveSidebarWidth(state.settings)) : nil
    let profile = state.bookmarkProfileId(window)
    let engine = state.engineProfile(profile)
    let next = BookmarksBarSnapshot(profileId: profile, items: [], hasOther: false,
      hideBookmarksBarImport: state.settings.bool("hideBookmarksBarImport"), theme: theme.tokens, dark: theme.dark,
      sidebarEdge: sidebarEdge, bookmarksBar: state.settings.string("bookmarksBar") ?? "newTab")
    guard next != metadata || engine != self.engine else { return }
    self.engine = engine
    metadata = next
    refresh()
  }

  func apply(_ json: String) {
    guard let tokens = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let state = NativeStoreHandle.store?.state else { return }
    updateNative(state, theme: SplitChromeTheme(tokens))
  }

  private func refresh() {
    guard let metadata else { return }
    guard let owner = NativeBookmarkOwner.displayCurrent, let snapshot = try? owner.snapshot(profile: metadata.profileId),
      snapshot.binding.engine == engine, snapshot.hasView else {
      binding = nil
      view.update(metadata)
      return
    }
    binding = snapshot.binding
    view.update(metadata.reading(snapshot.document, engine: snapshot.binding.engine))
  }

  private func perform(_ name: String, payload: [String: Any]) {
    let windowId = view.windowId
    guard !NativeStoreHandle.frozen, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let editing = NativeBookmarkEditing(windowId: windowId), editing.profile == payload["profileId"] as? String else { return }
    let action = payload["action"] as? String ?? ""
    let id = payload["id"] as? String
    if name == "importPress" { NativeImportWindow.open(); return }
    if action == "manage" {
      _ = NativeWorkspaceCommands.perform("openLibraryPage", arg: #"{"page":"bookmarks"}"#, windowId: windowId)
      return
    }
    if action == "hide" || action == "bar" {
      let patch: JSONValue
      if action == "hide" { patch = ["hideBookmarksBarImport": true] }
      else if let id, ["always", "newTab", "never"].contains(id) { patch = ["bookmarksBar": .string(id)] }
      else { return }
      _ = SettingsDirectWrites.write(editing.store, Command("updateSettings", [patch]))
      FrameUpdates.flush()
      return
    }

    guard let snapshot = editing.snapshot(), snapshot.binding == binding else { return }
    let roots = BookmarkFlat.roots(snapshot.binding.engine)
    let bar = snapshot.document["roots"]?[editing.profile]?["bar"]?.string ?? roots.bar
    let other = snapshot.document["roots"]?[editing.profile]?["other"]?.string ?? roots.other
    let edits = BookmarksBarEdits(profile: editing.profile, bar: bar, other: other, document: snapshot.document)
    let listed = payload["listed"] as? [String]
    if name == "move", let id, let listed {
      submit(edits.move(id, into: payload["into"] as? String, index: payload["index"] as? Int, listed: listed), editing, snapshot.binding)
      return
    }
    if name == "dropLinks", let parent = payload["parentId"] as? String, let items = payload["items"] as? [[String: String]] {
      let links = items.compactMap { item in item["url"].map { BookmarksBarDroppedLink(url: $0, title: item["title"] ?? "") } }
      submit(edits.drop(links, parent: parent, index: payload["index"] as? Int, listed: listed), editing, snapshot.binding)
      return
    }
    if let id, !edits.contains(id) { return }
    if name == "press", let id {
      let shift = payload["shiftKey"] as? Bool == true
      let background = payload["metaKey"] as? Bool == true || payload["middle"] as? Bool == true
      let split = payload["altKey"] as? Bool == true
      let mode = background ? (shift ? "foreground" : "background") : (split ? "split" : (shift ? "window" : "current"))
      NativeBookmarkCommands.openItem(id, mode: mode, windowId: windowId)
      return
    }
    if name == "folderToSidebar", let id, let listed, edits.children(bar) == listed, listed.contains(id) {
      NativeBookmarkCommands.addFolderToSidebar(id, editing: editing, snapshot: snapshot)
      return
    }
    guard name == "menuChoice" else { return }
    let itemModes = ["open": "current", "tab": "foreground", "window": "window", "incognito": "incognito", "split": "split"]
    let folderModes = ["openAll": "tabs", "openAllWindow": "window", "openAllIncognito": "incognito"]
    if let id, let mode = itemModes[action] ?? folderModes[action] {
      NativeBookmarkCommands.openItem(id, mode: mode, folder: folderModes[action] != nil, windowId: windowId)
      return
    }
    switch action {
    case "addGroup":
      if let id { NativeBookmarkCommands.addFolderToSidebar(id, editing: editing, snapshot: snapshot) }
    case "restoreArc":
      if let id { _ = NativeWorkspaceCommands.perform("restoreArcFolders", arg: id, windowId: windowId) }
    case "edit", "rename":
      if let id { NativeBookmarkForms.edit(windowId: windowId, id: id) }
    case "delete":
      if let id, let node = edits.nodes[id], node["parentId"]?.string != nil {
        submit([.init(method: "expectBookmarkNodes", args: [[id: node]]), .init(method: "removeBookmark", args: [.string(id)])], editing, snapshot.binding)
      }
    case "addPage", "addFolder":
      let parent = id.flatMap { edits.nodes[$0]?["parentId"]?.string } ?? bar
      let index = id.flatMap { edits.children(parent).firstIndex(of: $0) }.map { $0 + 1 }
      if action == "addPage" {
        NativeBookmarkForms.edit(windowId: windowId, id: nil, parent: parent, index: index)
      } else if edits.nodes[parent]?["kind"] == "folder" {
        let binding = snapshot.binding
        NativeWorkspaceRename.prompt("New Folder", value: "", placeholder: "Folder name", windowId: windowId,
          store: editing.store, confirmTitle: "Create") { [weak self] title in
          guard let current = editing.snapshot(), current.binding == binding,
            let children = current.document["nodes"]?[parent]?["children"]?.array?.compactMap(\.string) else { return }
          let position = id.flatMap { children.firstIndex(of: $0) }
          guard id == nil || position != nil else { return }
          self?.submit([.init(method: "expectChildren", args: [.string(editing.profile), .string(parent), JSONValue(children)]),
            .init(method: "addBookmarkFolder", args: [["profileId": .string(editing.profile),
              "title": .string(title), "parentId": .string(parent), "index": position.map { JSONValue($0 + 1) } ?? .null]])], editing, binding)
        }
      }
    default: break
    }
  }

  private func submit(_ mutations: [BookmarkMutation], _ editing: NativeBookmarkEditing, _ binding: BookmarkWriterBinding) {
    guard !mutations.isEmpty else { return }
    Task {
      do { _ = try await editing.write(mutations, binding: binding) }
      catch { editing.report(error) }
    }
  }

  isolated deinit {
    if let bookmarkObserver { NotificationCenter.default.removeObserver(bookmarkObserver) }
    if let (store, token) = storeListener { store.unsubscribe(token) }
  }
}

#if DEBUG
@MainActor
extension NativeBookmarksBar {
  private static var devHosts: [String: BookmarksBarDevHost] = [:]

  private static func devView(_ windowId: String) -> BookmarksBarView? {
    if NativeWindowShell.nativeLayoutActive(windowId) { return NativeSplitChrome.bookmarksView(windowId) }
    return devHosts[windowId]?.value?.view
  }

  static func devLayout(windowId: String) -> [String: Any]? {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
    view.layoutSubtreeIfNeeded()
    return view.devLayout()
  }

  static func devLayoutJSON(windowId: String) -> String {
    guard let layout = devLayout(windowId: windowId), let data = try? JSONSerialization.data(withJSONObject: layout) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devMenuJSON(windowId: String, trigger: String, id: String?) -> String {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devMenu(trigger: trigger, id: id)) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devChooseJSON(windowId: String, trigger: String, id: String?, choiceId: String) -> String {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devChoose(trigger: trigger, id: id, choiceId: choiceId)) else { return #"{"accepted":false}"# }
    return String(decoding: data, as: UTF8.self)
  }

  static func devKeyJSON(windowId: String, key: String, id: String?, modifiers: Int, fullKeyboardAccess: Bool) -> String {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devKey(key: key, id: id, flags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)), fullKeyboardAccess: fullKeyboardAccess)) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devAccessibilityJSON(windowId: String) -> String {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devAccessibility()) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func devDropJSON(windowId: String, x: Double, folderId: String?, payload: String) -> String {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor,
      let data = try? JSONSerialization.data(withJSONObject: view.devDrop(x: CGFloat(x), folderId: folderId, payload: payload)) else { return #"{"accepted":false}"# }
    return String(decoding: data, as: UTF8.self)
  }

  static func devInput(windowId: String, action: String, id: String?, modifiers: Int, x: Double?) -> Bool {
    guard let view = devView(windowId), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
    view.layoutSubtreeIfNeeded()
    return view.devInput(action: action, id: id, flags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)), x: x.map { CGFloat($0) })
  }
}

@MainActor
private final class BookmarksBarDevHost {
  weak var value: BookmarksBarHost?

  init(_ value: BookmarksBarHost) { self.value = value }
}
#endif

@MainActor
extension NativeBookmarksBar {
  private static var scaleHosts: [String: BookmarkScaleHost] = [:]

  fileprivate static func registerScaleHost(_ host: BookmarksBarHost, windowId: String) {
    let environment = ProcessInfo.processInfo.environment
    guard !LaunchSwitches.shared.distribution, environment["AC_BENCH_BOOKMARKS"] == "1",
      environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false else { return }
    scaleHosts[windowId] = BookmarkScaleHost(host)
  }

  static func scaleJSON(windowId: String, operation: String, value: String?) -> String {
    guard let view = scaleHosts[windowId]?.value?.view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return "null" }
    var output: [String: Any]
    if operation == "menu" {
      output = view.benchmarkMenu(trigger: value ?? "overflow", id: nil)
    } else {
      if operation == "resize", let width = value.flatMap(Double.init) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
      }
      output = view.benchmarkLayout()
    }
    output["selectionSequence"] = scaleHosts[windowId]?.selectionSequence ?? 0
    output["selectedTabId"] = scaleHosts[windowId]?.selectedTabId as Any? ?? NSNull()
    guard let data = try? JSONSerialization.data(withJSONObject: output) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

@MainActor
private final class BookmarkScaleHost {
  weak var value: BookmarksBarHost?
  var selectionSequence = 0
  var selectedTabId: String?
  private var selectionObserver: NSObjectProtocol?

  init(_ value: BookmarksBarHost) {
    self.value = value
    selectionObserver = NotificationCenter.default.addObserver(forName: SidebarView.selectionShown, object: nil, queue: .main) { [weak self] note in
      nonisolated(unsafe) let sidebar = note.object as? SidebarView
      MainActor.assumeIsolated {
        guard let self, let sidebar, sidebar.windowId == self.value?.view.windowId,
          let window = NativeStoreHandle.store?.state.windows[sidebar.windowId] else { return }
        self.selectionSequence += 1
        self.selectedTabId = window.activeTabIds[window.profileId]
      }
    }
  }

  isolated deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
}
