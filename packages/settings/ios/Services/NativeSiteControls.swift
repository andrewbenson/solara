import AppKit
import SolaraCore
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
protocol NativeSiteControlsContribution: AnyObject {
  func rows(tabId: String, windowId: String) -> JSONValue
  func handle(_ event: SitePanelEvent, tabId: String, windowId: String, close: @escaping () -> Void) -> Bool
}

@MainActor
final class NativeSiteControls {
  static let shared = NativeSiteControls()
  var extensions: NativeSiteControlsContribution? { didSet { refresh() } }
  var translate: NativeSiteControlsContribution? { didSet { refresh() } }
  private var menus: [WeakSiteMenu] = []
  private var started = false

  private init() {}

  func startWhenReady(tries: Int = 40) {
    guard !started else { return }
    guard let store = NativeStoreHandle.store, NativeSettingsHandle.model != nil else {
      guard tries > 0 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startWhenReady(tries: tries - 1) }
      return
    }
    started = true
    store.subscribe { _ in Task { @MainActor in NativeSiteControls.shared.refresh() } }
    refresh()
  }

  func register(_ menu: NativeSiteMenu) {
    menus.append(WeakSiteMenu(menu))
    startWhenReady()
  }

  func refresh() {
    menus.removeAll { $0.value == nil }
    for menu in menus { menu.value?.refresh() }
  }

  nonisolated static func json(_ raw: Any?) -> JSONValue {
    guard let raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
      let value = try? JSONValue.parse(data) else { return .null }
    return value
  }
}

@MainActor
private final class WeakSiteMenu {
  weak var value: NativeSiteMenu?
  init(_ value: NativeSiteMenu) { self.value = value }
}

@MainActor
final class NativeSiteMenu {
  let body = SitePanelView(frame: .zero)
  let popover: PopoverView
  var onDismiss: (() -> Void)?
  var onClosed: (() -> Void)?
  var onContribution: ((SitePanelEvent) -> Void)?
  private var input: JSONValue
  private var context: JSONValue = [:]
  private var session = SiteControlsSession()
  private var settings: JSONValue?
  private var displayed: SitePanelState?
  private var blocker: JSONValue?
  private var expanded: String?
  private var cleared: String?
  private var closed = false

  init(input: JSONValue) {
    self.input = input
    popover = PopoverView(body: body)
    popover.autoresizingMask = [.width, .height]
    body.favicons = NewTabNetwork.favicons
    body.onHeight = { [weak self] height in self?.popover.set(bodyHeight: height) }
    body.onEvent = { [weak self] event in self?.handle(event) }
    popover.onDismiss = { [weak self] in self?.dismiss() }
    popover.onClosed = { [weak self] in self?.onClosed?() }
    NativeSiteControls.shared.register(self)
  }

  func update(_ next: JSONValue) {
    guard !closed else { return }
    input = next
    refresh()
  }

  func close() {
    guard !closed else { return }
    closed = true
    session.invalidate()
    popover.close()
  }

  func dismiss() {
    close()
    onDismiss?()
  }

  func refresh() {
    guard !closed, let store = NativeStoreHandle.store, let tabId = input["tabId"]?.string,
      var c = SiteControlsLogic.context(state: store.state, tabId: tabId, pageEngine: store.pageEngine(tabId, in: store.state), input: input)?.object
    else { return }
    let windowId = c["windowId"]?.string ?? ""
    if let provider = NativeSiteControls.shared.extensions { c["extensions"] = provider.rows(tabId: tabId, windowId: windowId) }
    if let provider = NativeSiteControls.shared.translate { c["translate"] = provider.rows(tabId: tabId, windowId: windowId) }
    let next = JSONValue.object(c)
    guard next != context else { return }
    context = next
    let placement = PopoverPlacement(width: 288, top: input["top"]?.number ?? 8, right: input["right"]?.number, left: input["left"]?.number, fitHeight: true)
    popover.set(placement: placement, dark: input["dark"]?.bool == true)
    render()
    if let token = session.beginRefresh(context: context) {
      let captured = context
      Task { [weak self] in await self?.readPermissions(captured, token: token) }
      Task { [weak self] in await self?.readBlocker(captured, token: token) }
      Task { [weak self] in
        guard let self else { return }
        let info = await self.page("getSecurityInfo")
        guard self.session.accepts(token: token), !info.isNull else { return }
        let raw = info.text().data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        _ = await SettingsAdapters.js("site.security", tabId, raw)
      }
    }
  }

