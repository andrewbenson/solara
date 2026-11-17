import AppKit
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI
import Synchronization
import React

@MainActor
enum NativePaneRoots {
  nonisolated static var enabled: Bool {
    NativeWindowShell.enabled && LaunchSwitches.shared.isOn(.shellPanes)
  }

  nonisolated static var available: Bool { enabled && WindowHost.makeRootView != nil }

  nonisolated static func active(_ windowId: String) -> Bool { available && NativeWindowShell.active(windowId) }

  static var refusedTabs: Set<String> = []
  static var lateTeardown: TimeInterval = 0

  private static var hosts: [String: PaneRootsHost] = [:]
  private static var slotsObserver: NSObjectProtocol?
  private static var retiredFallbacks: [ObjectIdentifier: PaneFallbackTarget] = [:]
  nonisolated private static let fallbackSnapshots = Mutex<[String: String]>([:])
  nonisolated private static let announcedFallbacks = Mutex(PaneGuestAnnouncements())

  nonisolated static func forgetFallbackEpoch(_ generation: UInt64) {
    announcedFallbacks.withLock { $0.remove(generation) }
  }

  nonisolated static func fallbackState(_ windowId: String) -> String {
    fallbackSnapshots.withLock { $0[windowId] ?? "{}" }
  }

  nonisolated static func admitFallbackSnapshot(_ windowId: String, windowGeneration: UInt64, revision: UInt64) -> String {
    fallbackSnapshots.withLock { snapshots in
      guard let json = snapshots[windowId], let data = json.data(using: .utf8),
        let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (snapshot["windowGeneration"] as? NSNumber)?.uint64Value == windowGeneration,
        (snapshot["revision"] as? NSNumber)?.uint64Value == revision else { return "{}" }
      guard var targets = snapshot["targets"] as? [String: [String: Any]] else { return "{}" }
      announcedFallbacks.withLock { announcements in
        for (tabId, original) in targets {
          var target = original
          guard let generation = (target["targetGeneration"] as? NSNumber)?.uint64Value else { continue }
          target["lease"] = announcements.acquire(generation)
          targets[tabId] = target
        }
      }
      var acquired = snapshot
      acquired["targets"] = targets
      guard let data = try? JSONSerialization.data(withJSONObject: acquired) else { return "{}" }
      return String(decoding: data, as: UTF8.self)
    }
  }

  nonisolated static func fallbackSnapshot(_ windowId: String) -> String { fallbackState(windowId) }

  static func publishFallbacks(_ windowId: String, host: PaneRootsHost, snapshot: [String: Any]) {
    guard hosts[windowId] === host, let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
    fallbackSnapshots.withLock { $0[windowId] = String(decoding: data, as: UTF8.self) }
    Task { @MainActor in
      guard hosts[windowId] === host, host.admitsFallbackPublication(snapshot["revision"] as? UInt64 ?? 0) else { return }
      _ = try? await SettingsJS.shared.invoke("pane.fallbackTargets", [windowId, snapshot], timeout: 5)
    }
  }

  static func retireFallback(_ target: PaneFallbackTarget) {
    guard !target.lifetime.ended else { target.invalidate(); return }
    let key = ObjectIdentifier(target)
    retiredFallbacks[key] = target
    let announced = fallbackSnapshots.withLock { snapshots in
      if let json = snapshots[target.windowId], let data = json.data(using: .utf8),
        let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let targets = snapshot["targets"] as? [String: [String: Any]],
        (targets[target.tabId]?["targetGeneration"] as? NSNumber)?.uint64Value == target.lifetime.generation {
        snapshots[target.windowId] = nil
      }
      return announcedFallbacks.withLock { announcements in
        target.lifetime.generations.filter { announcements.contains($0) }
      }
    }
    for generation in announced { target.lifetime.announce(generation: generation) }
    target.lifetime.onEnd = { [weak target] in
      guard let target else { return }
      retiredFallbacks[key] = nil
      target.invalidate()
    }
    target.lifetime.retire()
  }

