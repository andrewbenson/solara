import AppKit
import Foundation
import SolaraCore
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeExtensionSheets {
  private static var lifecycle: Int?
  private static var store: Store?
  private static var subscription: Int?
  private static var lifetime = ExtensionInstallLifetime()
  private static var prompt: [String: Any]?
  private static var pinWindow: String?
  private static var rendered: [String: String] = [:]

  static func install() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle {
      let next = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
      guard store !== next else { return }
      if let subscription { store?.unsubscribe(subscription) }
      store = next
      subscription = next?.subscribe { _ in
        DispatchQueue.main.async { if lifetime.pending != nil || pinWindow != nil { reconcile() } }
      }
      if let receipt = lifetime.pending { _ = finish(receipt.id, accepted: false) }
      pinWindow = nil
      render()
    }
    SolaraCoreHost.extensionsEventHandler = { name, payload in
      MainActor.assumeIsolated {
        if name == "installPrompt" { receive(payload) }
        else if name == "requesterInvalidated", let id = payload["requestId"] as? String {
          _ = finish(id, accepted: false)
        }
      }
    }
    _ = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraWebStoreRemoveExtension"), object: nil, queue: .main) { note in
      guard let tabId = note.userInfo?["tabId"] as? String, let id = note.userInfo?["id"] as? String else { return }
      MainActor.assumeIsolated {
        guard let tab = store?.state.tabs[tabId], ExtensionWebStore.extensionId(id) == id else { return }
        NativeExtensionCommands.run(["command": "remove", "windowId": .string(tab.windowId), "id": .string(id)])
      }
    }
  }

  private static func receive(_ payload: [String: Any]) {
    guard let id = payload["requestId"] as? String else { return }
    guard let state = store?.state, !SolaraCoreHost.safeMode else {
      SolaraCoreHost.resolveExtensionInstallPrompt(id, accepted: false)
      return
    }
    let browserId = payload["browserId"] as? Int
    let originalProfile = payload["profile"] as? String ?? ""
    let privateProfile = payload["privateProfile"] as? String
    let popup = NativeExtensionActionPopup.current
    let requester: ExtensionInstallLifetime.Requester?
    let window: String?
    if let popup, matchesPopup(popup, browserId: browserId, payload: payload, state: state) {
      requester = .popup(popup.installRequesterId)
      window = popup.intent.windowId
    } else if let browserId, let nativeId = Int32(exactly: browserId), nativeId > 0 {
      guard SolaraCoreHost.isExtensionInstallTabLive(nativeId) else {
        SolaraCoreHost.resolveExtensionInstallPrompt(id, accepted: false)
        return
      }
      if let tabId = SolaraCoreHost.extensionInstallTabId(nativeId), let tab = state.tabs[tabId] {
        requester = .page(tabId: tabId, browserId: browserId, url: tab.url, navigation: tab.navigation?.seq)
        window = tab.windowId
      } else {
        requester = .browser(nativeId)
        window = host(state, payload, originalProfile: originalProfile, privateProfile: privateProfile)
      }
    } else if payload["type"] as? String == "permissions" {
      requester = nil
      window = browserId == nil ? state.ui.focusedWindowId ?? state.windowOrder.first : nil
    } else {
      requester = nil
      window = host(state, payload, originalProfile: originalProfile, privateProfile: privateProfile)
    }
    guard let window, state.windows[window] != nil else {
      SolaraCoreHost.resolveExtensionInstallPrompt(id, accepted: false)
      return
    }
    let replaced = lifetime.begin(.init(id: id, windowId: window, requester: requester))
    guard lifetime.pending?.id == id else { return }
    prompt = payload
    if let replaced { SolaraCoreHost.resolveExtensionInstallPrompt(replaced.id, accepted: false) }
    render()
  }

  private static func matchesPopup(_ popup: ExtensionActionPopupHost, browserId: Int?, payload: [String: Any], state: BrowserState) -> Bool {
    if let browserId {
      return ExtensionInstallLifetime.matchesPopup(requesterBrowserId: browserId, popupBrowserId: popup.browserId)
    }
    guard payload["type"] as? String == "permissions", let window = state.windows[popup.intent.windowId],
      state.engineProfile(window.profileId) == popup.intent.profile,
      payload["offTheRecord"] as? Bool != true || window.incognito else { return false }
    return ExtensionInstallLifetime.matchesPermissionPopup(extensionId: payload["id"] as? String,
      originalProfile: payload["profile"] as? String, privateProfile: payload["privateProfile"] as? String,
      popupExtensionId: popup.intent.extensionId, popupOriginalProfile: state.privateSession(window.profileId) ?? popup.intent.profile,
      popupPrivateProfile: window.incognito ? popup.intent.profile : nil)
  }

  private static func host(_ state: BrowserState, _ payload: [String: Any], originalProfile: String, privateProfile: String?) -> String? {
    guard payload["offTheRecord"] as? Bool != true || privateProfile != nil else { return nil }
    return ExtensionInstallLifetime.host(in: state, originalProfile: originalProfile, privateProfile: privateProfile)
  }

  static func reconcile() {
    if let receipt = lifetime.pending, let state = store?.state {
      let current: ExtensionInstallLifetime.Requester?
      switch receipt.requester {
      case .page(let id, let browserId, _, _):
        if let tab = state.tabs[id], tab.windowId == receipt.windowId,
          Int32(exactly: browserId).flatMap({ SolaraCoreHost.extensionInstallTabId($0) }) == id {
          current = .page(tabId: id, browserId: browserId, url: tab.url, navigation: tab.navigation?.seq)
        } else { current = nil }
      case .popup:
        current = NativeExtensionActionPopup.current.map { .popup($0.installRequesterId) }
      case .browser(let browserId):
        current = SolaraCoreHost.isExtensionInstallTabLive(browserId) ? .browser(browserId) : nil
      case nil: current = nil
      }
      if let cancelled = lifetime.reconcile(windowExists: state.windows[receipt.windowId] != nil, requester: current) {
        prompt = nil
        SolaraCoreHost.resolveExtensionInstallPrompt(cancelled.id, accepted: false)
      }
    }
    if let pinWindow, store?.state.windows[pinWindow] == nil { self.pinWindow = nil }
    render()
  }

  @discardableResult
  static func finish(_ id: String, accepted: Bool) -> Bool {
    if accepted { reconcile() }
    guard lifetime.answer(id) != nil else { return false }
    let profile = prompt?["profile"] as? String ?? ""
    prompt = nil
    SolaraCoreHost.resolveExtensionInstallPrompt(id, accepted: accepted)
    render()
    if accepted {
      let generation = NativeStoreHandle.ownershipGeneration
      for delay in [1.5, 5.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          guard NativeStoreHandle.ownershipGeneration == generation else { return }
          NativeExtensionCatalog.refresh(profile)
        }
      }
    }
    return true
  }

  static func showPins(_ window: String) {
    pinWindow = window
    render()
  }

  private static func render() {
    let receipt = lifetime.pending
    guard receipt != nil || pinWindow != nil || !rendered.isEmpty else { return }
    let state = store?.state
    let desired = Set([receipt?.windowId, pinWindow].compactMap { $0 }.filter { state?.windows[$0] != nil })
    for window in Array(rendered.keys) where !desired.contains(window) {
      NativeSheets.set(window, nil)
      rendered[window] = nil
    }
    guard let state else { return }
    for id in desired {
      guard let window = state.windows[id] else { continue }
      let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
      let dark = look.dark
      var theme = look.tokens
      let style = WindowSheetState.Style(dark: dark, panel: theme["panel"] ?? "", panelBorder: theme["panelBorder"] ?? "",
        panelShadowOpacity: look.panel.shadowOpacity)
      let go = dark ? "#DCCBD8" : "#0F182C"
      let goText = dark ? "#1A1418" : "#FFFFFF"
      let sheet: WindowSheetState
      if let receipt, receipt.windowId == id, let prompt {
        let name = prompt["name"] as? String ?? "Extension"
        let kind = prompt["type"] as? String
        let title = kind == "re-enable" ? "Turn “\(name)” back on?" : kind == "permissions" ? "“\(name)” needs new permissions" : "Add “\(name)”?"
        let action = kind == "re-enable" ? "Turn On" : kind == "permissions" ? "Allow" : "Add Extension"
        let body = ExtensionInstallState(status: "ready", title: title, error: nil, icon: prompt["icon"] as? String,
          warnings: prompt["permissions"] as? [String] ?? [], loadedFrom: nil, action: action, dark: dark, theme: theme,
          goButton: go, goButtonText: goText)
        sheet = WindowSheetState(kind: "install", key: receipt.id, title: title, busy: false, style: style, install: body, pins: nil)
      } else {
        let pins = NativeExtensionCatalog.visible(id).compactMap { row -> ExtensionPin? in
          guard let id = row["id"]?.string, let name = row["name"]?.string else { return nil }
          let icon = row["actionIcon"]?.truthy == true ? row["actionIcon"]?.string : row["icon"]?.string
          return ExtensionPin(id: id, name: name, icon: icon, pinned: row["pinned"]?.truthy == true)
        }
        theme["accent"] = dark ? "#4A77D4" : "#6395FC"
        let body = ExtensionPinsState(extensions: pins, dark: dark, theme: theme,
          control: dark ? "rgba(255,255,255,0.1)" : "#FFFFFF",
          controlBorder: dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.14)", goButton: go, goButtonText: goText)
        sheet = WindowSheetState(kind: "pins", key: "pins", title: "Pin Extensions", busy: false, style: style, install: nil, pins: body)
      }
      rendered[id] = sheet.key
      NativeSheets.present(id, sheet) { name, key, payload in event(window: id, name: name, key: key, payload: payload) }
    }
  }

  private static func event(window: String, name: String, key: String, payload: [String: Any]) {
    guard rendered[window] == key else { return }
    if name == "closed" {
      let generation = NativeStoreHandle.ownershipGeneration
      DispatchQueue.main.async {
        guard rendered[window] == nil, NativeStoreHandle.ownershipGeneration == generation,
          let state = store?.state, let tab = state.peeks[window]?.tabId ?? state.activeTabId(window) else { return }
        _ = SidePanelFocus.focus(windowId: window, tabId: tab)
      }
    } else if key == lifetime.pending?.id {
      if ["confirm", "submit", "cancel", "dismiss"].contains(name) {
        _ = finish(key, accepted: name == "confirm" || name == "submit")
      }
    } else if key == "pins", pinWindow == window {
      if name == "toggle", let id = payload["id"] as? String, let value = payload["pinned"] as? Bool {
        NativeExtensionCommands.run(["command": "setPinned", "windowId": .string(window), "id": .string(id), "pinned": .bool(value)])
      } else if ["done", "dismiss", "submit"].contains(name) {
        pinWindow = nil
        render()
      }
    }
  }

  #if DEBUG || SOLARA_PROBES
  static func dev(_ action: String, _ id: String?, _ window: String?) -> [String: Any]? {
    switch action {
    case "accept", "cancel":
      if let key = id ?? lifetime.pending?.id { return ["answered": finish(key, accepted: action == "accept")] }
      return ["answered": false]
    case "dismissPins":
      if pinWindow == window { pinWindow = nil; render() }
      return nil
    default: return prompt
    }
  }
  #endif
}
