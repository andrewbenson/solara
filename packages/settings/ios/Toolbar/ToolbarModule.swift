import AppKit
import ExpoModulesCore
import Foundation
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

public class ToolbarModule: Module {
  nonisolated static var available: Bool { NativeSettingsHandle.active }

  public func definition() -> ModuleDefinition {
    Name("SolaraToolbar")

    Events("onExtensionPopupChanged")

    OnCreate {
      let sink = ToolbarPopupEventSink(module: self)
      DispatchQueue.main.async { MainActor.assumeIsolated {
        NativeExtensionCommands.install()
        NativeExtensionCatalog.emit = { toolbar, menus in
          if toolbar { NativeToolbarPresenter.refreshContributions() }
          if menus {
            NativeSiteControls.shared.refresh()
            ShellMenus.refreshExtensions()
          }
        }
        NativeExtensionActionPopup.install()
        NativeExtensionActionPopup.emit = { name, body in sink.module?.sendEvent(name, body) }
        NativeExtensionCatalog.publish(force: true)
      } }
    }

    OnDestroy {
      DispatchQueue.main.async { MainActor.assumeIsolated {
        NativeExtensionActionPopup.close()
        NativeExtensionSidePanel.closeAll()
        NativeExtensionActionPopup.emit = nil
        NativeExtensionCatalog.emit = nil
      } }
    }

    AsyncFunction("refreshExtensionCatalog") { (profile: String, afterChange: Bool) async -> String in
      await NativeExtensionCatalog.refreshAndWait(profile, afterChange: afterChange)
    }

    AsyncFunction("extensionCommand") { (json: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        NativeExtensionCommands.run((try? JSONValue.parse(Data(json.utf8))) ?? .null) { error in
          if let error { reply.reject("ERR_EXTENSION_COMMAND", error) }
          else { reply.resolve(nil) }
        }
      }
    }.runOnQueue(.main)

    Function("extensionPopupWindow") { () -> String? in
      NativeExtensionActionPopup.visibleWindowId
    }

    Function("available") { () -> Bool in ToolbarModule.available }

    AsyncFunction("closeExtensionPopup") { (windowId: String?) in
      MainActor.assumeIsolated { NativeExtensionActionPopup.close(windowId: windowId) }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devSidePanel") { (windowId: String, action: String, id: String?) -> [String: String]? in
      MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed() else { return nil }
        switch action {
        case "open": if let id { NativeExtensionSidePanel.open(windowId, id) }
        case "toggle": if let id { NativeExtensionSidePanel.toggle(windowId, id) }
        case "close": NativeExtensionSidePanel.close(windowId)
        default: break
        }
        return NativeExtensionSidePanel.extensionId(windowId: windowId).map { ["extensionId": $0] }
      }
    }.runOnQueue(.main)

