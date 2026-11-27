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
  private var parked: [ObjectIdentifier: NativeSiteMenu] = [:]
  private var started = false
  private var blockerObserver: NSObjectProtocol?
  private var mediaListener: UUID?
  private weak var observedStore: Store?
  private var storeObserver: Int?

  private init() {}

  func startWhenReady(tries: Int = 40) {
    guard !started else { return }
    guard NativeStoreHandle.store != nil, NativeSettingsHandle.model != nil else {
      guard tries > 0 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startWhenReady(tries: tries - 1) }
      return
    }
    started = true
    mediaListener = NativeMediaStack.listen { [weak self] in self?.refresh() }
    blockerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraWebKitContentBlockerApplied"), object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refreshBlockerStatus() }
    }
    _ = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.observeStore() }
    PageIssuer.lifecycleObservers.append { [weak self] _, _, name, _ in
      guard ["onPagePhysicalReplaced", "onDocumentCommitted", "onReady", "onDiscarded", "onCrashed"].contains(name) else { return }
      DispatchQueue.main.async { self?.refresh() }
    }
    PageRegistry.shared.observe { [weak self] _ in
      DispatchQueue.main.async { self?.refresh() }
    }
    observeStore()
  }

  private func observeStore() {
    let store = NativeStoreHandle.ownsWorkspace && !NativeStoreHandle.frozen ? NativeStoreHandle.store : nil
    if store !== observedStore {
      if let storeObserver { observedStore?.unsubscribe(storeObserver) }
      observedStore = store
      storeObserver = store?.subscribe { _ in Task { @MainActor in NativeSiteControls.shared.refresh() } }
    }
    refresh()
  }

  func register(_ menu: NativeSiteMenu) {
    menus.append(WeakSiteMenu(menu))
    startWhenReady()
  }

  func reusableMenu(tabId: String, window: NSWindow) -> NativeSiteMenu? {
    guard let menu = menus.reversed().lazy.compactMap(\.value).first(where: { $0.canRehost(tabId: tabId, window: window) }) else { return nil }
    parked[ObjectIdentifier(menu)] = nil
    return menu
  }

  func park(_ menu: NativeSiteMenu, anchor: NSView, window: NSWindow) -> Bool {
    guard let tabId = menu.tabId, let root = window.contentView, menu.canRehost(tabId: tabId, window: window) else { return false }
    let id = ObjectIdentifier(menu)
    let frame = anchor.convert(anchor.bounds, to: root)
    let popover = menu.popover
    parked[id] = menu
    menu.onClosed = { [weak self, weak popover] in
      popover?.removeFromSuperview()
      self?.parked[id] = nil
    }
    popover.autoresizingMask = []
    root.addSubview(popover, positioned: .above, relativeTo: nil)
    popover.frame = frame
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak menu] in
      guard let self, let menu, self.parked[id] === menu else { return }
      menu.dismiss()
    }
    return true
  }

  private func refreshBlockerStatus() {
    menus.removeAll { $0.value == nil }
    for menu in menus { menu.value?.refreshBlockerStatus() }
  }

  func refresh() {
    menus.removeAll { $0.value == nil }
    for menu in menus { menu.value?.refresh() }
  }

  #if DEBUG
  func describe(windowId: String) -> String {
    let cards = menus.compactMap { $0.value?.describe(windowId: windowId) }
    guard let data = try? JSONSerialization.data(withJSONObject: cards) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
  #endif

  static func toggleDeveloperMode(windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen, let store = NativeStoreHandle.store else { return false }
    let route = CommandRoute.resolve("toggleDeveloperMode", windowId: windowId, state: store.state, closing: store.memory.closingWindows)
    guard let tabId = route.tabId, let context = SiteControlsLogic.context(state: store.state, tabId: tabId,
      pageEngine: store.pageEngine(tabId, in: store.state), input: [:]),
      let value = SiteControlsLogic.developerSettings(context: context, on: !SiteControlsLogic.developerEnabled(context: context)) else { return true }
    _ = try? store.dispatch(Command("updateSettings", [["developerMode": value]]), origin: .native)
    return true
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
  var onClosed: (() -> Void)?
  private let popoverRevision: UInt64
  private var input: JSONValue
  private var context: JSONValue = [:]
  private var session = SiteControlsSession()
  private var settings: JSONValue?
  private var displayed: SitePanelState?
  private var blocker: JSONValue?
  private var expanded: String?
  private var cleared: String?
  private var closed = false
  private var scope: PageActionScope?
  private var clearAlert: NSAlert?
  private var security: JSONValue?
  private static var toastId = -2_000_000

  init(input: JSONValue) {
    self.input = input
    popoverRevision = NativeSelectionTools.zoomRevision(input["tabId"]?.string ?? "")
    popover = PopoverView(body: body)
    popover.autoresizingMask = [.width, .height]
    body.favicons = NewTabNetwork.favicons
    body.onHeight = { [weak self] height in self?.popover.set(bodyHeight: height) }
    body.onEvent = { [weak self] event in self?.handle(event) }
    popover.onDismiss = { [weak self] in self?.dismiss() }
    popover.onClosed = { [weak self] in self?.onClosed?() }
  }

  #if DEBUG
  func describe(windowId: String) -> [String: Any]? {
    guard !closed, context["windowId"]?.string == windowId, body.window != nil, !body.isHiddenOrHasHiddenAncestor else { return nil }
    let frame = popover.cardFrame
    return ["tabId": context["tabId"]?.string ?? "", "card": [frame.minX, frame.minY, frame.width, frame.height]]
  }
  #endif

  var tabId: String? { input["tabId"]?.string }

  func canRehost(tabId: String, window: NSWindow) -> Bool {
    self.tabId == tabId && popover.window === window && matches(context, scope: scope)
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
    if let alert = clearAlert, let parent = alert.window.sheetParent {
      parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
    }
    popover.close()
  }

  func dismiss() {
    guard !closed else { return }
    close()
    guard let tabId = input["tabId"]?.string, NativeSelectionTools.popoverSnapshot()[tabId] == "siteControls",
      NativeSelectionTools.zoomRevision(tabId) == popoverRevision else { return }
    _ = NativeSelectionTools.setPopover(tabId, value: nil)
  }

  func refresh() {
    guard !closed else { return }
    guard let tabId = input["tabId"]?.string else { return }
    let store = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if let store {
      guard !NativeStoreHandle.frozen, let tab = store.state.tabs[tabId], let window = store.state.windows[tab.windowId],
        tab.profileId == window.profileId, !store.memory.closingWindows.contains(tab.windowId), window.keptOnClose != true
      else { dismiss(); return }
    }
    guard var c = SiteControlsLogic.context(state: store?.state, tabId: tabId,
      pageEngine: store.map { $0.pageEngine(tabId, in: $0.state) } ?? "", input: input)?.object else { dismiss(); return }
    let nextScope = NativeEngineCommands.pageScope(tabId)
    if scope != nextScope, scope != nil {
      dismiss()
      return
    }
    scope = nextScope
    if let store {
      c["security"] = nil
      c["playingAudio"] = .bool(store.state.live[tabId]?.playingAudio == true)
    }
    c["video"] = .bool(NowPlayingStore.shared.entries[tabId]?.report.hasVideo == true)
    c["pip"] = .bool(NowPlayingStore.shared.pictureInPicture[tabId] != nil)
    let windowId = c["windowId"]?.string ?? ""
    if let provider = NativeSiteControls.shared.extensions { c["extensions"] = provider.rows(tabId: tabId, windowId: windowId) }
    if let provider = NativeSiteControls.shared.translate { c["translate"] = provider.rows(tabId: tabId, windowId: windowId) }
    let next = JSONValue.object(c)
    let changed = next != context
    context = next
    let refreshToken = session.beginRefresh(context: next, scope: nextScope)
    guard changed || refreshToken != nil else { return }
    let placement = PopoverPlacement(width: 288, top: input["top"]?.number ?? 8, right: input["right"]?.number, left: input["left"]?.number, fitHeight: true)
    popover.set(placement: placement, dark: input["dark"]?.bool == true)
    if let token = refreshToken {
      settings = nil
      blocker = nil
      security = nil
      cleared = nil
      let captured = context
      let pageScope = scope
      Task { [weak self] in await self?.readPermissions(captured, scope: pageScope, token: token) }
      Task { [weak self] in await self?.readBlocker(captured, scope: pageScope, token: token) }
      Task { [weak self] in
        guard let self else { return }
        let info = await self.page("getSecurityInfo", scope: pageScope)
        guard self.matches(captured, scope: pageScope), self.session.accepts(token: token), !info.isNull else { return }
        self.security = info
        self.render()
      }
    }
    render()
  }

  private func render() {
    var visible = context.object ?? [:]
    if let security { visible["security"] = security }
    guard let state = SiteControlsLogic.state(context: .object(visible), expanded: expanded, featured: session.featured, settings: settings, blocker: blocker, cleared: cleared), state != displayed else { return }
    displayed = state
    body.update(state)
  }

  private func readPermissions(_ c: JSONValue, scope: PageActionScope?, token: Int) async {
    guard matches(c, scope: scope), let origin = SiteControlsLogic.origin(c["url"]?.string ?? "") else { return }
    let profile = c["profile"]?.string ?? ""
    let result: JSONValue
    if c["pageEngine"] == "webkit" {
      result = NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitSettings(profile: profile, origin: origin))
    } else {
      result = await EngineCalls.result({ done in SolaraCoreServices.siteSettings(profile: profile, origin: origin, completion: done) }, NativeSiteControls.json)
    }
    guard matches(c, scope: scope), session.receivePermissions(context: context, settings: result, token: token) else { return }
    settings = result
    render()
  }

  func refreshBlockerStatus() {
    guard matches(context, scope: scope), context["pageEngine"] == "webkit" else { return }
    let host = SiteControlsLogic.host(context["url"]?.string ?? "")
    blocker = NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitBlockerStatus(host: host))
    render()
  }

  private func readBlocker(_ c: JSONValue, scope: PageActionScope?, token: Int) async {
    guard matches(c, scope: scope) else { return }
    let host = SiteControlsLogic.host(c["url"]?.string ?? "")
    let result: JSONValue
    if c["pageEngine"] == "webkit" {
      result = NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitBlockerStatus(host: host))
    } else {
      let state = await EngineCalls.result({ done in SolaraCoreContentBlocker.state(done) }, NativeSiteControls.json)
      let allowed = await EngineCalls.result({ done in SolaraCoreContentBlocker.isAllowed(host: host) { done(["allowed": $0]) } }, { $0["allowed"] as? Bool == true })
      result = ["enabled": .bool(state["enabled"]?.bool == true), "allowed": .bool(allowed)]
    }
    guard matches(c, scope: scope), session.accepts(token: token) else { return }
    blocker = result
    render()
  }

  private func page(_ method: String, _ args: [Any] = [], scope: PageActionScope?) async -> JSONValue {
    let captured = context
    guard matches(captured, scope: scope) else { return .null }
    if !NativeStoreHandle.ownsWorkspace {
      let result = await SettingsAdapters.js("site.page", captured["tabId"]?.string ?? "", method, args, captured.foundation)
      return matches(captured, scope: scope) ? NativeSiteControls.json(result) : .null
    }
    guard let scope, let issuer = PageIssuer.shared,
      let command = try? PageCommand.decode(method: method, args: args.map { try PageValue(any: $0) }) else { return .null }
    return await withCheckedContinuation { continuation in
      issuer.store.sequence {
        guard matches(context, scope: scope) else { continuation.resume(returning: .null); return }
        issuer.issueInScope(tabId: scope.tab.id, identity: scope.identity, command: command) { result in
          guard self.matches(self.context, scope: scope) else { continuation.resume(returning: .null); return }
          continuation.resume(returning: NativeSiteControls.json((try? result.get())?.foundation))
        }
      }
    }
  }

  private func showSettings(_ pane: String, detail: String? = nil) {
    NativeSettingsWindow.navigate(pane: pane, profileId: nil, detail: detail)
    WindowHost.openAuxiliary(id: NativeSettingsWindow.windowId, kind: "settings", title: "Settings")
  }

  private func handle(_ event: SitePanelEvent) {
    guard matches(context, scope: scope) else { return }
    let id: String
    switch event {
    case .press(let value, _), .menu(let value, _), .toggle(let value, _), .zoom(let value, _): id = value
    }
    let tabId = context["tabId"]?.string ?? ""
    let windowId = context["windowId"]?.string ?? ""
    switch SiteControlsLogic.action(event, context: context) {
    case .contribution:
      let provider = NativeStoreHandle.store == nil ? nil : id.hasPrefix("ext:") ? NativeSiteControls.shared.extensions : NativeSiteControls.shared.translate
      _ = provider?.handle(event, tabId: tabId, windowId: windowId, close: { [weak self] in self?.dismiss() })
    case .zoom(let step):
      let source = scope
      Task { _ = await page("zoomStep", [step], scope: source) }
    case .fullURL(let on):
      updateSettings(["showFullUrl": .bool(on)])
    case .expand(let section):
      expanded = expanded == section ? nil : section
      render()
    case .developer(let changed):
      updateSettings(["developerMode": changed])
    case .blocker: Task { await toggleBlocker() }
    case .keepAwake(let sites):
      updateSettings([KeepAwakeSites.settingKey: sites])
    case .sleepSettings(let detail):
      dismiss()
      showSettings("tabs", detail: detail)
    case .enginePicker: pickEngine()
    case .clear: Task { await clearData() }
    case .permission(let type): pickPermission(type)
    case .shared(let action):
      guard case .press(_, let rect) = event else { return }
      if action == "cast" {
        dismiss()
        NativeCast.toggle(windowID: windowId, tabID: tabId)
        return
      }
      if action == "pip" {
        NativeMediaStack.togglePictureInPicture(tabId: tabId, windowId: windowId, window: body.window)
        dismiss()
        return
      }
      switch action {
      case "copy", "share":
        let options: JSONValue = ["tabId": .string(tabId), "anchor": .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })]
        let captured = context
        dismiss()
        if !NativeLinkCommands.perform(action == "copy" ? "copyUrl" : "share", arg: options.text(), windowId: windowId) {
          Task { await legacyAction(action, args: ["rect": [rect.minX, rect.minY, rect.width, rect.height]], captured: captured) }
        }
      case "find":
        let captured = context
        dismiss()
        if !NativeStoreHandle.ownsWorkspace {
          Task { await legacyAction(action, captured: captured) }
          return
        }
        let request = Int(Date().timeIntervalSince1970 * 1000)
        try? NativeStoreHandle.store?.dispatch(Command("setFind", [.string(tabId), ["open": true, "replace": false, "focusRequest": JSONValue(request)]]), origin: .native)
      case "other-engine":
        guard scope != nil else { return }
        dismiss()
        NativeEngineCommands.request(tabId: tabId, action: "toggle", options: [:]) { _ in }
      default: break
      }
    case .none: break
    }
  }

  private func matches(_ captured: JSONValue, scope: PageActionScope?) -> Bool {
    guard !closed, let id = captured["tabId"]?.string, NativeSelectionTools.popoverSnapshot()[id] == "siteControls",
      NativeSelectionTools.zoomRevision(id) == popoverRevision else { return false }
    if !NativeStoreHandle.ownsWorkspace {
      return scope == nil && ["tabId", "windowId", "profileId", "url", "pageEngine", "navigationSeq", "mount"].allSatisfy { context[$0] == captured[$0] }
    }
    guard let store = NativeStoreHandle.store, !NativeStoreHandle.frozen, let tab = store.state.tabs[id],
      let window = store.state.windows[tab.windowId], window.profileId == tab.profileId, window.keptOnClose != true,
      ToolbarActionCommand.resolve(windowId: tab.windowId, tabId: id, state: store.state, closing: store.memory.closingWindows) != nil,
      captured["windowId"]?.string == tab.windowId, captured["profileId"]?.string == tab.profileId,
      captured["url"]?.string == tab.url, captured["pageEngine"]?.string == store.pageEngine(id, in: store.state),
      NativeEngineCommands.pageScope(id) == scope else { return false }
    return true
  }

  private func updateSettings(_ changed: JSONObject) {
    if let model = NativeSettingsHandle.model { model.update(changed); return }
    let captured = context
    let source = scope
    Task {
      guard !NativeStoreHandle.ownsWorkspace, matches(captured, scope: source) else { return }
      _ = await SettingsAdapters.js("site.settings", captured["tabId"]?.string ?? "", captured.foundation, JSONValue.object(changed).foundation)
    }
  }

  private func legacyAction(_ action: String, args: [String: Any] = [:], captured: JSONValue) async {
    guard !NativeStoreHandle.ownsWorkspace else { return }
    _ = await SettingsAdapters.js("site.action", captured["tabId"]?.string ?? "", action, args, captured.foundation)
  }

  private func pickPermission(_ type: String) {
    let captured = context
    let source = scope
    let choices = SiteControlsLogic.permissionChoices(type).map { ($0, SiteControlsLogic.choiceTitle(type, $0), settings?[type]?["value"]?.string == $0) }
    guard let choice = SiteMenuChoice.pick(choices) else { return }
    Task {
      guard matches(captured, scope: source), let origin = SiteControlsLogic.origin(captured["url"]?.string ?? "") else { return }
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
      guard matches(captured, scope: source) else { return }
      settings = refreshed
      render()
      if type == "sound" {
        if let source {
          _ = try? NativeStoreHandle.store?.dispatch(Command("updateTab", [.string(source.tab.id), ["muted": .bool(choice == "block")]]), origin: .native)
        } else if !NativeStoreHandle.ownsWorkspace {
          _ = await SettingsAdapters.js("site.muted", captured["tabId"]?.string ?? "", captured.foundation, choice == "block")
        }
        _ = await page("setMuted", [choice == "block"], scope: source)
      }
    }
  }

  private func pickEngine() {
    let captured = context
    guard let scope else { return }
    let choices = SiteControlsLogic.engineChoices(context: captured)
    guard let choice = SiteMenuChoice.pick(choices.map { ($0.id, $0.title, $0.checked) }, separatorAfterFirst: captured["privatePage"]?.bool != true) else { return }
    guard matches(captured, scope: scope) else { return }
    let engine = choice == "default" ? captured["recommendedEngine"]?.string ?? "chromium" : choice
    dismiss()
    NativeEngineCommands.request(tabId: scope.tab.id, action: "open", options: ["engine": .string(engine), "rule": choice == "default" ? .null : .string(choice)]) { _ in }
  }

  private func toggleBlocker() async {
    let scope = self.scope
    guard let blocker, matches(context, scope: scope) else { return }
    if blocker["enabled"]?.bool != true {
      dismiss()
      showSettings("privacy")
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
    guard matches(captured, scope: scope) else { return }
    self.blocker = captured["pageEngine"] == "webkit"
      ? NativeSiteControls.json(SolaraCoreSiteControlsBridge.webKitBlockerStatus(host: host))
      : ["enabled": blocker["enabled"] ?? false, "allowed": .bool(allowed)]
    render()
    if error != nil {
      Self.toastId -= 1
      NativeSplitChrome.showNativeToast(.init(id: Self.toastId, title: "Couldn't Change the Ad Blocker",
        message: "Blocking on \(host) is as it was. Try again.", icon: "exclamationmark.triangle"), windowId: captured["windowId"]?.string ?? "")
    } else { _ = await page("reload", scope: scope) }
  }

  private func clearData() async {
    let captured = context
    let scope = self.scope
    guard matches(captured, scope: scope), clearAlert == nil, SiteControlsLogic.origin(captured["url"]?.string ?? "") != nil else { return }
    let alert = NSAlert()
    alert.messageText = "Clear cookies and site data for \(SiteControlsLogic.host(captured["url"]?.string ?? ""))?"
    alert.informativeText = "You'll be signed out of this site, and its offline data will be deleted."
    alert.addButton(withTitle: "Clear").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    clearAlert = alert
    let confirmed: Bool = await withCheckedContinuation { continuation in
      if let window = ShellDrag.window(captured["windowId"]?.string ?? ""), window.isVisible {
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
      } else { continuation.resume(returning: false) }
    }
    clearAlert = nil
    guard confirmed, matches(captured, scope: scope) else { return }
    let result = await page("clearSiteData", scope: scope)
    guard !result.isNull, matches(captured, scope: scope) else { return }
    let n = result["cookies"]?.int ?? 0
    cleared = n == 0 ? "Cleared site data" : "Cleared \(n) cookie\(n == 1 ? "" : "s") and site data"
    render()
    _ = await page("reload", scope: scope)
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
