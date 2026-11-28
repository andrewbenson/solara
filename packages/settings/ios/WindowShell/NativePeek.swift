import AppKit
import Foundation
import SolaraShell
import SolaraUI
import SolaraModel
import SolaraStore

@MainActor
enum NativePeek {
  private static var started = false
  private static var hosts: [String: PeekHost] = [:]

  private struct Load {
    let tabId: String
    let identity: PageIdentity
    var progress: Double?
    var insecure: Bool?
    var loading = false
    var loaded = false
  }

  private static var loads: [String: Load] = [:]

  static func start() {
    guard !started else { return }
    started = true
    PageIssuer.lifecycleObservers.append { issuer, binding, name, payload in
      guard ["onNavigationChange", "onProgress", "onSecurity", "onLoadError"].contains(name),
        NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === issuer.store,
        let tab = issuer.store.state.tabs[binding.tabId],
        issuer.store.state.peeks[tab.windowId]?.tabId == tab.id else { return }
      let windowId = tab.windowId
      var load = loads[windowId].flatMap { $0.identity == binding.identity ? $0 : nil } ?? Load(tabId: tab.id, identity: binding.identity)
      switch name {
      case "onProgress":
        if let progress = payload["progress"]?.number, progress.isFinite { load.progress = min(1, max(0, progress)) }
      case "onSecurity":
        load.insecure = ["warning", "dangerous"].contains(payload["chromium"]?.string ?? "")
      default:
        if issuer.store.state.live[tab.id]?.isLoading == true {
          load.loading = true
        } else if load.loading, !load.loaded {
          load.loaded = true
          if !issuer.store.memory.isDismissingPeek(windowId) { ShellHaptics.tick() }
        }
      }
      loads[windowId] = load
      issuer.afterIngress { NativeWindowShell.host(windowId)?.scheduleLayoutProjection() }
    }
    _ = PageRegistry.shared.observe { event in
      guard case .retired(let registration) = event,
        let window = loads.first(where: {
          $0.value.tabId == registration.tabID && $0.value.identity.registrationGeneration == registration.registrationGeneration
        })?.key else { return }
      loads[window] = nil
    }
    PageIssuer.consumePeekEscape = { issuer, binding in
      let state = issuer.store.state
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === issuer.store,
        let tab = state.tabs[binding.tabId], let peek = state.peeks[tab.windowId],
        peek.tabId == tab.id || peek.sourceId == tab.id, state.find[tab.id]?.json["open"]?.bool != true,
        state.windowUi[tab.windowId]?.panelOpen != true, NativeSelectionTools.popoverSnapshot()[tab.id] == nil else { return false }
      issuer.afterIngress {
        guard issuer.isCurrent(binding) else { return }
        if !NativeTileFolders.close(in: tab.windowId) { action(tab.windowId, tabId: peek.tabId, action: "dismiss") }
      }
      return true
    }
  }

  static func install(_ state: BrowserState, shell: WindowShellView, fullscreenTabId: String?) {
    let windowId = shell.windowId
    guard TabPoolHost.available, let window = state.windows[windowId] else { return }
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let fullscreen = state.peeks[windowId].map { $0.tabId == fullscreenTabId } ?? false
    if loads[windowId]?.tabId != state.peeks[windowId]?.tabId { loads[windowId] = nil }
    let load = loads[windowId]
    let next = PeekState.native(state: state, windowId: windowId, card: shell.railFraction > 0 ? shell.frames.page : shell.frames.card, tokens: look.tokens, dark: look.dark,
      fullscreen: fullscreen, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, progress: load?.progress, insecure: load?.insecure)
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
    loads[windowId] = nil
  }

  static func backdropChanged(_ windowId: String) {
    hosts[windowId]?.refreshBackdrop()
  }

  @discardableResult
  static func action(_ windowId: String, tabId: String, action: String) -> Bool {
    guard let store = WorkspaceWrites.store, !store.memory.closingWindows.contains(windowId),
      let peek = store.state.peeks[windowId], peek.tabId == tabId else { return false }
    let host = hosts[windowId].flatMap { $0.view.state?.tabId == tabId ? $0 : nil }
    switch action {
    case "beginClose":
      return beginClose(store, windowId: windowId, tabId: tabId)
    case "dismiss":
      if let host {
        guard host.view.canDismiss, beginClose(store, windowId: windowId, tabId: tabId) else { return false }
        host.dismiss(tabId)
      } else {
        finishClose(store, windowId: windowId, sourceId: peek.sourceId, tabId: tabId)
      }
    case "closed":
      finishClose(store, windowId: windowId, sourceId: peek.sourceId, tabId: tabId)
    case "expand":
      if let host {
        host.view.expandToTab(expectedTabId: tabId) { [weak host] accepted in
          guard accepted, let host, hosts[windowId] === host else { return }
          Self.action(windowId, tabId: tabId, action: "promote")
        }
      } else {
        return Self.action(windowId, tabId: tabId, action: "promote")
      }
    case "promote", "split":
      return promote(store, windowId: windowId, peek: peek, split: action == "split")
    case "closeFind":
      guard store.state.find[tabId]?.json["open"]?.bool == true else { return false }
      _ = try? store.dispatch(Command("setFind", [.string(tabId), ["open": false, "count": .null, "active": 0]]), origin: .native)
      NativeWorkspaceCommands.restoreContentFocus(windowId: windowId, store: store, tabId: tabId, stopFinding: true)
    default:
      return false
    }
    return true
  }