    AsyncFunction("devExtensionSheet") { (action: String, id: String?, windowId: String?) -> [String: Any]? in
      let snapshot: JSONValue? = MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed(), let value = NativeExtensionSheets.dev(action, id, windowId),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONValue.parse(data)
      }
      return snapshot?.foundation as? [String: Any]
    }.runOnQueue(.main)

    AsyncFunction("devExtensionCatalog") { () -> [String: Any] in
      let snapshot: JSONValue = MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed() else { return [:] }
        return ["native": .bool(NativeExtensionCatalog.current), "polling": .bool(NativeExtensionCatalog.polling),
          "lists": .object(JSONObject(NativeExtensionCatalog.catalog.lists.map { ($0.key, .array($0.value.map(JSONValue.object))) }))]
      }
      return snapshot.foundation as? [String: Any] ?? [:]
    }.runOnQueue(.main)

    AsyncFunction("devExtensionPopup") { (windowId: String) -> String in
      MainActor.assumeIsolated {
        guard SolaraCoreTestHooksAllowed(), let snapshot = ExtensionActionPopupRead.snapshot(windowId: windowId) else { return "null" }
        return (try? JSONSerialization.data(withJSONObject: snapshot)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
      }
    }.runOnQueue(.main)
    #endif

    #if DEBUG
    Function("devToolbarStates") { (windowId: String) -> String in
      if Thread.isMainThread { return MainActor.assumeIsolated { NativeToolbarHostView.devStates(windowId) } }
      return DispatchQueue.main.sync { MainActor.assumeIsolated { NativeToolbarHostView.devStates(windowId) } }
    }
    #endif

    AsyncFunction("devToolbar") { (windowId: String, tabId: String) -> String in
      MainActor.assumeIsolated {
        #if DEBUG
        let toolbar = NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)
        var out: [String: Any] = [
          "extensions": toolbar?.describeExtensions() ?? [],
          "urlRight": toolbar?.state.map { $0.geometry.urlRight as Any } ?? NSNull(),
          "infoPopover": ToolbarInfoPopover.describe() ?? NSNull(),
          "urlEditor": toolbar.map { containsDeveloperUrlField($0) } ?? false,
        ]
        if SolaraCoreTestHooksAllowed(), let toolbar, !toolbar.isHiddenOrHasHiddenAncestor,
          let frameView = toolbar.window?.contentView?.superview,
          let button = toolbar.layoutAnchors["button:sidebar"], !button.isEmpty {
          let point = toolbar.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
          out["sidebarButtonPoint"] = [point.x, frameView.bounds.height - point.y]
        }
        return (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        #else
        return "null"
        #endif
      }
    }.runOnQueue(.main)

    AsyncFunction("devInfoPopover") { (action: String) -> Bool in
      MainActor.assumeIsolated {
        #if DEBUG
        switch action {
        case "press": return ToolbarInfoPopover.pressAction()
        case "close":
          ToolbarInfoPopover.close()
          return true
        default: return ToolbarInfoPopover.describe() != nil
        }
        #else
        return false
        #endif
      }
    }.runOnQueue(.main)

    View(NativeToolbarHostView.self) {
      Events("onToolbarClick", "onToolbarAnchors")

      Prop("input") { (view: NativeToolbarHostView, v: String) in MainActor.assumeIsolated { view.setInput(v) } }
    }
  }
}

final class NativeToolbarHostView: ExpoView {
  let onToolbarClick = EventDispatcher()
  let onToolbarAnchors = EventDispatcher()
  let toolbar = ToolbarView(frame: .zero)
  private var input = ""
  private lazy var presenter = NativeToolbarPresenter { [weak self] state, _ in self?.apply(state) }
  private weak var toolbarShell: WindowShellView?
  private static let live = NSHashTable<NativeToolbarHostView>.weakObjects()

  static func toolbar(windowId: String, tabId: String) -> ToolbarView? { NativeSplitChrome.toolbar(windowId: windowId, tabId: tabId) ?? host(windowId: windowId, tabId: tabId)?.toolbar }

