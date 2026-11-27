import AppKit
import SolaraEngine
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
final class NativeBookmarkForms {
  private enum Intent {
    case page(String)
    case allTabs([JSONValue])
    case editor(id: String?, folder: Bool, parent: String?, index: Int?)

    var nodeId: String? {
      switch self {
      case .page(let id), .editor(let id?, _, _, _): id
      default: nil
      }
    }
  }

  private static var forms: [String: NativeBookmarkForms] = [:]
  private static var opening: [String: UUID] = [:]
  private let editing: NativeBookmarkEditing
  private let intent: Intent
  private let binding: BookmarkWriterBinding
  private let model = BookmarkFormModel()
  private let host: NSHostingView<BookmarkFormView>
  private var waiting = false
  private var catalogTask: Task<Void, Never>?
  private var storeListener: Int?
  private var lifecycle: Int?
  private var closeObserver: NSObjectProtocol?

  private init(editing: NativeBookmarkEditing, intent: Intent, binding: BookmarkWriterBinding) {
    self.editing = editing
    self.intent = intent
    self.binding = binding
    host = NSHostingView(rootView: BookmarkFormView(model: model))
    host.safeAreaRegions = []
  }

  static func edit(windowId: String, id: String?, folder: Bool = false, parent: String? = nil, index: Int? = nil, profile: String? = nil) {
    guard let editing = NativeBookmarkEditing(windowId: windowId), profile == nil || editing.profile == profile else { return }
    show(.editor(id: id, folder: folder, parent: parent, index: index), editing: editing)
  }

  static func bookmarkTabs(windowId: String) {
    guard let editing = NativeBookmarkEditing(windowId: windowId) else { return }
    let state = editing.store.state
    let drafts: [JSONValue] = state.viewTabIds(windowId).compactMap { id in
      guard let tab = state.tabs[id], ["http:", "https:", "file:"].contains(where: { tab.url.hasPrefix($0) }) else { return nil }
      return ["url": .string(tab.url), "title": .string(tab.customTitle ?? (tab.title.isEmpty ? tab.url : tab.title))]
    }
    if !drafts.isEmpty { show(.allTabs(drafts), editing: editing) }
  }

  static func bookmarkTab(windowId: String, tabId: String) {
    guard let editing = NativeBookmarkEditing(windowId: windowId),
      let tab = editing.store.state.tabs[tabId], tab.windowId == windowId, !tab.url.isEmpty else { return }
    if let view = editing.snapshot(), let existing = view.document["nodes"]?.object?.first(where: {
      $0.value["kind"] == "url" && $0.value["url"] == .string(tab.url)
    })?.key {
      show(.page(existing), editing: editing)
      return
    }
    guard opening[windowId] == nil else { return }
    let request = UUID()
    opening[windowId] = request
    let options: JSONValue = ["profileId": .string(editing.profile), "url": .string(tab.url),
      "title": .string(tab.customTitle ?? (tab.title.isEmpty ? tab.url : tab.title)), "favicon": tab.favicon.map(JSONValue.string) ?? .null]
    Task {
      defer { if opening[windowId] == request { opening[windowId] = nil } }
      do {
        let receipt = try await editing.write([.init(method: "addBookmark", args: [options])])
        guard opening[windowId] == request, editing.live, editing.store.state.tabs[tabId]?.windowId == windowId,
          let id = receipt.results.first?.string else { return }
        show(.page(id), editing: editing)
      } catch { editing.report(error) }
    }
  }

  #if DEBUG
  static func showEditor(windowId: String, id: String) -> String {
    guard let editing = NativeBookmarkEditing(windowId: windowId) else { return "target" }
    return show(.editor(id: id, folder: false, parent: nil, index: nil), editing: editing)
  }

  static func showExisting(windowId: String, id: String) -> String {
    guard let editing = NativeBookmarkEditing(windowId: windowId) else { return "target" }
    return show(.page(id), editing: editing)
  }
  #endif