  static func releaseFallback(_ windowId: String, tabId: String, generation: UInt64, lease: UInt64) {
    guard announcedFallbacks.withLock({ $0.reject(generation, ticket: lease) }) else { return }
    hosts[windowId]?.releaseFallback(tabId, generation: generation)
    for target in Array(retiredFallbacks.values) where target.windowId == windowId && target.tabId == tabId {
      target.lifetime.release(generation: generation)
    }
  }

  static func start(_ windowId: String, prepareSelected: Bool) -> PaneRootsHost? {
    guard available else { return nil }
    if slotsObserver == nil {
      slotsObserver = NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: nil, queue: .main) { note in
        guard let windowId = note.userInfo?["windowId"] as? String else { return }
        MainActor.assumeIsolated { hosts[windowId]?.refreshNextTurn() }
      }
    }
    hosts[windowId]?.stop()
    let host = PaneRootsHost(windowId: windowId)
    hosts[windowId] = host
    if prepareSelected { host.prepareSelected() }
    host.refresh()
    return host
  }

  static func end(_ windowId: String, ifHost host: PaneRootsHost) {
    guard hosts[windowId] === host else { return }
    host.stop()
    hosts[windowId] = nil
    fallbackSnapshots.withLock { $0[windowId] = nil }
  }

  static func sample(_ windowId: String) -> [String: Any]? { hosts[windowId]?.sample() }

  nonisolated static func storeChanged() {
    let schedule = storeRefresh.withLock { queued -> Bool in
      if queued { return false }
      queued = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        storeRefresh.withLock { $0 = false }
        for host in hosts.values { host.refresh() }
      }
    }
  }

  nonisolated private static let storeRefresh = Mutex<Bool>(false)
}

@MainActor
final class PaneRootsHost {
  let windowId: String
  private let roots: PaneRoots
  private var refreshQueued = false
  private var stopped = false
  private var appearances: [ObjectIdentifier: NSObjectProtocol] = [:]
  private var sizers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
  private var fallbacks: [String: PaneFallbackTarget] = [:]
  private var fallbackRevision: UInt64 = 0
  private var lastFallbackTargets: [String: [String: AnyHashable]] = [:]
  private let windowGeneration: UInt64