  static func extensionButton(_ event: NSEvent) -> ExtensionPopupButton? {
    guard let window = event.window, let root = window.contentView,
      let hit = root.superview?.hitTest(event.locationInWindow) else { return nil }
    let native = root.convert(event.locationInWindow, from: nil)
    let point = root.isFlipped ? native : CGPoint(x: native.x, y: root.bounds.height - native.y)
    for toolbar in toolbars(in: root) where hit.isDescendant(of: toolbar) {
      for item in toolbar.describeExtensions() {
        guard let id = item["id"] as? String, id.hasPrefix("ext:"), let frame = item["frame"] as? [CGFloat], frame.count == 4,
          CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]).contains(point) else { continue }
        return ExtensionPopupButton(owner: ObjectIdentifier(hit), id: id, tabId: toolbar.state?.tabId)
      }
    }
    return nil
  }

  static func extensionAnchor(window: NSWindow, tabId: String?, extensionId: String, fallback: Bool = false) -> CGRect? {
    guard let root = window.contentView else { return nil }
    for toolbar in toolbars(in: root) where toolbar.state?.tabId == tabId {
      if let anchor = toolbar.extensionAnchor(extensionId, fallback: fallback) { return anchor }
    }
    return nil
  }

  private static func toolbars(in view: NSView) -> [ToolbarView] {
    guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return [] }
    if let toolbar = view as? ToolbarView { return [toolbar] }
    return view.subviews.flatMap { toolbars(in: $0) }
  }

  #if DEBUG
  static func devStates(_ windowId: String) -> String {
    guard SolaraCoreTestHooksAllowed(), let model = NativeStoreHandle.store?.state.windows[windowId] else { return "[]" }
    let states = model.tabIds.compactMap { toolbar(windowId: windowId, tabId: $0)?.state }
    guard let data = try? JSONEncoder().encode(states) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
  #endif

  static func host(windowId: String, tabId: String) -> NativeToolbarHostView? {
    let tabWindow = NativeStoreHandle.store?.state.tabs[tabId]?.windowId
    guard tabWindow == nil || tabWindow == windowId else { return nil }
    let hosts = live.allObjects.filter { $0.window != nil && $0.toolbar.state?.tabId == tabId }
    return hosts.first { !$0.isHiddenOrHasHiddenAncestor } ?? hosts.first
  }

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    toolbar.autoresizingMask = [.width, .height]
    toolbar.frame = bounds
    toolbar.onGeometryChange = { [weak self] in
      guard let self, let tabId = toolbar.state?.tabId, let windowId = toolbarShell?.windowId else { return }
      AutoHideHost.toolbarReady(windowId: windowId, tabId: tabId, toolbar: toolbar)
    }
    toolbar.onLayoutAnchorsChange = { [weak self] in
      guard let windowId = self?.toolbarShell?.windowId else { return }
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
    }
    toolbar.onHiddenOrDetached = { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        NativeExtensionActionPopup.flushHeldFieldBlur(from: self)
      }
    }
    toolbar.onClick = { [weak self] click in
      MainActor.assumeIsolated {
        guard let self, let target = self.toolbar.state?.tabId else { return }
        if NativeToolbarActions.perform(click, source: self.toolbar,
          target: self.toolbar.state.map { .pane($0.tabId) }) { return }
        if let tabId = self.toolbar.state?.tabId,
          click.id == "urlEdit" || click.kind == .menu || self.toolbar.state?.url?.developer == nil,
          NativeOmniboxActions.addressClick(click, windowId: self.toolbarShell?.windowId ?? NativeStoreHandle.store?.state.tabs[tabId]?.windowId ?? "", tabId: tabId, view: self.toolbar) {
          if click.id == "urlEdit", click.kind == .submit {
            self.onToolbarClick(["tabId": target, "id": "urlEdit", "kind": "cancel", "nativeActions": true, "meta": false, "alt": false, "shift": false])
          }
          return
        }
        let payload: [String: Any] = ["tabId": target, "id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()]
        if click.id == "urlEdit", click.kind.rawValue == "focus" { NativeExtensionActionPopup.dropHeldFieldBlur(from: self) }
        if click.id == "urlEdit", click.kind.rawValue == "blur",
          NativeExtensionActionPopup.holdFieldBlur(from: self, fieldContainer: self.toolbar, flush: { self.onToolbarClick(payload) }) { return }
        self.onToolbarClick(payload)
      }
    }
    toolbar.onAnchors = { [weak self] anchors in
      MainActor.assumeIsolated {
        if let self, !self.isHiddenOrHasHiddenAncestor {
          NativeExtensionActionPopup.anchorsChanged(window: self.window, tabId: self.toolbar.state?.tabId, anchors: anchors)
        }
      }
      self?.onToolbarAnchors(["anchors": anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }])
    }
    addSubview(toolbar)
    Self.live.add(self)
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    toolbar.needsLayout = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func setInput(_ next: String) {
    guard next != input else { return }
    input = next
    if window != nil { presenter.update(next) }
  }

  private func apply(_ state: ToolbarState?) {
    guard let state else {
      toolbar.clearPresentation()
      return
    }
    if toolbar.state?.tabId != state.tabId { toolbar.clearPresentation() }
    toolbar.update(state)
    toolbar.isHidden = false
    syncToolbarShell()
    AutoHideHost.toolbarReady(tabId: state.tabId)
  }

  private func syncToolbarShell() {
    let shell = windowShell
    if toolbarShell !== shell {
      toolbarShell?.unregisterToolbar(toolbar)
      toolbarShell = shell
    }
    shell?.registerToolbar(toolbar, owner: self)
  }

  override func layout() {
    super.layout()
    syncToolbarShell()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    syncToolbarShell()
  }

  override func viewDidHide() {
    super.viewDidHide()
    syncToolbarShell()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncToolbarShell()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncToolbarShell()
    if window != nil { presenter.update(input) }
    else { presenter.end() }
  }
}

