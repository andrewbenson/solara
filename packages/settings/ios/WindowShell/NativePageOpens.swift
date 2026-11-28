import Foundation
import SolaraCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

@MainActor
enum NativePageOpens {
  @MainActor
  private struct Receipt {
    let source: PageOpenSource
    let identity: PageIdentity
    let documentRevision: Int

    init?(_ issuer: PageIssuer, _ binding: PageHostBinding) {
      let store = issuer.store
      guard let source = store.sequence({
        issuer.isCurrent(binding) ? PageOpenSource(state: store.state, memory: store.memory, tabId: binding.tabId) : nil
      }) else { return nil }
      self.source = source
      identity = binding.identity
      documentRevision = binding.documentRevision
    }

    func isCurrent(_ issuer: PageIssuer) -> Bool {
      guard WorkspaceWrites.store === issuer.store, PageIssuer.shared === issuer,
        let binding = issuer.binding(identity: identity), binding.documentRevision == documentRevision,
        issuer.isCurrent(binding) else { return false }
      let store = issuer.store
      return store.sequence { PageOpenSource(state: store.state, memory: store.memory, tabId: source.tabId) == source }
    }
  }

  private struct Pending {
    let receipt: Receipt
    let url: String
    let disposition: String
    let expires: TimeInterval
  }

  private static var lifecycle: Int?
  private static weak var store: Store?
  private static var subscription: Int?
  private static var sources: [String] = []
  private static var modifiers: [String] = []
  private static var pending: [String: Pending] = [:]
  private static var seen: [String: TimeInterval] = [:]
  private static let consumer = "workspace-pinned-links"

  static func start() {
    guard lifecycle == nil else { return }
    PageIssuer.consumePageOpen = { issuer, binding, request in
      guard let receipt = Receipt(issuer, binding) else { return }
      issuer.afterIngress {
        open(receipt, request: request, issuer: issuer)
      }
    }
    PageIssuer.consumeLittleWindowEvent = { issuer, binding, event in
      let state = issuer.store.state
      guard let windowId = state.tabs[binding.tabId]?.windowId, state.windows[windowId]?.isSmall == true else { return false }
      guard let receipt = Receipt(issuer, binding) else { return true }
      issuer.afterIngress {
        guard receipt.isCurrent(issuer), issuer.store.state.activeTabId(windowId) == binding.tabId else { return }
        if event == "onWindowClose" {
          _ = NativeWorkspaceCommands.perform("closeWindow", windowId: windowId)
        } else {
          escape(receipt.source, store: issuer.store)
        }
      }
      return true
    }
    SolaraCoreWebView.setOpenWindowGuard { tabId in
      let check: (@Sendable () -> Bool)? = MainActor.assumeIsolated {
        guard let issuer = PageIssuer.shared, issuer.store.state.tabs[tabId] != nil else { return nil }
        guard let binding = issuer.binding(tabId: tabId), let receipt = Receipt(issuer, binding) else { return { false } }
        return { MainActor.assumeIsolated { receipt.isCurrent(issuer) } }
      }
      return check
    }
    lifecycle = NativeStoreHandle.subscribeLifecycle { reconcile() }
  }

  private static func escape(_ source: PageOpenSource, store: Store) {
    let windowId = source.windowId
    let tabId = source.tabId
    let command = LittleSolaraEscape.resolve(source, state: store.state, memory: store.memory,
      popup: NativeExtensionActionPopup.visibleWindowId == windowId, popover: NativeSelectionTools.popoverSnapshot()[tabId] != nil)
    switch command {
    case .popup:
      NativeExtensionActionPopup.close(windowId: windowId)
    case .popover:
      _ = NativeSelectionTools.setPopover(tabId, value: nil)
    case .panel:
      _ = try? store.dispatch(Command("closePanel", [.string(windowId)]), origin: .native)
    case .find:
      _ = try? store.dispatch(Command("setFind", [.string(tabId), ["open": false, "active": 0, "count": .null]]), origin: .native)
      NativeWorkspaceCommands.restoreContentFocus(windowId: windowId, store: store, tabId: tabId, stopFinding: true)
    case .window:
      _ = NativeWorkspaceCommands.perform("closeWindow", windowId: windowId)
    case nil:
      break
    }
  }

