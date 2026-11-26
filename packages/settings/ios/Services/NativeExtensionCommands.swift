import AppKit
import Foundation
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeExtensionCommands {
  static let site = ExtensionSiteContribution()
  private static var heldStates: [String: JSONObject] = [:]
  static func install() {
    NativeSiteControls.shared.extensions = site
    ShellMenus.extensionCatalog = {
      guard NativeExtensionCatalog.current, let state = NativeStoreHandle.store?.state else { return [] }
      guard let window = state.ui.focusedWindowId, state.windows[window] != nil else { return [] }
      return NativeExtensionCatalog.visible(window).map { row in
        ["id": row["id"]?.string ?? "", "title": row["name"]?.string ?? "", "icon": row["actionIcon"]?.truthy == true ? row["actionIcon"]!.foundation : row["icon"]?.foundation ?? NSNull()]
      }
    }
    for command in ["addExtension", "manageExtensions", "pinExtensions", "openExtension"] {
      NativeMenuCommands.argumentHandlers[command] = { arg, window in perform(command, arg: arg, windowId: window) }
    }
  }

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard ["addExtension", "manageExtensions", "pinExtensions", "openExtension"].contains(command),
      NativeExtensionCatalog.current, let store = NativeStoreHandle.store else { return false }
    let state = store.state
    let requested = windowId == "settings" || windowId == "import" ? nil : windowId
    let window = state.resolveWindowId(requested) ?? ""
    if window.isEmpty && command != "manageExtensions" { return true }
    run(["command": .string(command), "windowId": .string(window), "id": arg.map(JSONValue.string) ?? .null])
    return true
  }

  static var focusedProfile: String? {
    guard let state = NativeStoreHandle.store?.state else { return nil }
    return ExtensionPresentation.focusedProfile(in: state)
  }

  static func toolbar(_ input: JSONValue) -> JSONValue {
    guard let window = input["windowId"]?.string, let tab = input["tabId"]?.string else { return ["width": 0, "buttons": []] }
    let store = NativeExtensionCatalog.current ? NativeStoreHandle.store : nil
    let popup = NativeExtensionCatalog.popupId(window)
    if let host = input["host"]?.string {
      NativeExtensionCatalog.presentation.trackToolbar(host: host, window: window, tab: tab, store: store, popup: popup)
    }
    guard let store, store.state.tabs[tab]?.windowId == window else { return ["width": 0, "buttons": []] }
    let key = "\(NativeStoreHandle.ownershipGeneration)|\(input["host"]?.string ?? tab)"
    var states = heldStates[key] ?? [:]
    if let next = NativeExtensionCatalog.actionState(tab: tab) {
      for (id, value) in next { states[id] = value }
    }
    heldStates[key] = states
    return ExtensionToolbarProjection.make(rows: NativeExtensionCatalog.visible(window), states: states,
      popup: popup, limit: input["limit"]?.int ?? Int.max,
      routes: input["routes"]?.array?.compactMap(\.object) ?? [], webkit: store.pageEngine(tab, in: store.state) == "webkit",
      accent: input["accent"]?.string ?? "")
  }

  static func run(_ input: JSONValue, menu: ExtensionPresentation.WindowContext? = nil, completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
    var synchronous = true
    defer { if synchronous { completion?(nil) } }
    if input["command"]?.string == "releaseToolbar" {
      let host = input["id"]?.string ?? ""
      NativeExtensionCatalog.presentation.releaseToolbar(host: host)
      let suffix = "|\(host)"
      heldStates = heldStates.filter { !$0.key.hasSuffix(suffix) }
      return
    }
    guard NativeExtensionCatalog.current, let store = NativeStoreHandle.store else { return }
    let command = input["command"]?.string ?? ""
    let window = menu?.windowId ?? input["windowId"]?.string ?? ""
    let id = input["id"]?.string ?? ""
    guard menu?.matches(state: store.state) != false else { return }
    let profile = menu?.engineProfile ?? input["profile"]?.string ?? NativeExtensionCatalog.profile(window)
    let ext = NativeExtensionCatalog.catalog.lists[profile]?.first { $0["id"]?.string == id }
    switch command {
    case "addExtension": open("https://chromewebstore.google.com/category/extensions", window: window, store: store)
    case "manageExtensions":
      let own = store.state.windows[window]?.profileId
      let profile = own.map { Ids.isIncognitoProfile($0) ? Ids.incognitoOriginal($0) : $0 } ?? focusedProfile
      NativeSettingsWindow.navigate(pane: "extensions", profileId: profile, detail: nil)
      WindowHost.openAuxiliary(id: "settings", kind: "settings", title: "Settings")
    case "pinExtensions":
      guard let target = ExtensionPresentation.pinWindow(invoker: window, state: store.state, closing: store.memory.closingWindows) else { return }
      if target != window { ShellScripting.showWindow(target) }
      NativeExtensionSheets.showPins(target)
    case "options":
      if input["requiresVisible"] == true && !NativeExtensionCatalog.visible(window).contains(where: { $0["id"]?.string == id }) { return }
      if let url = ext?["optionsUrl"]?.string { open(url, window: window, store: store) }
    case "openExtension":
      let rect = input["anchor"].flatMap { value -> CGRect? in
        guard let x = value["x"]?.number, let y = value["y"]?.number,
          let width = value["width"]?.number, let height = value["height"]?.number,
          [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
      }
      NativeExtensionActionPopup.activate(windowId: window, extensionId: id, tabId: input["tabId"]?.string,
        anchor: rect, requiresActive: input["requiresActive"]?.truthy == true)
    case "menu":
      guard let ext else { return }
      let panel = NativeExtensionSidePanel.extensionId(windowId: window) == id
      choose(ExtensionToolbarProjection.menu(ext, panelOpen: panel), window: window) { choice, context in
        var next = input.object ?? [:]
        next["command"] = .string(choice == "pin" ? "setPinned" : choice == "enable" ? "setEnabled" : choice == "manage" ? "manageExtensions" : choice)
        if choice == "pin" { next["pinned"] = .bool(ext["pinned"]?.truthy != true) }
        if choice == "enable" { next["enabled"] = .bool(ext["enabled"]?.truthy != true) }
        run(.object(next), menu: context)
      }
    case "overflow":
      choose(ExtensionToolbarProjection.overflow(NativeExtensionCatalog.visible(window)), window: window) { choice, context in
        var next = input.object ?? [:]
        next["command"] = .string(choice == "pin" ? "pinExtensions" : choice == "manage" ? "manageExtensions" : choice == "add" ? "addExtension" : "openExtension")
        if choice.hasPrefix("open:") { next["id"] = .string(String(choice.dropFirst(5))) }
        run(.object(next), menu: context)
      }
    case "sidePanel":
      if profile == NativeExtensionCatalog.profile(window) { NativeExtensionSidePanel.toggle(window, id) }
    case "setPinned", "setEnabled", "configure":
      let options: JSONObject = command == "setPinned" ? ["pinned": input["pinned"] ?? false] : command == "setEnabled" ? ["enabled": input["enabled"] ?? false, "state": input["enabled"]?.truthy == true ? "ENABLED" : "DISABLED"] : input["options"]?.object ?? [:]
      if command != "configure" { NativeExtensionCatalog.catalog.patch(profile, id: id, values: options); NativeExtensionCatalog.publish() }
      let generation = NativeStoreHandle.ownershipGeneration
      synchronous = false
      Task { @MainActor in
        let error: String? = await EngineCalls.result({ done in
          if command == "setEnabled" { SolaraCoreServices.setExtension(id, enabled: input["enabled"]?.truthy == true, profile: profile) { done($0) } }
          else { SolaraCoreServices.configureExtension(id, profile: profile, options: JSONValue.object(options).foundation as? [String: Any] ?? [:]) { done($0) } }
        }) { ExtensionsAdapter.engineError($0) }
        guard NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation, NativeExtensionCatalog.current else { completion?(error); return }
        if command != "setPinned" || error != nil { _ = await NativeExtensionCatalog.refreshAndWait(profile, afterChange: false) }
        completion?(error)
      }
    case "remove":
      guard let ext else { return }
      let alert = NSAlert()
      alert.messageText = "Remove “\(ext["name"]?.string ?? "Extension")”?"
      alert.informativeText = ext["fromWebStore"]?.truthy == true ? "Its data and settings will be removed too." : "The extension's folder stays on your Mac."
      alert.addButton(withTitle: "Remove")
      alert.addButton(withTitle: "Cancel")
      alert.buttons.first?.hasDestructiveAction = true
      let generation = NativeStoreHandle.ownershipGeneration
      synchronous = false
      let accepted: (NSApplication.ModalResponse) -> Void = { response in
        let state = store.state
        guard response == .alertFirstButtonReturn, NativeExtensionCatalog.current, NativeStoreHandle.store === store,
          NativeStoreHandle.ownershipGeneration == generation, menu?.matches(state: state) != false,
          ExtensionPresentation.WindowContext.profileExists(state: state, engineProfile: profile) else { completion?(nil); return }
        uninstall(id, profile: profile) { result in
          let error = ExtensionsAdapter.engineError(result)
          Task { @MainActor in
            if NativeExtensionCatalog.current, NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation { _ = await NativeExtensionCatalog.refreshAndWait(profile, afterChange: false) }
            completion?(error)
          }
        }
      }
      if let host = ShellDrag.window(window) { alert.beginSheetModal(for: host, completionHandler: accepted) }
      else { accepted(alert.runModal()) }
    default: break
    }
  }

  static func uninstall(_ id: String, profile: String, completion: @escaping ([String: Any]) -> Void) {
    NativeExtensionActionPopup.extensionRemoved(id, profile: profile)
    NativeExtensionSidePanel.extensionRemoved(id, profile: profile)
    SolaraCoreServices.uninstallExtension(id, profile: profile) { completion($0) }
  }

  static func openWebStoreDetail(_ requestedURL: String, profile: String) {
    guard NativeExtensionCatalog.current, let store = NativeStoreHandle.store,
      let id = ExtensionWebStore.extensionId(requestedURL) else { return }
    let state = store.state
    guard let profileId = state.profileOrder.first(where: { state.profiles[$0] != nil && state.engineProfile($0) == profile }) else { return }
    let url = ExtensionWebStore.detailURL(id)
    if let window = state.ui.focusOrder.first(where: { state.windows[$0]?.incognito == false && NativeExtensionCatalog.profile($0) == profile }) {
      open(url, window: window, store: store)
    } else {
      let options: JSONObject = ["url": .string(url), "profileId": .string(profileId)]
      _ = try? store.dispatch(Command("createWindow", [.object(options)]), origin: .native)
    }
  }

  private static func open(_ url: String, window: String, store: Store) {
    guard store.state.windows[window] != nil else { return }
    _ = try? store.dispatch(Command("newTab", [.string(window), ["url": .string(url)]]), origin: .native)
  }

  static func showAddMenu(window: String, close: @escaping () -> Void) {
    choose([["id": "addExtension", "title": "Add Extension…", "symbol": "plus"],
      ["id": "pinExtensions", "title": "Pin Extensions…", "symbol": "pin"],
      ["id": "manageExtensions", "title": "Manage Extensions…", "symbol": "puzzlepiece.extension"]], window: window) { choice, context in
      close()
      run(["command": .string(choice), "windowId": .string(window)], menu: context)
    }
  }

  private static func choose(_ rows: [JSONObject], window: String, selected: @escaping (String, ExtensionPresentation.WindowContext) -> Void) {
    guard let store = NativeStoreHandle.store, let context = ExtensionPresentation.WindowContext(state: store.state, window: window) else { return }
    let generation = NativeStoreHandle.ownershipGeneration
    ShellMenus.choose(rows.map { JSONValue.object($0).foundation as? [String: Any] ?? [:] }) { choice in
      guard let choice, NativeExtensionCatalog.current, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == generation, context.matches(state: store.state) else { return }
      selected(choice, context)
    }
  }
}

