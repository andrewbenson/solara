import AppKit
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI
import Synchronization

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

  static func start(_ windowId: String) -> PaneRootsHost? {
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
    host.refresh()
    return host
  }

  static func end(_ windowId: String, ifHost host: PaneRootsHost) {
    guard hosts[windowId] === host else { return }
    hosts[windowId] = nil
    host.stop()
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
  private var appearances: [ObjectIdentifier: NSObjectProtocol] = [:]
  private var sizers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

  init(windowId: String) {
    self.windowId = windowId
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

  func refresh() {
    guard let window = NativeStoreHandle.store?.displayState.windows[windowId] else { return }
    let open = Set(window.tabIds)
    let windowId = windowId
    let visible = open.filter { tabId in
      guard let slot = PaneOverlays.shared.container(windowId: windowId, tabId: tabId, layer: .rn) else { return false }
      return !slot.isHiddenOrHasHiddenAncestor
    }
    roots.update(visible: visible, open: open)
  }

  private static func unmount(_ root: NSView) {
    guard root.responds(to: Selector(("contentView"))), let content = root.value(forKey: "contentView") as? NSObject else { return }
    let invalidate = NSSelectorFromString("invalidate")
    if content.responds(to: invalidate) { content.perform(invalidate) }
  }

  func refreshNextTurn() {
    guard !refreshQueued else { return }
    refreshQueued = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.refreshQueued = false
        self.refresh()
      }
    }
  }

  func stop() {
    roots.stop()
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
        guard let self, let root else { return }
        self.roots.contentAppeared(tabId, root: root)
        self.keepSized(root)
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