  private static func reconcile() {
    let next = WorkspaceWrites.store
    if store !== next {
      if let subscription { store?.unsubscribe(subscription) }
      store = next
      sources = []
      modifiers = []
      pending.removeAll()
      seen.removeAll()
      if next == nil {
        SolaraCoreWebView.clearPinnedLinkHandler(consumer)
      } else {
        SolaraCoreWebView.setPinnedLinkHandler({ event in MainActor.assumeIsolated { pinnedLink(event) } }, owner: consumer)
      }
      subscription = next?.subscribe { commit in
        let changes = commit.changes
        guard !changes.tabs.isEmpty || !changes.windows.isEmpty || changes.settings else { return }
        Task { @MainActor in sync() }
      }
    }
    sync()
  }

  private static func sync() {
    guard let store else { return }
    let state = store.state
    let nextModifiers = [state.settings.peekModifier, state.settings.splitLinkModifier]
    if modifiers != nextModifiers {
      modifiers = nextModifiers
      SolaraCoreWebView.setPeekModifier(modifiers[0])
      SolaraCoreWebView.setSplitLinkModifier(modifiers[1])
    }
    let nextSources = state.tabs.values.compactMap { tab -> String? in
      guard tab.pinned, let window = state.windows[tab.windowId], !window.isSmall, window.tabIds.contains(tab.id) else { return nil }
      return tab.id
    }.sorted()
    if sources != nextSources {
      sources = nextSources
      SolaraCoreWebView.setPinnedLinkSources(sources)
    }
  }

  private static func pinnedLink(_ event: [String: Any]) {
    guard let requestId = event["requestId"] as? String else { return }
    let now = ProcessInfo.processInfo.systemUptime
    pending = pending.filter { $0.value.expires > now }
    if event["phase"] as? String == "intercepted" {
      guard let decision = pending.removeValue(forKey: requestId), let issuer = PageIssuer.shared,
        (event["sourceURL"] as? String)?.jsBeforeFirst("#") == decision.receipt.source.page else { return }
      var request: JSONObject = ["url": .string(decision.url), "disposition": .string(decision.disposition)]
      if let point = event["point"] as? [String: NSNumber], let x = point["x"]?.doubleValue, let y = point["y"]?.doubleValue,
        x.isFinite, y.isFinite { request["point"] = ["x": .number(x), "y": .number(y)] }
      let captured = request
      Task { @MainActor in open(decision.receipt, request: captured, issuer: issuer, pinned: true) }
      return
    }
    guard event["phase"] as? String == "decide" else { return }
    seen = seen.filter { $0.value > now }
    guard seen[requestId] == nil else { return }
    seen[requestId] = now + 30
    if seen.count > 256, let oldest = seen.min(by: { $0.value < $1.value })?.key { seen[oldest] = nil }
    var intercept = false
    defer {
      if !SolaraCoreWebView.resolvePinnedLink(requestId, intercept: intercept) { pending[requestId] = nil }
    }
    guard pending.count < 128, pending[requestId] == nil, let issuer = PageIssuer.shared, store === issuer.store,
      let tabId = event["sourceId"] as? String, let binding = issuer.binding(tabId: tabId), let receipt = Receipt(issuer, binding),
      let tab = issuer.store.state.tabs[tabId], tab.pinned, let window = issuer.store.state.windows[tab.windowId], !window.isSmall,
      receipt.source.isVisible(in: issuer.store.state), let source = event["sourceURL"] as? String,
      source.jsBeforeFirst("#") == receipt.source.page, let url = event["url"] as? String,
      PinnedLinkPolicy.crossesSites(from: source, to: url) else { return }
    let target = issuer.store.state.settings["pinnedLinkTarget"]?.string
    let disposition = target == "littleSolara" && !window.incognito ? "littleSolara" : target == "tab" || target == "littleSolara" ? "foreground" : "peek"
    pending[requestId] = Pending(receipt: receipt, url: url, disposition: disposition, expires: now + 5)
    intercept = true
  }

  private static func open(_ receipt: Receipt, request: JSONObject, issuer: PageIssuer, pinned: Bool = false) {
    let store = issuer.store
    guard receipt.isCurrent(issuer), let rawURL = request["url"]?.string else { return }
    var options = request
    options["url"] = .string(toAppUrl(rawURL))
    let before = store.state
    guard (try? store.transact(origin: .engine, { $0.openFromPage(receipt.source, request: options, pinned: pinned) })) != nil else { return }
    NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
  }
}