  init(windowId: String) {
    self.windowId = windowId
    windowGeneration = NativeWindowShell.nativeLayoutGeneration(windowId)
    let container: (String) -> NSView? = { tabId in PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .rn) }
    var made: ((String, NSView) -> Void)?
    roots = PaneRoots(
      windowId: windowId,
      makeRoot: { tabId in
        guard !NativePaneRoots.refusedTabs.contains(tabId), let root = WindowHost.makeRootView?("pane", Self.props(windowId, tabId, shown: false))
        else { return nil }
        if root.responds(to: Selector(("setPassThroughTouches:"))) { root.setValue(true, forKey: "passThroughTouches") }
        if root.responds(to: Selector(("setBackgroundColor:"))) { root.setValue(nil, forKey: "backgroundColor") }
        made?(tabId, root)
        return root
      },
      container: container
    )
    made = { [weak self] tabId, root in self?.observe(tabId, root) }
    roots.onShown = { tabId, root, shown in Self.setProps(root, Self.props(windowId, tabId, shown: shown)) }
    roots.onEnd = { [weak self] tabId, root in
      self?.forget(root)
      Self.setProps(root, Self.props(windowId, tabId, shown: false))
      guard NativePaneRoots.lateTeardown > 0 else { return Self.unmount(root) }
      DispatchQueue.main.asyncAfter(deadline: .now() + NativePaneRoots.lateTeardown) { MainActor.assumeIsolated { Self.unmount(root) } }
    }
  }

  private static func props(_ windowId: String, _ tabId: String, shown: Bool) -> [String: Any] {
    ["windowId": windowId, "tabId": tabId, "shown": shown]
  }

  private static func setProps(_ root: NSView, _ props: [String: Any]) {
    guard root.responds(to: Selector(("setAppProperties:"))) else { return }
    root.setValue(props, forKey: "appProperties")
  }

  func prepareSelected() {
    guard !stopped, let state = NativeStoreHandle.store?.displayState,
      let window = state.windows[windowId], let active = state.activeTabId(windowId) else { return }
    let selected = Set(Splits.splitOf(state, active)?.tabIds ?? [active])
    roots.update(visible: selected, open: Set(window.tabIds))
  }

  func refresh() {
    guard !stopped else { return }
    guard let window = NativeStoreHandle.store?.displayState.windows[windowId] else { return }
    let open = Set(window.tabIds)
    let windowId = windowId
    let visible = open.filter { tabId in
      guard let slot = PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .rn) else { return false }
      return !slot.isHiddenOrHasHiddenAncestor
    }
    roots.update(visible: visible, open: open)
    refreshFallbacks(visible: visible, open: open)
  }

  private func refreshFallbacks(visible: Set<String>, open: Set<String>) {
    guard windowGeneration > 0 else { return }
    for id in Array(fallbacks.keys) where !open.contains(id) || !visible.contains(id) || roots.root(id).map({ !$0.isHidden }) == true {
      guard let target = fallbacks.removeValue(forKey: id) else { continue }
      forget(target.root)
      target.root.removeFromSuperview()
      NativePaneRoots.retireFallback(target)
    }
    for id in visible where roots.root(id) == nil {
      guard fallbacks[id] == nil else { continue }
      guard let root = WindowHost.makeRootView?("paneFallbackSlot", [:]),
        root.responds(to: Selector(("reactTag"))), let tag = root.value(forKey: "reactTag") as? NSNumber else { continue }
      if root.responds(to: Selector(("setPassThroughTouches:"))) { root.setValue(true, forKey: "passThroughTouches") }
      if root.responds(to: Selector(("setBackgroundColor:"))) { root.setValue(nil, forKey: "backgroundColor") }
      fallbacks[id] = PaneFallbackTarget(windowId: windowId, tabId: id, root: root, rootTag: tag)
      observe(id, root)
    }
    for (id, target) in fallbacks {
      let primaryShown = roots.root(id).map { !$0.isHidden } ?? false
      let shown = visible.contains(id) && !primaryShown
      target.lifetime.setShown(shown)
      target.root.isHidden = !shown
      if let into = PaneOverlays.shared.container(windowId: windowId, tabId: id, layer: .rn) {
        if target.root.superview !== into { into.addSubview(target.root, positioned: .below, relativeTo: nil) }
        target.root.autoresizingMask = [.width, .height]
        target.root.frame = into.bounds
      }
    }
    publishFallbacks()
  }

  private func publishFallbacks() {
    let targets = fallbacks.mapValues { target -> [String: AnyHashable] in
      ["rootTag": target.rootTag.intValue, "targetGeneration": target.lifetime.generation, "shown": target.lifetime.shown]
    }
    guard fallbackRevision == 0 || targets != lastFallbackTargets else { return }
    lastFallbackTargets = targets
    fallbackRevision += 1
    let encoded = targets.mapValues { $0.mapValues(\.base) }
    NativePaneRoots.publishFallbacks(windowId, host: self,
      snapshot: ["windowGeneration": windowGeneration, "revision": fallbackRevision, "targets": encoded])
  }

  func admitsFallbackPublication(_ revision: UInt64) -> Bool { revision == fallbackRevision }

  func releaseFallback(_ tabId: String, generation: UInt64) {
    fallbacks[tabId]?.lifetime.release(generation: generation)
  }

  fileprivate static func unmount(_ root: NSView) {
    guard root.responds(to: Selector(("contentView"))), let content = root.value(forKey: "contentView") as? NSObject else { return }
    let invalidate = NSSelectorFromString("invalidate")
    if content.responds(to: invalidate) { content.perform(invalidate) }
  }

  func refreshNextTurn() {
    guard !stopped, !refreshQueued else { return }
    refreshQueued = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        self.refreshQueued = false
        self.refresh()
      }
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    roots.stop()
    for target in fallbacks.values {
      forget(target.root)
      target.root.removeFromSuperview()
      NativePaneRoots.retireFallback(target)
    }
    fallbacks = [:]
    publishFallbacks()
  }

  func sample() -> [String: Any] {
    var out: [String: Any] = [:]
    for tabId in roots.tabIds {
      let root = roots.root(tabId)
      let content = root?.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }
      out[tabId] = [
        "hidden": root?.isHidden ?? true, "retiring": roots.isRetiring(tabId), "inSlot": root?.superview != nil,
        "size": root.map { [$0.bounds.width, $0.bounds.height] } ?? [], "content": content.map { [$0.frame.width, $0.frame.height] } ?? [],
      ]
    }
    return out
  }

  private func observe(_ tabId: String, _ root: NSView) {
    let appeared = NotificationCenter.default.addObserver(
      forName: Notification.Name("RCTContentDidAppearNotification"), object: root, queue: .main
    ) { [weak self, weak root] _ in
      MainActor.assumeIsolated {
        guard let self, !self.stopped, let root, self.roots.root(tabId) === root || self.fallbacks[tabId]?.root === root else { return }
        self.roots.contentAppeared(tabId, root: root)
        self.keepSized(root)
        self.refresh()
      }
    }
    appearances[ObjectIdentifier(root)] = appeared
  }

  private func keepSized(_ root: NSView) {
    for old in sizers.removeValue(forKey: ObjectIdentifier(root)) ?? [] { NotificationCenter.default.removeObserver(old) }
    guard let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    let fit: @MainActor () -> Void = { [weak root, weak content] in
      guard let root, let content, content.superview === root, !root.bounds.isEmpty, content.frame.size != root.bounds.size else { return }
      root.needsLayout = true
      content.needsLayout = true
    }
    root.postsFrameChangedNotifications = true
    content.postsFrameChangedNotifications = true
    sizers[ObjectIdentifier(root)] = [root, content].map { view in
      NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
        MainActor.assumeIsolated { fit() }
      }
    }
    fit()
  }

  private func forget(_ root: NSView) {
    for token in [appearances.removeValue(forKey: ObjectIdentifier(root))].compactMap({ $0 }) + (sizers.removeValue(forKey: ObjectIdentifier(root)) ?? []) {
      NotificationCenter.default.removeObserver(token)
    }
  }
}