  @discardableResult private static func show(_ intent: Intent, editing: NativeBookmarkEditing) -> String {
    guard let view = editing.snapshot() else { return "catalog" }
    guard let content = NativeWindowShell.overlay(editing.windowId) ?? WindowHost.contentView(editing.windowId),
      let window = content.window else { return "window" }
    let nodes = view.document["nodes"]?.object ?? [:]
    let bar = BookmarkFlat.roots(editing.target.engine).bar
    let node = intent.nodeId.flatMap { nodes[$0] }
    if intent.nodeId != nil, node?["parentId"]?.string == nil { return "node" }
    let form = NativeBookmarkForms(editing: editing, intent: intent, binding: view.binding)
    switch intent {
    case .page:
      guard node?["kind"] == "url" else { return "kind" }
      form.model.configure(kind: .page, name: node?["title"]?.string ?? "", folder: node?["parentId"]?.string)
    case .allTabs(let tabs):
      form.model.configure(kind: .allTabs, folder: bar, tabCount: tabs.count)
    case .editor(_, let folder, let parent, _):
      if let parent, nodes[parent]?["kind"] != "folder" { return "folder" }
      let kind: BookmarkFormModel.Kind = node.map { $0["kind"] == "folder" ? .renameFolder : .editBookmark }
        ?? (folder ? .newFolder : .addBookmark)
      form.model.configure(kind: kind, name: node?["title"]?.string ?? "", url: node?["url"]?.string ?? "",
        folder: node?["parentId"]?.string ?? parent ?? bar)
    }
    form.model.dark = ThemeScopeProjection.project(editing.store.state, windowId: editing.windowId).dark
    let sidebar = NativeWindowShell.host(editing.windowId)?.shell.input.addressBarInSidebar
      ?? (editing.store.state.settings.string("addressBar") == "sidebar"
        && (editing.store.state.windows[editing.windowId]?.tabLayout ?? editing.store.state.settings.string("tabLayout")) == "sidebar")
    form.model.placement = BookmarkFormModel.placement(addressInSidebar: sidebar)
    forms[editing.windowId]?.close()
    opening[editing.windowId] = nil
    forms[editing.windowId] = form
    form.mount(in: content, window: window)
    return "shown"
  }

  private func mount(in content: NSView, window: NSWindow) {
    let windowId = editing.windowId
    PageProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
    model.onEvent = { [weak self] event in self?.receive(event) }
    let catalog = NativeHistoryCatalog.catalog
    let engine = editing.target.engine
    model.apply(snapshot: catalog.bookmarks(engineProfile: engine))
    catalogTask = Task { [weak self] in
      for await snapshot in catalog.observeBookmarks(engineProfile: engine) {
        guard !Task.isCancelled, let self else { return }
        if !editing.live {
          close()
          return
        }
        if !waiting, let id = intent.nodeId, snapshot.ready, snapshot.nodes[id] == nil,
          editing.snapshot()?.document["nodes"]?[id] == nil {
          close()
          return
        }
        model.apply(snapshot: snapshot)
      }
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in
      if let self, !self.editing.live { self.close() }
    }
    storeListener = editing.store.subscribe { [weak self] commit in
      let changes = commit.changes
      guard ThemeScopeProjection.mayChange(changes) || !changes.windows.isEmpty
        || changes.settingsChanged.contains("defaultProfileId") else { return }
      Task { @MainActor in
        guard let self else { return }
        if !self.editing.live { self.close(); return }
        let dark = ThemeScopeProjection.project(self.editing.store.state, windowId: windowId).dark
        if self.model.dark != dark { self.model.dark = dark }
      }
    }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    content.addSubview(host, positioned: .above, relativeTo: nil)
    NativeWindowShell.host(windowId)?.shell.setModal("bookmarkForm", shown: true)
  }

  private func close() {
    guard Self.forms[editing.windowId] === self else { return }
    Self.forms[editing.windowId] = nil
    catalogTask?.cancel()
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    if let storeListener { editing.store.unsubscribe(storeListener) }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    host.removeFromSuperview()
    NativeWindowShell.host(editing.windowId)?.shell.setModal("bookmarkForm", shown: false)
  }

  private func receive(_ event: BookmarkFormEvent) {
    guard !waiting, editing.live else { return }
    if event == .cancel { close(); return }
    if case .newFolder(let parent) = event {
      promptForFolder(parent: parent)
      return
    }
    waiting = true
    Task {
      defer { waiting = false }
      do {
        try await save(event)
        close()
      } catch {
        editing.report(error, showToast: false)
        if !editing.live || intent.nodeId.map({ editing.snapshot()?.document["nodes"]?[$0] == nil }) == true { close() }
      }
    }
  }

