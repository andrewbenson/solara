import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativePeek {
  static let topic = "peek.state"
  private static var started = false
  private static var hosts: [String: PeekHost] = [:]

  nonisolated static var enabled: Bool { NativeSplitChrome.panesEnabled }

  static func start() {
    guard enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  private static func apply(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, host) in hosts where windows[windowId] == nil {
      host.end()
      hosts[windowId] = nil
    }
    for (windowId, json) in windows {
      guard let json = json as? String else { continue }
      if json.isEmpty, hosts[windowId] == nil { continue }
      guard let shell = NativeWindowShell.host(windowId)?.shell else { continue }
      let host = hosts[windowId].flatMap { $0.shell === shell ? $0 : nil } ?? replace(windowId, shell)
      host.apply(json)
    }
  }

  private static func replace(_ windowId: String, _ shell: WindowShellView) -> PeekHost {
    hosts[windowId]?.end()
    let host = PeekHost(windowId: windowId, shell: shell)
    hosts[windowId] = host
    return host
  }

  static func presentationChanged(_ windowId: String, fullscreenTabId: String?) {
    hosts[windowId]?.presentationChanged(fullscreenTabId)
  }

  static func windowEnded(_ windowId: String) {
    hosts.removeValue(forKey: windowId)?.end()
  }

  static func backdropChanged(_ windowId: String) {
    hosts[windowId]?.refreshBackdrop()
  }

  static func close(_ windowId: String) -> Bool {
    guard let host = hosts[windowId], host.view.state != nil else { return false }
    host.view.close()
    return true
  }

  static func expand(_ windowId: String, _ done: @escaping () -> Void) {
    guard let host = hosts[windowId], host.view.state != nil else { return done() }
    host.view.expandToTab(done)
  }

  static func paneFrame(_ windowId: String, in shell: WindowShellView) -> CGRect? {
    guard let host = hosts[windowId], host.view.window === shell.window, host.view.superview != nil else { return nil }
    return host.view.convert(host.view.bounds, to: shell)
  }

  static func sample(_ windowId: String) -> [String: Any]? {
    guard let host = hosts[windowId] else { return nil }
    return [
      "mounted": host.shell?.view(in: .peek) === host.view,
      "tabId": host.view.state?.tabId ?? NSNull(),
      "slot": TabSlots.shared.container(for: .peek(windowId)) === host.view.pageSlot,
      "backdrop": !host.view.backdropSlot.subviews.isEmpty,
    ]
  }
}

@MainActor
final class PeekHost {
  let windowId: String
  let view = PeekOverlayView(frame: .zero)
  private(set) weak var shell: WindowShellView?
  private var latestJSON = ""
  private var fullscreenTabId: String?

  init(windowId: String, shell: WindowShellView) {
    self.windowId = windowId
    self.shell = shell
    view.onEvent = { [windowId] event in
      Task { @MainActor in _ = await SettingsAdapters.js("peek.event", windowId, PeekOverlayView.eventJSON(event)) }
    }
  }

  func apply(_ json: String) {
    latestJSON = json
    guard let shell else { return }
    if json.isEmpty {
      view.clear()
      unmount()
      return
    }
    if shell.view(in: .peek) !== view {
      shell.mount(.peek, view)
      refreshBackdrop()
    }
    TabSlots.shared.set(.peek(windowId), container: view.pageSlot)
    if NativeWindowShell.nativeLayoutActive(windowId),
      let data = json.data(using: .utf8), var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      let tabId = value["tabId"] as? String
      value["fullscreen"] = tabId != nil && tabId == fullscreenTabId
      view.isHidden = fullscreenTabId != nil && tabId != fullscreenTabId
      if let encoded = try? JSONSerialization.data(withJSONObject: value), let next = String(data: encoded, encoding: .utf8) { view.apply(json: next) }
    } else {
      view.apply(json: json)
    }
    shell.coverChanged()
  }

  func presentationChanged(_ fullscreenTabId: String?) {
    guard self.fullscreenTabId != fullscreenTabId else { return }
    self.fullscreenTabId = fullscreenTabId
    if !latestJSON.isEmpty { apply(latestJSON) }
  }

  func refreshBackdrop() {
    view.backdropSlot.subviews.forEach { $0.removeFromSuperview() }
    guard let backdrop = NativeWindowShell.host(windowId)?.makeBackdrop() else { return }
    backdrop.frame = view.backdropSlot.bounds
    backdrop.autoresizingMask = [.width, .height]
    view.backdropSlot.addSubview(backdrop)
  }

  func end() {
    view.clear()
    unmount()
  }

  private func unmount() {
    TabSlots.shared.remove(.peek(windowId), container: view.pageSlot)
    if let shell, shell.view(in: .peek) === view { shell.mount(.peek, nil) }
  }
}