public class SidebarAddressBarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSidebarAddressBar")

    Function("available") { () -> Bool in ToolbarModule.available && ProcessInfo.processInfo.environment["SOLARA_NATIVE_SIDEBAR_ADDRESS"] != "0" }

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { SidebarAddressBridge.install() } } }

    AsyncFunction("set") { (windowId: String, json: String?) in
      MainActor.assumeIsolated {
        SidebarAddressBridge.install()
        SidebarAddressBridge.set(windowId, input: json)
      }
    }.runOnQueue(.main)

    AsyncFunction("sample") { (windowId: String) -> String? in
      MainActor.assumeIsolated {
        guard let view = SidebarAddressBars.shared.existing(windowId) else { return nil }
        var out = view.sample()
        out["claimed"] = SidebarAddressBars.shared.claimed(windowId)
        out["inWindow"] = view.window != nil
        return (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) }
      }
    }.runOnQueue(.main)

    View(NativeSidebarAddressHostView.self) {
      Prop("windowId") { (view: NativeSidebarAddressHostView, v: String) in MainActor.assumeIsolated { view.windowId = v } }
    }
  }
}

@MainActor
enum SidebarAddressBridge {
  private static var installed = false
  private static var presenters: [String: NativeToolbarPresenter] = [:]

  static func set(_ windowId: String, input: String?) {
    guard let input else {
      presenters.removeValue(forKey: windowId)?.end()
      return
    }
    if presenters[windowId] == nil {
      presenters[windowId] = NativeToolbarPresenter { _, state in SidebarAddressBars.shared.set(windowId, state: state) }
    }
    presenters[windowId]?.update(input)
  }

  static func install() {
    guard !installed else { return }
    installed = true
    SidebarAddressBars.shared.onClick = { windowId, source, click in
      guard let presented = source.state else { return }
      let target = NativeStoreHandle.store?.state.activeTabId(windowId)
      if NativeStoreHandle.ownsWorkspace, presented.tabId != (target ?? "") { return }
      if NativeToolbarActions.perform(click, source: source, windowId: windowId, target: .window) { return }
      let bar = SidebarAddressBars.shared.existing(windowId)
      if NativeOmniboxActions.ownsActions, click.id == "url" || click.id == "urlEdit",
        NativeStoreHandle.store?.state.activeTabId(windowId) == nil { return }
      if let store = NativeStoreHandle.store, let tabId = store.state.activeTabId(windowId),
        click.id == "urlEdit" || click.kind == .menu || bar?.state?.url?.developer == nil,
        NativeOmniboxActions.addressClick(click, windowId: windowId, tabId: tabId, view: bar) {
        if click.id == "urlEdit", click.kind == .submit {
          Task { @MainActor in _ = await SettingsAdapters.js("sidebar.addressClick", windowId, ["tabId": tabId, "id": "urlEdit", "kind": "cancel", "nativeActions": true]) }
        }
        return
      }
      var payload: [String: Any] = ["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()]
      payload["tabId"] = presented.tabId
      Task { @MainActor in _ = await SettingsAdapters.js("sidebar.addressClick", windowId, payload) }
    }
    SidebarAddressBars.shared.onAnchors = { windowId, anchors in
      NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
      let state = NativeStoreHandle.store?.state
      let tabId = state?.peeks[windowId]?.tabId ?? state?.activeTabId(windowId)
      NativeExtensionActionPopup.anchorsChanged(window: ShellDrag.window(windowId), tabId: tabId, anchors: anchors)
      sendAnchors(windowId, anchors)
    }
    SettingsJS.shared.onConnect {
      for (windowId, anchors) in SidebarAddressBars.shared.anchors { sendAnchors(windowId, anchors) }
      SidebarAddressBars.shared.reannounceOnNextSet()
    }
  }

  private static func sendAnchors(_ windowId: String, _ anchors: [String: CGRect]) {
    guard SettingsJS.shared.connected else { return }
    let payload = anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
    Task { @MainActor in _ = await SettingsAdapters.js("sidebar.addressAnchors", windowId, payload) }
  }

  static func extensionAnchor(windowId: String, extensionId: String) -> CGRect? {
    let bars = SidebarAddressBars.shared
    guard let bar = bars.existing(windowId), !bar.isHiddenOrHasHiddenAncestor, let anchors = bars.anchors[windowId] else { return nil }
    return anchors[extensionId] ?? anchors["*"]
  }

  static func extensionButton(windowId: String, event: NSEvent) -> ExtensionPopupButton? {
    guard let bar = SidebarAddressBars.shared.existing(windowId), !bar.isHiddenOrHasHiddenAncestor,
      let root = event.window?.contentView, bar.window === event.window,
      let hit = root.superview?.hitTest(event.locationInWindow), hit.isDescendant(of: bar) else { return nil }
    let native = root.convert(event.locationInWindow, from: nil)
    let point = root.isFlipped ? native : CGPoint(x: native.x, y: root.bounds.height - native.y)
    guard let anchors = SidebarAddressBars.shared.anchors[windowId],
      let id = anchors.first(where: { key, rect in key != "*" && key != "field" && rect.contains(point) })?.key else { return nil }
    return ExtensionPopupButton(owner: ObjectIdentifier(hit), id: "ext:\(id)", tabId: nil)
  }
}

private final class ToolbarPopupEventSink: @unchecked Sendable {
  weak var module: ToolbarModule?