  private func promptForFolder(parent: String?) {
    guard let window = host.window, window.attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = "New Folder"
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField.solaraPromptField(value: "", placeholder: "Folder name")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    waiting = true
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard response == .alertFirstButtonReturn, !title.isEmpty else { waiting = false; return }
      Task {
        defer { waiting = false }
        do {
          let (_, condition) = try destination(parent)
          let receipt = try await editing.write(condition + [makeFolder(title, parent: parent)], binding: binding)
          if Self.forms[editing.windowId] === self, editing.live, let id = receipt.results.last?.string { model.selectFolder(id) }
        } catch { editing.report(error, showToast: false) }
      }
    }
  }

  private func destination(_ parent: String?) throws -> (JSONObject, [BookmarkMutation]) {
    guard Self.forms[editing.windowId] === self, let view = editing.snapshot(), view.binding == binding else { throw BookmarkWriterError.staleBinding }
    let nodes = view.document["nodes"]?.object ?? [:]
    var expected: JSONObject = [:]
    if let id = intent.nodeId {
      guard let node = nodes[id] else { throw BookmarkWriterError.staleBinding }
      expected[id] = node
    }
    if let parent {
      guard let node = nodes[parent], node["kind"] == "folder" else { throw BookmarkWriterError.staleBinding }
      expected[parent] = node
    }
    let conditions: [BookmarkMutation] = expected.isEmpty ? [] : [.init(method: "expectBookmarkNodes", args: [.object(expected)])]
    return (nodes, conditions)
  }

  private func makeFolder(_ title: String, parent: String?, index: Int? = nil) -> BookmarkMutation {
    .init(method: "addBookmarkFolder", args: [["profileId": .string(editing.profile), "title": .string(title),
      "parentId": parent.map(JSONValue.string) ?? .null, "index": index.map { JSONValue($0) } ?? .null]])
  }

  private func save(_ event: BookmarkFormEvent) async throws {
    var mutations: [BookmarkMutation] = []
    switch (intent, event) {
    case (.page(let id), .done(let name, let parent)):
      let (nodes, conditions) = try destination(parent)
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      mutations = conditions
      if !title.isEmpty, nodes[id]?["title"] != .string(title) {
        mutations.append(.init(method: "updateBookmark", args: [.string(id), ["title": .string(title)]]))
      }
      if let parent, nodes[id]?["parentId"] != .string(parent) {
        mutations.append(.init(method: "moveBookmark", args: [.string(id), .string(parent)]))
      }
      if mutations == conditions { return }
    case (.page(let id), .remove):
      let (_, conditions) = try destination(nil)
      mutations = conditions + [.init(method: "removeBookmark", args: [.string(id)])]
    case (.allTabs(let tabs), .done(let name, let parent)):
      let (_, conditions) = try destination(parent)
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      mutations = conditions + [.init(method: "addBookmarkTree", args: [.string(editing.profile),
        [["title": .string(title.isEmpty ? "Tabs" : title), "children": .array(tabs)]], parent.map(JSONValue.string) ?? .null])]
    case (.editor(let id, let folder, _, let index), .save(let name, let input, let parent)):
      let (nodes, conditions) = try destination(parent)
      let isFolder = id.flatMap { nodes[$0]?["kind"]?.string }.map { $0 == "folder" } ?? folder
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = resolveInput(input, search: searchUrlPrefix(editing.store.state.settings))
      guard isFolder ? !title.isEmpty : !url.isEmpty else { return }
      mutations = conditions
      if let id {
        let patch: JSONValue = isFolder ? ["title": .string(title)] : ["title": .string(title), "url": .string(url)]
        mutations.append(.init(method: "updateBookmark", args: [.string(id), patch]))
        if let parent, nodes[id]?["parentId"] != .string(parent) {
          mutations.append(.init(method: "moveBookmark", args: [.string(id), .string(parent)]))
        }
      } else if isFolder {
        mutations.append(makeFolder(title, parent: parent, index: index))
      } else {
        mutations.append(.init(method: "addBookmark", args: [["profileId": .string(editing.profile), "url": .string(url),
          "title": .string(title.isEmpty ? url : title), "parentId": parent.map(JSONValue.string) ?? .null,
          "index": index.map { JSONValue($0) } ?? .null]]))
      }
    default: return
    }
    _ = try await editing.write(mutations, binding: binding)
  }

  static func probeRows() -> [[String: Any]] {
    forms.values.map { form in
      var row: [String: Any] = ["kind": "bookmarkForm", "name": form.model.name, "url": form.model.url, "folder": form.model.folderId as Any? ?? NSNull(),
        "valid": form.model.valid, "ax": NativePageView.axLines(form.host, depth: 0), "frames": NativePageView.probeFrames()]
      #if DEBUG
      row["windowId"] = form.editing.windowId
      row["profileId"] = form.editing.profile
      row["formKind"] = form.model.kind.rawValue
      row["bookmarkId"] = form.intent.nodeId as Any? ?? NSNull()
      if case .editor(_, _, _, let index) = form.intent { row["index"] = index }
      #endif
      return row
    }
  }
}
