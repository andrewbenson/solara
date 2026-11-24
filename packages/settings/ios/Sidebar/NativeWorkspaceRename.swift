import AppKit
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeWorkspaceRename {
  private static var registry = WorkspaceRenameRegistry()
  private static var lifecycle: Int?
  private static var owner: ObjectIdentifier?

  static func start() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle { ownershipChanged() }
  }

  static func override(_ windowId: String) -> String?? {
    guard let store = WorkspaceActionRouter.ownedStore else { return nil }
    let value = registry.override(windowId, state: store.state)
    if value == .some(nil), registry.key(windowId) != nil { Task { @MainActor in pruneStale() } }
    return value
  }

  @discardableResult
  static func begin(windowId: String, kind: WorkspaceRenameKind, id: String) -> Bool {
    guard let store = WorkspaceActionRouter.ownedStore,
      let route = WorkspaceActionRouter.renameRoute(store.state, windowId: windowId, kind: kind, id: id) else { return false }
    pruneStale()
    switch route {
    case .tileSheet:
      guard let tab = store.state.tabs[id] else { return false }
      prompt("Rename Tab", value: tab.customTitle ?? tab.title, placeholder: tab.title.isEmpty ? "Tab name" : tab.title, windowId: windowId, store: store) { name in
        guard WorkspaceActionRouter.ownedStore === store, store.state.tabs[id] != nil else { return }
        _ = try? store.dispatch(Command("updateTab", [.string(id), ["customTitle": .string(name)]]), origin: .native)
        FrameUpdates.flush()
      }
      return true
    case .groupSheet:
      guard let group = store.state.groups[id] else { return false }
      prompt("Rename Group", value: group.name, placeholder: SidebarQuery(store.state).groupLabel(id), windowId: windowId, store: store) { name in
        guard WorkspaceActionRouter.ownedStore === store, store.state.groups[id] != nil else { return }
        _ = try? store.dispatch(Command("updateGroup", [.string(id), ["name": .string(name)]]), origin: .native)
        FrameUpdates.flush()
      }
      return true
    case .inline(let expand):
      for groupId in expand { _ = try? store.dispatch(Command("updateGroup", [.string(groupId), ["collapsed": false]]), origin: .native) }
      if !expand.isEmpty { FrameUpdates.flush() }
      publish(windowId, WorkspaceActionRouter.renameKey(kind, id))
      return true
    }
  }

  static func commit(windowId: String, kind: WorkspaceRenameKind, id: String, text: String) {
    if let store = WorkspaceActionRouter.ownedStore, let command = WorkspaceActionRouter.renameCommand(store.state, kind: kind, id: id, text: text) {
      _ = try? store.dispatch(command, origin: .native)
      FrameUpdates.flush()
    }
    end(windowId: windowId, id: id)
  }

  static func end(windowId: String, id: String) {
    guard let sequence = registry.end(windowId, id: id) else { return }
    notify(windowId, nil, sequence)
  }

  static func reset(windowId: String) {
    publish(windowId, nil)
  }

  static func windowGone(_ windowId: String) {
    guard registry.key(windowId) != nil else { return }
    publish(windowId, nil)
  }

  private static func ownershipChanged() {
    let current = WorkspaceActionRouter.ownedStore.map(ObjectIdentifier.init)
    guard current != owner else { return }
    owner = current
    var sequences: [String: Any] = [:]
    for windowId in registry.windowIds {
      sequences[windowId] = registry.set(windowId, nil)
      NativeSidebar.renameChanged(windowId)
      NativeLayoutChrome.renameChanged(windowId)
    }
    Task { @MainActor in
      _ = await SettingsAdapters.js("sidebar.action", "", "renameReset", "", ["windows": sequences])
    }
  }

  private static func pruneStale() {
    guard let store = WorkspaceActionRouter.ownedStore else { return }
    for windowId in registry.stale(store.state) { publish(windowId, nil) }
  }

  private static func publish(_ windowId: String, _ key: String?) {
    notify(windowId, key, registry.set(windowId, key))
  }

  private static func notify(_ windowId: String, _ key: String?, _ sequence: Int) {
    NativeSidebar.renameChanged(windowId)
    NativeLayoutChrome.renameChanged(windowId)
    let kind = key.flatMap(WorkspaceActionRouter.renameKind)
    let id = key.map(WorkspaceActionRouter.renameId) ?? ""
    Task { @MainActor in
      _ = await SettingsAdapters.js("sidebar.action", windowId, "renameState", id, ["kind": kind.map { $0.rawValue as Any } ?? NSNull(), "seq": sequence])
    }
  }

  static func prompt(
    _ title: String, value: String, placeholder: String, windowId: String, store: Store, apply: @escaping @MainActor (String) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "Update")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField.solaraPromptField(value: value, placeholder: placeholder)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NativeWorkspaceCommands.askGuarded(alert, windowId: windowId, setting: nil, store: store) {
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { apply(name) }
    }
  }
}