@MainActor
final class ExtensionSiteContribution: NativeSiteControlsContribution {
  func rows(tabId: String, windowId: String) -> JSONValue {
    let extensions = NativeExtensionCatalog.visible(windowId).map { ext -> JSONValue in
      let name = ext["actionTitle"]?.truthy == true ? ext["actionTitle"]?.string ?? "" : ext["name"]?.string ?? ""
      return ["id": .string("ext:\(ext["id"]?.string ?? "")"), "name": .string(name + (ext["pinned"]?.truthy == true ? " (pinned)" : "")), "icon": ext["actionIcon"]?.truthy == true ? ext["actionIcon"]! : ext["icon"] ?? .null]
    }
    return [["kind": "section", "title": "Extensions"], ["kind": "extensions", "columns": 4, "extensions": .array(extensions + [["id": "ext:add", "name": "Add Extension", "icon": nil, "symbol": "plus"]])]]
  }

  func handle(_ event: SitePanelEvent, tabId: String, windowId: String, close: @escaping () -> Void) -> Bool {
    let id: String
    let menu: Bool
    var anchor: JSONValue = .null
    switch event {
    case .press(let value, let rect):
      id = value; menu = false
      anchor = ["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)]
    case .menu(let value, _): id = value; menu = true
    default: return false
    }
    guard id.hasPrefix("ext:") else { return false }
    if menu && id == "ext:add" {
      NativeExtensionCommands.showAddMenu(window: windowId, close: close)
      return true
    }
    if !menu { close() }
    NativeExtensionCommands.run(["windowId": .string(windowId), "tabId": .string(tabId), "id": .string(String(id.dropFirst(4))), "anchor": anchor,
      "command": .string(id == "ext:add" ? "addExtension" : menu ? "menu" : "openExtension")])
    return true
  }
}
