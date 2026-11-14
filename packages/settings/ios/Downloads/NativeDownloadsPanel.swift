import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeDownloadsPanel {
  static let topic = "downloads.panel"
  nonisolated static let kind = "downloadsPanel"
  nonisolated static let buttonKind = "downloadsButton"
  private static var started = false
  private static var panels: [String: DownloadsPanelView] = [:]
  #if DEBUG
    private static let hosted = NSMapTable<NSString, DownloadsPanelView>.strongToWeakObjects()
  #endif

  static func register() {
    HostedViews.register(kind) { windowId in
      let panel = DownloadsPanelView(frame: .zero)
      DownloadsHoverShifts.shown.add(panel.list)
      #if DEBUG
        hosted.setObject(panel, forKey: windowId as NSString)
      #endif
      let send: (String, [String: Any]) -> Void = { [weak panel] name, payload in
        var body = payload
        body["token"] = panel?.state?.token
        HostedViews.send(kind, windowId: windowId, name, body)
      }
      panel.onDismiss = { send("dismiss", [:]) }
      panel.onClosed = { send("closed", [:]) }
      panel.onEvent = { send("action", event($0)) }
      return HostedContent(view: panel, onUnmount: { panel.end() }, takesFocus: false, onState: { [weak panel] json in
        guard let state = DownloadsPanelState.decode(json) else { return }
        panel?.update(state)
      })
    }
    HostedViews.register(buttonKind) { windowId in
      let button = DownloadButtonView(frame: .zero)
      button.onPress = { [weak button] in HostedViews.send(buttonKind, windowId: windowId, "press", ["token": button?.token ?? NSNull()]) }
      return HostedContent(view: button, onUnmount: { button.end() }, takesFocus: false, onState: { [weak button] json in button?.apply(json: json) })
    }
  }

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  private static func apply(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, panel) in panels where windows[windowId] == nil {
      panel.end()
      panel.removeFromSuperview()
      panels[windowId] = nil
    }
    for (windowId, json) in windows {
      guard let json = json as? String, let state = DownloadsPanelState.decode(json), let overlay = NativeWindowShell.overlay(windowId) else { continue }
      let panel = panels[windowId] ?? make(windowId)
      if panel.superview !== overlay {
        panel.frame = overlay.bounds
        panel.autoresizingMask = [.width, .height]
        overlay.addSubview(panel)
      }
      panel.update(state)
    }
  }

  private static func make(_ windowId: String) -> DownloadsPanelView {
    let panel = DownloadsPanelView(frame: .zero)
    DownloadsHoverShifts.shown.add(panel.list)
    panel.onDismiss = { [weak panel] in send(windowId, ["kind": "dismiss", "token": panel?.state?.token ?? NSNull()]) }
    panel.onClosed = { [weak panel] in send(windowId, ["kind": "closed", "token": panel?.state?.token ?? NSNull()]) }
    panel.onEvent = { [weak panel] e in
      var body = event(e)
      body["token"] = panel?.state?.token
      send(windowId, body)
    }
    panels[windowId] = panel
    return panel
  }

  private static func event(_ value: DownloadsEvent) -> [String: Any] {
    let (kind, id): (String, String?) =
      switch value {
      case .open(let id): ("open", id)
      case .reveal(let id): ("reveal", id)
      case .pause(let id): ("pause", id)
      case .resume(let id): ("resume", id)
      case .keep(let id): ("keep", id)
      case .cancel(let id): ("cancel", id)
      case .menu(let id): ("menu", id)
      case .clear: ("clear", nil)
      case .viewAll: ("viewAll", nil)
      }
    return ["kind": kind, "id": id ?? NSNull()]
  }

  private static func send(_ windowId: String, _ event: [String: Any]) {
    Task { @MainActor in _ = await SettingsAdapters.js("downloads.panel", windowId, event) }
  }

  #if DEBUG
  static func describe(_ windowId: String) -> String {
    guard let info = read(windowId) else { return "null" }
    let data = try? JSONSerialization.data(withJSONObject: info)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  static func read(_ windowId: String) -> [String: Any]? {
    guard let panel = panels[windowId] ?? hosted.object(forKey: windowId as NSString), panel.superview != nil else { return nil }
    func inWindow(_ view: NSView, _ r: CGRect) -> [Double] {
      let w = view.convert(r, to: nil)
      let h = view.window?.contentView?.bounds.height ?? 0
      return [w.minX, h - w.maxY, w.width, w.height]
    }
    var controls: [String: [Double]] = [:]
    func walk(_ view: NSView) {
      if view.accessibilityRole() == .button, let name = view.accessibilityLabel(), !name.isEmpty { controls[name] = inWindow(view, view.bounds) }
      view.subviews.forEach(walk)
    }
    walk(panel.list)
    let info: [String: Any] = [
      "card": panel.cardFrame.map { inWindow(panel, $0) } ?? NSNull(), "list": inWindow(panel.list, panel.list.bounds), "opacity": panel.presentedOpacity,
      "progress": panel.progress, "closing": panel.isClosing, "controls": controls,
    ]
    return info
  }
  #endif
}

#if SOLARA_PROBES
@MainActor
public enum DownloadsPanelRead {
  public static func panel(windowId: String) -> [String: Any]? {
    guard var info = NativeDownloadsPanel.read(windowId) else { return nil }
    let controls = info["controls"] as? [String: [Double]] ?? [:]
    info["controls"] = controls.filter { ["View all downloads", "Clear"].contains($0.key) }
    return info
  }
}
#endif