  private func render() {
    guard let state = SiteControlsLogic.state(context: context, expanded: expanded, featured: session.featured, settings: settings, blocker: blocker, cleared: cleared), state != displayed else { return }
    displayed = state
    body.update(state)
  }

  private func readPermissions(_ c: JSONValue, token: Int) async {
    guard let origin = SiteControlsLogic.origin(c["url"]?.string ?? "") else { return }
    let profile = c["profile"]?.string ?? ""
    let result: JSONValue
    if c["pageEngine"] == "webkit" {
      result = NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitSettings(profile: profile, origin: origin))
    } else {
      result = await EngineCalls.result({ done in SolaraCoreServices.siteSettings(profile: profile, origin: origin, completion: done) }, NativeSiteControls.json)
    }
    guard session.receivePermissions(context: context, settings: result, token: token) else { return }
    settings = result
    render()
  }

  private func readBlocker(_ c: JSONValue, token: Int) async {
    let host = SiteControlsLogic.host(c["url"]?.string ?? "")
    let state = await EngineCalls.result({ done in SolaraCoreContentBlocker.state(done) }, NativeSiteControls.json)
    let allowed = await EngineCalls.result({ done in SolaraCoreContentBlocker.isAllowed(host: host) { done(["allowed": $0]) } }, { $0["allowed"] as? Bool == true })
    let result: JSONValue = ["enabled": .bool(state["enabled"]?.bool == true), "allowed": .bool(allowed)]
    guard session.accepts(token: token) else { return }
    blocker = result
    render()
  }

  private func page(_ method: String, _ args: [Any] = []) async -> JSONValue {
    let tabId = context["tabId"]?.string ?? ""
    if let view = TabPoolHost.shared.pageView(tabId) {
      return await withCheckedContinuation { continuation in
        PageCalls.run(view, method, args, resolve: { continuation.resume(returning: NativeSiteControls.json($0)) }, reject: { _, _ in continuation.resume(returning: .null) })
      }
    }
    return NativeSiteControls.json(await SettingsAdapters.js("site.page", tabId, method, args))
  }

  private func shared(_ action: String, _ args: [String: Any] = [:], captured: JSONValue? = nil) async {
    let c = captured ?? context
    let snapshot: [String: Any] = [
      "url": c["url"]?.string ?? "", "title": c["title"]?.string ?? "", "customTitle": c["customTitle"]?.string as Any? ?? NSNull(),
      "windowId": c["windowId"]?.string ?? "",
    ]
    _ = await SettingsAdapters.js("site.action", c["tabId"]?.string ?? "", action, args, snapshot)
  }

  private func handle(_ event: SitePanelEvent) {
    guard !closed else { return }
    let id: String
    switch event {
    case .press(let value, _), .menu(let value, _), .toggle(let value, _), .zoom(let value, _): id = value
    }
    let tabId = context["tabId"]?.string ?? ""
    let windowId = context["windowId"]?.string ?? ""
    switch SiteControlsLogic.action(event, context: context) {
    case .contribution:
      let provider = id.hasPrefix("ext:") ? NativeSiteControls.shared.extensions : NativeSiteControls.shared.translate
      if provider?.handle(event, tabId: tabId, windowId: windowId, close: { [weak self] in self?.dismiss() }) != true { onContribution?(event) }
    case .zoom(let step):
      Task { _ = await page("zoomStep", [step]) }
    case .fullURL(let on):
      NativeSettingsHandle.model?.update(["showFullUrl": .bool(on)])
    case .expand(let section):
      expanded = expanded == section ? nil : section
      render()
    case .developer(let changed):
      NativeSettingsHandle.model?.update(["developerMode": changed])
    case .blocker: Task { await toggleBlocker() }
    case .enginePicker: pickEngine()
    case .clear: Task { await clearData() }
    case .permission(let type): pickPermission(type)
    case .shared(let action):
      guard case .press(_, let rect) = event else { return }
      let captured = context
      let clickAt = NSApp.currentEvent.map { $0.type == .leftMouseUp ? $0.timestamp * 1000 : 0 } ?? 0
      dismiss()
      Task { await shared(action, ["rect": [rect.minX, rect.minY, rect.width, rect.height], "clickAt": clickAt], captured: captured) }
    case .none: break
    }
  }

  private func pickPermission(_ type: String) {
    let captured = context
    let choices = SiteControlsLogic.permissionChoices(type).map { ($0, SiteControlsLogic.choiceTitle(type, $0), settings?[type]?["value"]?.string == $0) }
    guard let choice = SiteMenuChoice.pick(choices) else { return }
    Task {
      guard let origin = SiteControlsLogic.origin(captured["url"]?.string ?? "") else { return }
      let profile = captured["profile"]?.string ?? ""
      if captured["pageEngine"] == "webkit" {
        SolaraCoreSiteControlsBridge.setWebKitPermission(profile: profile, origin: origin, kind: type, value: choice)
      } else {
        SolaraCoreServices.setSiteSetting(choice, profile: profile, origin: origin, type: type)
      }
      let refreshed: JSONValue
      if captured["pageEngine"] == "webkit" {
        refreshed = NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitSettings(profile: profile, origin: origin))
      } else {
        refreshed = await EngineCalls.result({ done in SolaraCoreServices.siteSettings(profile: profile, origin: origin, completion: done) }, NativeSiteControls.json)
      }
      settings = refreshed
      render()
      if type == "sound", let store = NativeStoreHandle.store {
        _ = try? store.dispatch(Command("updateTab", [.string(captured["tabId"]?.string ?? ""), ["muted": .bool(choice == "block")]]), origin: .native)
        _ = await page("setMuted", [choice == "block"])
      }
    }
  }

  private func pickEngine() {
    let captured = context
    let choices = SiteControlsLogic.engineChoices(context: captured)
    guard let choice = SiteMenuChoice.pick(choices.map { ($0.id, $0.title, $0.checked) }, separatorAfterFirst: captured["privatePage"]?.bool != true) else { return }
    let engine = choice == "default" ? captured["recommendedEngine"]?.string ?? "chromium" : choice
    dismiss()
    Task { await shared("engine", ["engine": engine, "rule": choice == "default" ? NSNull() : choice as Any], captured: captured) }
  }

  private func toggleBlocker() async {
    guard context["pageEngine"] != "webkit", let blocker else { return }
    if blocker["enabled"]?.bool != true {
      let captured = context
      dismiss()
      await shared("privacy", captured: captured)
      return
    }
    let captured = context
    let host = SiteControlsLogic.host(captured["url"]?.string ?? "")
    let error: String? = await withCheckedContinuation { continuation in
      SolaraCoreContentBlocker.setAllowed(blocker["allowed"]?.bool != true, host: host) { continuation.resume(returning: $0) }
    }
    let allowed: Bool = await withCheckedContinuation { continuation in
      SolaraCoreContentBlocker.isAllowed(host: host) { continuation.resume(returning: $0) }
    }
    self.blocker = ["enabled": blocker["enabled"] ?? false, "allowed": .bool(allowed)]
    render()
    if error != nil {
      await shared("toast", ["title": "Couldn't Change the Ad Blocker", "detail": "Blocking on \(host) is as it was. Try again.", "icon": "exclamationmark.triangle"], captured: captured)
    } else { _ = await page("reload") }
  }

  private func clearData() async {
    let captured = context
    guard SiteControlsLogic.origin(captured["url"]?.string ?? "") != nil else { return }
    let alert = NSAlert()
    alert.messageText = "Clear cookies and site data for \(SiteControlsLogic.host(captured["url"]?.string ?? ""))?"
    alert.informativeText = "You'll be signed out of this site, and its offline data will be deleted."
    alert.addButton(withTitle: "Clear").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    let confirmed: Bool = await withCheckedContinuation { continuation in
      if let window = ShellDrag.window(captured["windowId"]?.string ?? ""), window.isVisible {
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
      } else { continuation.resume(returning: false) }
    }
    guard confirmed else { return }
    let result = await page("clearSiteData")
    let n = result["cookies"]?.int ?? 0
    cleared = n == 0 ? "Cleared site data" : "Cleared \(n) cookie\(n == 1 ? "" : "s") and site data"
    render()
    _ = await page("reload")
  }
}

@MainActor
private final class SiteMenuChoice: NSObject {
  var selected: String?

  @objc func choose(_ sender: NSMenuItem) { selected = sender.representedObject as? String }

  static func pick(_ choices: [(String, String, Bool)], separatorAfterFirst: Bool = false) -> String? {
    let target = SiteMenuChoice()
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (index, choice) in choices.enumerated() {
      if separatorAfterFirst, index == 1 { menu.addItem(.separator()) }
      let item = NSMenuItem(title: choice.1, action: #selector(choose(_:)), keyEquivalent: "")
      item.target = target
      item.representedObject = choice.0
      item.state = choice.2 ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    return target.selected
  }
}
