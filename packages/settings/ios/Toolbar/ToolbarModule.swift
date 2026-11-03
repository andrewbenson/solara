import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

public class ToolbarModule: Module {
  nonisolated static var available: Bool { NativeSettingsHandle.active }

  public func definition() -> ModuleDefinition {
    Name("SolaraToolbar")

    Function("available") { () -> Bool in ToolbarModule.available }

    AsyncFunction("devToolbar") { (windowId: String, tabId: String) -> String in
      MainActor.assumeIsolated {
        #if DEBUG
        let toolbar = NativeToolbarHostView.toolbar(windowId: windowId, tabId: tabId)
        let out: [String: Any] = [
          "extensions": toolbar?.describeExtensions() ?? [],
          "urlRight": toolbar?.state.map { $0.geometry.urlRight as Any } ?? NSNull(),
          "infoPopover": ToolbarInfoPopover.describe() ?? NSNull(),
        ]
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

      Prop("state") { (view: NativeToolbarHostView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeToolbarHostView: ExpoView {
  let onToolbarClick = EventDispatcher()
  let onToolbarAnchors = EventDispatcher()
  let toolbar = ToolbarView(frame: .zero)
  private var json = ""
  private static let live = NSHashTable<NativeToolbarHostView>.weakObjects()

  static func toolbar(windowId: String, tabId: String) -> ToolbarView? { host(windowId: windowId, tabId: tabId)?.toolbar }

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
    toolbar.onClick = { [weak self] click in
      self?.onToolbarClick(["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()])
    }
    toolbar.onAnchors = { [weak self] anchors in
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

  func setState(_ next: String) {
    guard next != json, let state = ToolbarState.decode(next) else { return }
    json = next
    toolbar.update(state)
    AutoHideHost.toolbarReady(tabId: state.tabId)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, let tabId = toolbar.state?.tabId { AutoHideHost.toolbarReady(tabId: tabId) }
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
        SidebarAddressBars.shared.set(windowId, json: json)
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
  private static var latestAnchors: [String: [String: [CGFloat]]] = [:]

  static func install() {
    guard !installed else { return }
    installed = true
    SidebarAddressBars.shared.onClick = { windowId, click in
      let payload: [String: Any] = ["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()]
      Task { @MainActor in _ = await SettingsAdapters.js("sidebar.addressClick", windowId, payload) }
    }
    SidebarAddressBars.shared.onAnchors = { windowId, anchors in
      let payload = anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
      latestAnchors[windowId] = payload
      sendAnchors(windowId, payload)
    }
    SettingsJS.shared.onConnect {
      latestAnchors = latestAnchors.filter { SidebarAddressBars.shared.existing($0.key) != nil }
      for (windowId, payload) in latestAnchors { sendAnchors(windowId, payload) }
    }
  }

  private static func sendAnchors(_ windowId: String, _ payload: [String: [CGFloat]]) {
    Task { @MainActor in _ = await SettingsAdapters.js("sidebar.addressAnchors", windowId, payload) }
  }
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
    guard let host = NativeToolbarHostView.host(windowId: windowId, tabId: tabId), let state = host.toolbar.state else { return nil }
    return ["tabId": state.tabId, "hidden": host.isHiddenOrHasHiddenAncestor,
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
      guard let host = NativeToolbarHostView.host(windowId: windowId, tabId: tabId), let state = host.toolbar.state else { continue }
      rows.append(["tabId": state.tabId, "bare": state.bare, "urlHost": state.url.map { $0.host as Any } ?? NSNull()])
    }
    return rows
  }
}
#endif