  init(module: ToolbarModule) { self.module = module }
}

final class NativeSidebarAddressHostView: ExpoView {
  var windowId = "" {
    didSet { if windowId != oldValue { adopt() } }
  }

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    NotificationCenter.default.addObserver(self, selector: #selector(claimsChanged), name: SidebarAddressBars.claimsChanged, object: nil)
  }

  @objc private func claimsChanged() { adopt() }

  private func adopt() {
    guard !windowId.isEmpty else { return }
    MainActor.assumeIsolated {
      SidebarAddressBridge.install()
      let bars = SidebarAddressBars.shared
      guard !bars.claimed(windowId) else { return }
      let bar = bars.view(windowId)
      if bar.superview !== self {
        bar.frame = bounds
        bar.autoresizingMask = [.width, .height]
        addSubview(bar)
      }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { adopt() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

#if SOLARA_PROBES
@MainActor
public enum SidebarAddressBarRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let view = SidebarAddressBars.shared.existing(windowId) else { return nil }
    let source = view.sample()
    return ["frame": source["frame"] ?? NSNull(), "field": source["field"] ?? NSNull(),
      "buttons": source["buttons"] ?? [], "claimed": SidebarAddressBars.shared.claimed(windowId),
      "inWindow": view.window != nil]
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum ToolbarStateRead {
  public static func snapshot(windowId: String, tabId: String) -> [String: Any]? {
    guard let toolbar = NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId), let state = toolbar.state else { return nil }
    return ["tabId": state.tabId, "hidden": toolbar.isHiddenOrHasHiddenAncestor,
      "url": state.url.map { $0.host + $0.hoverTrail } ?? NSNull(),
      "identity": String(describing: ObjectIdentifier(toolbar)), "background": state.palette.background ?? NSNull(),
      "hairline": state.hairline, "stripes": state.stripes ?? NSNull(), "windowToolbar": state.windowToolbar ?? false,
      "reloadIcon": state.left.first(where: { $0.id == "reload" }).map { $0.icon as Any } ?? NSNull(),
      "zoomLabel": (state.url?.trailing.first(where: { $0.id == "zoom" })?.tooltip).map { $0 as Any } ?? NSNull()]
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum ToolbarRead {
  public static func snapshot(windowId: String) -> [[String: Any]] {
    guard let model = NativeStoreHandle.store?.state.windows[windowId] else { return [] }
    var rows: [[String: Any]] = []
    for tabId in model.tabIds {
      guard let toolbar = NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId), let state = toolbar.state else { continue }
      rows.append(["tabId": state.tabId, "bare": state.bare, "urlHost": state.url.map { $0.host as Any } ?? NSNull(),
        "identity": String(describing: ObjectIdentifier(toolbar)), "background": state.palette.background ?? NSNull(),
        "hairline": state.hairline, "stripes": state.stripes ?? NSNull(), "windowToolbar": state.windowToolbar ?? false])
    }
    return rows
  }
}
#endif

#if DEBUG
@MainActor
private func containsDeveloperUrlField(_ view: NSView) -> Bool {
  String(describing: type(of: view)).contains("DeveloperUrlField") || view.subviews.contains { containsDeveloperUrlField($0) }
}
#endif
