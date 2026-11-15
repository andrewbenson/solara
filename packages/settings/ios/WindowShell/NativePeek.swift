import AppKit
import Foundation
import SolaraUI
import SolaraModel
import SolaraStore

@MainActor
enum NativePeek {
  static let topic = "peek.state"
  private static var started = false
  private static var hosts: [String: PeekHost] = [:]

  nonisolated static var enabled: Bool { NativeSplitChrome.panesEnabled }

  static func start() {
    guard enabled, !started else { return }
    started = true
    if NativeWindowShell.nativeLayout {
      TabPoolHost.shared.pageEventObservers.append { tabId, _, _ in
        guard let windowId = TabPoolHost.shared.windowOf(tabId), NativeWindowShell.nativeLayoutActive(windowId) else { return }
        NativeWindowShell.host(windowId)?.scheduleLayoutProjection()
      }
      return
    }
    _ = SettingsJS.shared.observe(topic) { value in apply(value) }
    apply(SettingsJS.shared.latestValue(topic))
  }

  private static func apply(_ value: Any?) {
    guard !NativeWindowShell.nativeLayout else { return }
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

  static func install(_ state: BrowserState, shell: WindowShellView, fullscreenTabId: String?) {
    let windowId = shell.windowId
    guard NativeWindowShell.nativeLayoutActive(windowId), let window = state.windows[windowId] else { return }
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let fullscreen = state.peeks[windowId].flatMap { NativeStoreHandle.store?.pageFacts($0.tabId)?.keepAlive?.reveal.fullscreen } ?? false
    let next = PeekState.native(state: state, windowId: windowId, card: shell.railFraction > 0 ? shell.frames.page : shell.frames.card, tokens: look.tokens, dark: look.dark,
      fullscreen: fullscreen, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    if next == nil, hosts[windowId] == nil { return }
    let host = hosts[windowId].flatMap { $0.shell === shell ? $0 : nil } ?? replace(windowId, shell)
    host.presentationChanged(fullscreenTabId)
    host.apply(next, sourceId: state.peeks[windowId]?.sourceId)
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

  static func close(_ windowId: String, tabId: String, generation: UInt64) -> Bool {
    guard controlMatches(windowId, tabId: tabId, generation: generation), let host = hosts[windowId] else { return false }
    host.view.close(expectedTabId: tabId)
    return true
  }

  static func expand(_ windowId: String, tabId: String, generation: UInt64, _ done: @escaping (Bool) -> Void) {
    guard controlMatches(windowId, tabId: tabId, generation: generation), let host = hosts[windowId] else { return done(false) }
    host.view.expandToTab(expectedTabId: tabId, done)
  }

  private static func controlMatches(_ windowId: String, tabId: String, generation: UInt64) -> Bool {
    guard hosts[windowId]?.view.state?.tabId == tabId, NativeWindowShell.nativeLayoutGeneration(windowId) == generation else { return false }
    return !NativeStoreHandle.ownedWorkspaceAtLaunch || NativeStoreHandle.store?.state.peeks[windowId]?.tabId == tabId
  }

  static func anchors(_ windowId: String) -> [String: CGRect] {
    guard let host = hosts[windowId], let shell = host.shell, host.view.state != nil else { return [:] }
    host.view.layoutSubtreeIfNeeded()
    return ["peekPage": host.view.pageSlot.convert(host.view.pageSlot.bounds, to: shell)]
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
  private var eventGeneration: UInt64 = 0
  private var sourceId: String?

  init(windowId: String, shell: WindowShellView) {
    self.windowId = windowId
    self.shell = shell
    view.onEvent = { [weak self] event in
      guard let self, let tabId = self.view.state?.tabId else { return }
      let receipt = self.eventGeneration
      Task { @MainActor [weak self] in
        guard let self, self.eventGeneration == receipt, self.view.state?.tabId == tabId,
          !NativeWindowShell.nativeLayoutActive(windowId) || NativeStoreHandle.store?.state.peeks[windowId]?.tabId == tabId else { return }
        var payload = PeekOverlayView.eventJSON(event)
        payload["tabId"] = tabId
        _ = await SettingsAdapters.js("peek.event", windowId, payload)
      }
    }
  }

  func apply(_ next: PeekState?, sourceId: String?) {
    guard let next, let shell else {
      if view.state != nil { eventGeneration += 1 }
      let responder = view.window?.firstResponder as? NSView
      let returnFocus = responder.map { $0 === view || $0.isDescendant(of: view) } ?? false
      view.clear()
      unmount()
      if returnFocus, let shell, !shell.modalShown, let sourceId = self.sourceId,
        NativeStoreHandle.store?.state.activeTabId(windowId) == sourceId,
        let page = TabPoolHost.shared.pageView(sourceId), page.window === shell.window {
        shell.window?.makeFirstResponder(page)
      }
      self.sourceId = nil
      return
    }
    self.sourceId = sourceId
    view.isHidden = fullscreenTabId != nil && next.tabId != fullscreenTabId
    if view.state == next, shell.view(in: .peek) === view { return }
    if view.state?.tabId != next.tabId { eventGeneration += 1 }
    if shell.view(in: .peek) !== view {
      shell.mount(.peek, view)
      refreshBackdrop()
    }
    view.apply(next)
    TabSlots.shared.set(.peek(windowId), container: view.pageSlot)
    shell.coverChanged()
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
    if NativeWindowShell.nativeLayoutActive(windowId) {
      view.isHidden = fullscreenTabId != nil && view.state?.tabId != fullscreenTabId
    } else if !latestJSON.isEmpty {
      apply(latestJSON)
    }
  }

  func refreshBackdrop() {
    view.backdropSlot.subviews.forEach { $0.removeFromSuperview() }
    guard let backdrop = NativeWindowShell.host(windowId)?.makeBackdrop() else { return }
    backdrop.frame = view.backdropSlot.bounds
    backdrop.autoresizingMask = [.width, .height]
    view.backdropSlot.addSubview(backdrop)
  }

  func end() {
    eventGeneration += 1
    view.clear()
    unmount()
  }

  private func unmount() {
    TabSlots.shared.remove(.peek(windowId), container: view.pageSlot)
    if let shell, shell.view(in: .peek) === view { shell.mount(.peek, nil) }
  }
}
