import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum PanePrompts {
  struct Shown {
    let tabId: String
    let kind: PanePromptKind
    let key: String
    let json: String
  }

  nonisolated static let kind = "panePrompts"
  static let topic = "pane.prompts"
  private static var started = false
  private static var pages: [String: PanePromptPage] = [:]
  private static var windows: [String: [String: Any]] = [:]
  private static var browsers = PaneBrowsers()
  private static var windowOfTab: [String: String] = [:]
  private static var selectionShown: [String: PaneSelection] = [:]
  private static var selectionGenerations: [String: Int] = [:]
  private static var engineRemember: [String: (site: String, on: Bool)] = [:]
  private static var cliShown: [String: Bool] = [:]
  private static var cliRevealed: Set<String> = []
  private static var cliHideUntil: [String: TimeInterval] = [:]
  static let cliHideDelay: TimeInterval = 0.25
  private(set) static var activatedAt: TimeInterval = 0

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    TabPoolHost.shared.pageEventObservers.append { tabId, name, payload in pageEvent(tabId, name, payload) }
    TabPoolHost.shared.stateObservers.append { tabsMoved() }
    SolaraCoreEventTaps.observers.append { name, payload in coreEvent(name, payload) }
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { activatedAt = ProcessInfo.processInfo.systemUptime }
      }
    }
    _ = SettingsJS.shared.observe(topic) { value in applyWindows(value) }
    applyWindows(SettingsJS.shared.latestValue(topic))
  }

  static func owns(_ tabId: String) -> Bool { started && TabPoolHost.shared.pageView(tabId) != nil }

  private static func tabs(in windowId: String, where test: (PanePromptPage) -> Bool) -> [String] {
    pages.compactMap { tabId, page in test(page) && TabPoolHost.shared.windowOf(tabId) == windowId ? tabId : nil }
  }

  static func sadTabs(in windowId: String) -> [String] { tabs(in: windowId) { $0.sadMode != nil } }

  static func holds(_ windowId: String) -> Bool { !tabs(in: windowId) { $0.shown != PanePromptPage().shown }.isEmpty }

  static func draws(_ windowId: String) -> Bool {
    if holds(windowId) || selectionShown.keys.contains(where: { TabPoolHost.shared.windowOf($0) == windowId }) { return true }
    guard let window = windows[windowId] else { return false }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    if panes.values.contains(where: { $0["popups"] is [String: Any] || $0["engineOffer"] is [String: Any] }) { return true }
    return ((window["theme"] as? [String: Any])?["cli"] as? [String: Any])?["shown"] as? Bool == true || (cliHideUntil[windowId] ?? 0) > ProcessInfo.processInfo.systemUptime
  }

  private static func tabsMoved() {
    var moved: Set<String> = []
    for (tabId, was) in windowOfTab {
      let now = TabPoolHost.shared.windowOf(tabId)
      guard now != was else { continue }
      moved.insert(was)
      if let now {
        moved.insert(now)
        windowOfTab[tabId] = now
      } else {
        windowOfTab[tabId] = nil
      }
    }
    for windowId in moved { NativePaneOverlays.refresh(windowId) }
  }

  static func pageEvent(_ tabId: String, _ name: String, _ payload: [String: Any]) {
    if name == "onReady", let browserId = (payload["browserId"] as? NSNumber)?.intValue {
      for found in browsers.ready(tabId, browserId: browserId) { enqueue(found.tabId, found.request) }
      if let chooser = browsers.parkedChooser(browserId) {
        var page = pages[tabId] ?? PanePromptPage()
        if page.chooserEvent(chooser) { update(tabId, page) }
      }
    }
    if name == "onPageGone" {
      browsers.gone(tabId)
      let barShown = selectionShown.removeValue(forKey: tabId) != nil
      selectionGenerations[tabId] = nil
      engineRemember[tabId] = nil
      let gone = pages.removeValue(forKey: tabId)
      let windowId = windowOfTab.removeValue(forKey: tabId) ?? TabPoolHost.shared.windowOf(tabId)
      guard barShown || (gone.map { $0.shown != PanePromptPage().shown } ?? false) else { return }
      return NativePaneOverlays.refreshShowing(tabId, lastWindow: windowId)
    }
    var page = pages[tabId] ?? PanePromptPage()
    let shown = page.shown
    let selection = page.selection
    guard page.take(name, payload) else {
      if pages[tabId] != nil { pages[tabId] = page }
      return
    }
    pages[tabId] = page
    if page.selection != selection { selectionChanged(tabId, page.selection) }
    if page.shown != shown { changed(tabId) }
  }

  private static func selectionChanged(_ tabId: String, _ selection: PaneSelection?) {
    guard let selection else {
      if selectionShown.removeValue(forKey: tabId) != nil { changed(tabId) }
      return
    }
    let generation = (selectionGenerations[tabId] ?? 0) + 1
    selectionGenerations[tabId] = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + PanePromptSpecs.selectionDelay) {
      MainActor.assumeIsolated {
        guard generation == selectionGenerations[tabId], pages[tabId]?.selection == selection else { return }
        selectionShown[tabId] = selection
        changed(tabId)
      }
    }
  }

  static func selections(in windowId: String) -> [(tabId: String, state: SelectionBarState)] {
    guard let window = windows[windowId], let theme = window["theme"] as? [String: Any], let search = theme["search"] as? [String: Any], search["enabled"] as? Bool == true else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    let engine = search["engine"] as? String ?? ""
    return selectionShown.keys.sorted().compactMap { tabId in
      guard owns(tabId), TabPoolHost.shared.windowOf(tabId) == windowId, let selection = selectionShown[tabId] else { return nil }
      let zoom = (panes[tabId]?["zoom"] as? NSNumber)?.doubleValue ?? 1
      let state = PanePromptSpecs.selectionBar(selection, zoom: zoom, engine: engine, dark: theme["dark"] as? Bool ?? false, icon: theme["icon"] as? String ?? "", textPrimary: theme["textPrimary"] as? String ?? "")
      return (tabId, state)
    }
  }

  static func searchSelection(_ windowId: String, _ tabId: String, _ click: [String: Bool]) -> Bool {
    guard let selection = selectionShown[tabId] else { return false }
    selectionShown[tabId] = nil
    if var page = pages[tabId] {
      page.selection = nil
      pages[tabId] = page
    }
    changed(tabId)
    js("pane.searchSelection", windowId, tabId, selection.text, click)
    return true
  }

  static func coreEvent(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "permission":
      guard let request = PanePermissionRequest(payload) else { return }
      guard let tabId = browsers.route(request) else {
        _ = browsers.overflow()
        return
      }
      enqueue(tabId, request)
    case "permissionDismissed":
      guard let id = payload["id"] as? String else { return }
      browsers.dismissed(id)
      for tabId in Array(pages.keys) {
        guard var page = pages[tabId], page.dropPermission(id) else { continue }
        update(tabId, page)
      }
    case "deviceChooser":
      guard let chooser = PaneDeviceChooser(payload) else { return }
      guard let tabId = browsers.tab(chooser.browserId) else { return browsers.park(chooser) }
      var page = pages[tabId] ?? PanePromptPage()
      if page.chooserEvent(chooser) { update(tabId, page) }
    default: break
    }
  }

  private static func enqueue(_ tabId: String, _ request: PanePermissionRequest) {
    var page = pages[tabId] ?? PanePromptPage()
    page.enqueue(request)
    update(tabId, page)
  }

  static func chooserAction(_ tabId: String, _ event: DeviceChooserEvent) {
    guard var page = pages[tabId], let chooser = page.chooser else { return }
    let id = Int32(chooser.id)
    switch event {
    case .select(let index):
      page.chooserSelected = index
      update(tabId, page)
    case .choose(let index):
      guard let choice = chooser.choice(index, selected: page.chooserSelected), page.answerChooser() else { return }
      pages[tabId] = page
      SolaraCoreHost.deviceChooser(id, select: Int32(choice))
    case .cancel:
      guard page.answerChooser() else { return }
      pages[tabId] = page
      SolaraCoreHost.deviceChooser(id, action: "cancel")
    case .refresh: SolaraCoreHost.deviceChooser(id, action: "refresh")
    case .openSettings: SolaraCoreHost.deviceChooser(id, action: "settings")
    }
  }

  static func choosers(in windowId: String, paneWidth: (String) -> Double?) -> [(tabId: String, id: Int, json: String)] {
    guard let window = windows[windowId], let look = (window["theme"] as? [String: Any])?["prompt"] as? [String: Any] else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    return tabs(in: windowId, where: { $0.chooser != nil }).sorted().compactMap { tabId in
      guard owns(tabId), let page = pages[tabId], let chooser = page.chooser, panes[tabId]?["newTabShown"] as? Bool != true else { return nil }
      let left = PanePromptSpecs.promptLeft(urlLeft: urlLeft(tabId) ?? 0, paneWidth: paneWidth(tabId) ?? 0, width: PanePromptSpecs.deviceChooserWidth)
      let spec = PanePromptSpecs.deviceChooser(chooser, selected: page.chooserSelected, product: Bundle.main.productName, left: left)
      return encode(spec.merging(look) { _, theme in theme }).map { (tabId, chooser.id, $0) }
    }
  }

  static func sadTabAction(_ windowId: String, _ tabId: String, _ action: SadTabAction) {
    if var page = pages[tabId] {
      if action == .reload { page.crashed = false } else { page.unresponsive = false }
      pages[tabId] = page
      changed(tabId)
    }
    js("pane.sadTab", windowId, tabId, action.rawValue)
  }

  static func sadTab(_ windowId: String, _ tabId: String) -> SadTabState? {
    guard owns(tabId), let mode = pages[tabId]?.sadMode, let theme = windows[windowId]?["theme"] as? [String: Any] else { return nil }
    var object = theme
    object["mode"] = mode.rawValue
    return encode(object).flatMap(SadTabState.decode)
  }

  static func prompts(in windowId: String, paneWidth: (String) -> Double?) -> [Shown] {
    guard let window = windows[windowId], let look = (window["theme"] as? [String: Any])?["prompt"] as? [String: Any] else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    var shown: [Shown] = []
    let asking = Set(tabs(in: windowId, where: { $0.password != nil || $0.autofill != nil || $0.externalApp != nil || $0.permission != nil }))
    for tabId in asking.union(panes.compactMap { $0.value["popups"] is [String: Any] || $0.value["engineOffer"] is [String: Any] ? $0.key : nil }).sorted() where owns(tabId) {
      let page = pages[tabId] ?? PanePromptPage()
      let pane = panes[tabId] ?? [:]
      func add(_ kind: PanePromptKind, _ key: String, _ spec: [String: Any]) {
        if let json = encode(spec.merging(look) { _, theme in theme }) { shown.append(Shown(tabId: tabId, kind: kind, key: key, json: json)) }
      }
      if let prompt = page.password { add(.password, prompt.key, PanePromptSpecs.password(prompt, chosen: page.chosenUsername)) }
      if let prompt = page.autofill { add(.autofill, prompt.key, PanePromptSpecs.autofill(prompt)) }
      let newTabShown = pane["newTabShown"] as? Bool == true
      func left(_ width: Double) -> Double {
        PanePromptSpecs.promptLeft(urlLeft: (pane["urlLeft"] as? NSNumber)?.doubleValue ?? 0, paneWidth: paneWidth(tabId) ?? 0, width: width)
      }
      if let request = page.externalApp, !newTabShown {
        add(.externalApp, request.key, PanePromptSpecs.externalApp(request, always: page.alwaysOpen, left: left(PanePromptSpecs.externalAppWidth)))
      }
      if let request = page.permission, !newTabShown {
        add(.permission, request.key, PanePromptSpecs.permission(request, left: left(PanePromptSpecs.permissionWidth)))
      }
      if let hint = pane["popups"] as? [String: Any], let popups = PanePromptSpecs.popups(hint) { add(.popups, popups.key, popups.spec) }
      if let offer = pane["engineOffer"] as? [String: Any], let site = offer["site"] as? String, !newTabShown {
        let remember = engineRemember[tabId].map { $0.site == site && $0.on } ?? false
        let spec = PanePromptSpecs.engineOffer(host: offer["host"] as? String ?? site, canRemember: offer["canRemember"] as? Bool == true, remember: remember, product: Bundle.main.productName, left: left(PanePromptSpecs.externalAppWidth))
        add(.engineOffer, site, spec)
      }
    }
    return shown
  }

  static func urlLeft(_ tabId: String) -> Double? {
    guard let windowId = TabPoolHost.shared.windowOf(tabId), let panes = windows[windowId]?["panes"] as? [String: [String: Any]] else { return nil }
    return (panes[tabId]?["urlLeft"] as? NSNumber)?.doubleValue
  }

  static func promptEvent(_ windowId: String, _ tabId: String, _ kind: PanePromptKind, _ event: PromptEvent) {
    if kind == .engineOffer {
      let panes = windows[windowId]?["panes"] as? [String: [String: Any]]
      guard let site = (panes?[tabId]?["engineOffer"] as? [String: Any])?["site"] as? String else { return }
      switch event {
      case .toggle(let on):
        engineRemember[tabId] = (site, on)
        changed(tabId)
      case .button(let id): js("pane.engineOffer", windowId, tabId, id, engineRemember[tabId].map { $0.site == site && $0.on } ?? false)
      case .close: js("pane.engineOffer", windowId, tabId, "dismiss", false)
      default: break
      }
      return
    }
    if kind == .popups {
      switch event {
      case .button(let id): js("pane.popups", windowId, tabId, id, "")
      case .row(let id): js("pane.popups", windowId, tabId, "row", id)
      case .close: js("pane.popups", windowId, tabId, "dismiss", "")
      default: break
      }
      return
    }
    guard var page = pages[tabId] else { return }
    switch kind {
    case .password:
      guard let prompt = page.password else { return }
      if case .choice(let name) = event {
        page.chosenUsername = name
        return update(tabId, page)
      }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      let username = page.chosenUsername ?? prompt.username
      page.password = nil
      page.chosenUsername = nil
      update(tabId, page)
      js("pane.password", windowId, tabId, action, username, prompt.key)
    case .autofill:
      guard let prompt = page.autofill else { return }
      let action: String
      switch event {
      case .button(let id): action = id
      case .close: action = "dismiss"
      default: return
      }
      page.autofill = nil
      update(tabId, page)
      js("pane.autofill", windowId, tabId, prompt.id, action)
    case .externalApp:
      guard let request = page.externalApp else { return }
      if case .toggle(let on) = event {
        page.alwaysOpen = on
        return update(tabId, page)
      }
      let open: Bool
      switch event {
      case .button(let id): open = id == "open"
      case .close: open = false
      default: return
      }
      let remember = open && page.alwaysOpen
      page.externalApp = nil
      page.alwaysOpen = false
      update(tabId, page)
      js("pane.externalApp", windowId, tabId, request.id, open, remember)
    case .permission:
      guard let request = page.permission else { return }
      let result: String
      switch event {
      case .button(let id): result = id
      case .close: result = "dismiss"
      default: return
      }
      _ = page.dropPermission(request.id)
      update(tabId, page)
      js("pane.permission", windowId, tabId, request.id, result)
    case .popups, .engineOffer:
      return
    }
  }

  private static func js(_ name: String, _ args: Any...) {
    Task { @MainActor in
      do {
        _ = try await SettingsJS.shared.invoke(name, args)
      } catch {
        NSLog("[pane prompts] %@ failed: %@", name, String(describing: error))
      }
    }
  }

  private static func update(_ tabId: String, _ page: PanePromptPage) {
    pages[tabId] = page
    changed(tabId)
  }

  private static func encode(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func changed(_ tabId: String) {
    guard let windowId = TabPoolHost.shared.windowOf(tabId) else { return refreshAll() }
    windowOfTab[tabId] = windowId
    NativePaneOverlays.refresh(windowId)
  }

  private static func refreshAll() {
    for windowId in Set(windows.keys) { NativePaneOverlays.refresh(windowId) }
  }

  private static func applyWindows(_ value: Any?) {
    windows = ((value as? [String: Any])?["windows"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    for (windowId, window) in windows {
      let shown = ((window["theme"] as? [String: Any])?["cli"] as? [String: Any])?["shown"] as? Bool == true
      if shown == (cliShown[windowId] ?? false) { continue }
      cliShown[windowId] = shown
      if shown {
        cliRevealed.remove(windowId)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard cliShown[windowId] == true else { return }
            cliRevealed.insert(windowId)
            NativePaneOverlays.refresh(windowId)
          }
        }
      } else {
        cliRevealed.remove(windowId)
        cliHideUntil[windowId] = ProcessInfo.processInfo.systemUptime + cliHideDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + cliHideDelay + 0.01) {
          MainActor.assumeIsolated { NativePaneOverlays.refresh(windowId) }
        }
      }
    }
    for windowId in cliShown.keys where windows[windowId] == nil {
      cliShown[windowId] = nil
      cliRevealed.remove(windowId)
      cliHideUntil[windowId] = nil
    }
    refreshAll()
  }

  static func cliPills(in windowId: String) -> [(tabId: String, state: CliPillState)] {
    guard let window = windows[windowId], var cli = (window["theme"] as? [String: Any])?["cli"] as? [String: Any] else { return [] }
    let shown = cli["shown"] as? Bool == true
    guard shown || (cliHideUntil[windowId] ?? 0) > ProcessInfo.processInfo.systemUptime else { return [] }
    cli["shown"] = shown && cliRevealed.contains(windowId)
    guard let state = encode(cli).flatMap(CliPillState.decode) else { return [] }
    let panes = window["panes"] as? [String: [String: Any]] ?? [:]
    return panes.keys.sorted().compactMap { tabId in panes[tabId]?["cliPill"] as? Bool == true && owns(tabId) ? (tabId, state) : nil }
  }
}