  private static func beginClose(_ store: Store, windowId: String, tabId: String) -> Bool {
    (try? store.transact { session in session.result = .bool(session.beginPeekDismissal(windowId, tabId: tabId)) })?.result?.bool == true
  }

  private static func finishClose(_ store: Store, windowId: String, sourceId: String, tabId: String) {
    _ = try? store.dispatch(Command("closePeek", [.string(windowId), .string(tabId)]), origin: .native)
    guard hosts[windowId] == nil, store.state.activeTabId(windowId) == sourceId else { return }
    NativeWorkspaceCommands.restoreContentFocus(windowId: windowId, store: store, tabId: sourceId)
  }

  private static func promote(_ store: Store, windowId: String, peek: Peek, split: Bool) -> Bool {
    guard !store.memory.isDismissingPeek(windowId) else { return false }
    if split, (Splits.splitOf(store.state, peek.sourceId)?.tabIds.count ?? 0) >= Splits.maxPanes { return false }
    let identity = PageIssuer.shared?.binding(tabId: peek.tabId)?.identity
    let commit = try? store.transact { session in
      guard let id = session.peekToTab(windowId, activate: !split, tabId: peek.tabId) else { return }
      if split {
        var options = Session.OpenPaneOptions()
        options.tabId = id
        options.anchorTabId = peek.sourceId
        options.side = "right"
        if session.openSplitPane(windowId, options)["ok"]?.bool != true { session.activate(id) }
      }
      session.result = .string(id)
    }
    guard let id = commit?.result?.string else { return false }
    if !split { ShellHaptics.tick() }
    FrameUpdates.flush()
    if store.state.activeTabId(windowId) == id, PageIssuer.shared?.binding(tabId: id)?.identity == identity {
      NativeWorkspaceCommands.restoreContentFocus(windowId: windowId, store: store, tabId: id)
    }
    return true
  }

  static func anchors(_ windowId: String) -> [String: CGRect] {
    guard let host = hosts[windowId], let shell = host.shell, host.view.state != nil else { return [:] }
    host.view.layoutNativeContentIfNeeded()
    return ["peekPage": host.view.pageSlot.convert(host.view.pageSlot.bounds, to: shell)]
  }

  static func paneFrame(_ windowId: String, in shell: WindowShellView) -> CGRect? {
    guard let host = hosts[windowId], host.view.window === shell.window, host.view.superview != nil else { return nil }
    return host.view.convert(host.view.bounds, to: shell)
  }

  static func pagePlacementReady(_ windowId: String, tabId: String?, shell: WindowShellView) -> Bool {
    guard let tabId else { return hosts[windowId]?.view.state == nil }
    guard let host = hosts[windowId], host.shell === shell, host.view.state?.tabId == tabId,
      shell.view(in: .peek) === host.view, !host.view.needsLayout else { return false }
    return TabSlots.shared.container(for: .peek(windowId)) === host.view.pageSlot
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
  private var fullscreenTabId: String?
  private var eventGeneration: UInt64 = 0
  private var sourceId: String?
  private var dismissing: String?

  init(windowId: String, shell: WindowShellView) {
    self.windowId = windowId
    self.shell = shell
    view.onEvent = { [weak self] event in
      guard let self, let tabId = self.view.state?.tabId else { return }
      if event == .dismiss {
        NativePeek.action(windowId, tabId: tabId, action: "dismiss")
        return
      }
      let receipt = self.eventGeneration
      Task { @MainActor [weak self] in
        guard let self, self.eventGeneration == receipt, self.view.state?.tabId == tabId else { return }
        switch event {
        case .dismiss: break
        case .openAsTab: NativePeek.action(windowId, tabId: tabId, action: "expand")
        case .openInSplit: NativePeek.action(windowId, tabId: tabId, action: "split")
        case .closed(let closed):
          guard closed == tabId else { return }
          self.dismissing = nil
          NativePeek.action(windowId, tabId: tabId, action: "closed")
        }
      }
    }
  }

  func apply(_ next: PeekState?, sourceId: String?) {
    guard let next, let shell else {
      if view.state != nil { eventGeneration += 1 }
      let responder = view.window?.firstResponder as? NSView
      let returnFocus = responder.map { $0 === view || $0.isDescendant(of: view) } ?? false
      dismissing = nil
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
    if view.state == next, shell.view(in: .peek) === view {
      TabSlots.shared.set(.peek(windowId), container: view.pageSlot)
      view.layoutNativeContentIfNeeded()
      return
    }
    if view.state?.tabId != next.tabId { eventGeneration += 1 }
    if shell.view(in: .peek) !== view {
      shell.mount(.peek, view)
      refreshBackdrop()
    }
    view.apply(next)
    TabSlots.shared.set(.peek(windowId), container: view.pageSlot)
    shell.coverChanged()
  }

  func dismiss(_ tabId: String) {
    dismissing = tabId
    view.close(expectedTabId: tabId)
  }

  func presentationChanged(_ fullscreenTabId: String?) {
    self.fullscreenTabId = fullscreenTabId
    view.isHidden = fullscreenTabId != nil && view.state?.tabId != fullscreenTabId
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
    if let dismissing { NativePeek.action(windowId, tabId: dismissing, action: "closed") }
  }

  private func unmount() {
    TabSlots.shared.remove(.peek(windowId), container: view.pageSlot)
    if let shell, shell.view(in: .peek) === view { shell.mount(.peek, nil) }
  }
}