@MainActor
final class PaneFallbackTarget {
  let windowId: String
  let tabId: String
  let root: NSView
  let rootTag: NSNumber
  let lifetime = PaneGuestLifetime()
  private var bridgeObserver: NSObjectProtocol?
  private var invalidated = false

  init(windowId: String, tabId: String, root: NSView, rootTag: NSNumber) {
    self.windowId = windowId
    self.tabId = tabId
    self.root = root
    self.rootTag = rootTag
    if root.responds(to: Selector(("bridge"))), let bridge = root.value(forKey: "bridge") as? RCTBridge {
      bridgeObserver = NotificationCenter.default.addObserver(forName: .RCTBridgeWillBeInvalidated, object: bridge, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.lifetime.abandon() }
      }
    }
    lifetime.onEnd = { [weak self] in self?.invalidate() }
  }

  func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    for generation in lifetime.generations { NativePaneRoots.forgetFallbackEpoch(generation) }
    if let bridgeObserver { NotificationCenter.default.removeObserver(bridgeObserver) }
    bridgeObserver = nil
    guard root.responds(to: Selector(("bridge"))), let bridge = root.value(forKey: "bridge") as? RCTBridge, bridge.isValid,
      let manager = bridge.uiManager, let queue = RCTGetUIManagerQueue() else { return }
    let queuedRoot = root
    nonisolated(unsafe) let queuedManager = manager
    queue.async {
      queuedManager.addUIBlock { _, _ in
        MainActor.assumeIsolated { PaneRootsHost.unmount(queuedRoot) }
      }
      queuedManager.setNeedsLayout()
    }
  }
}
