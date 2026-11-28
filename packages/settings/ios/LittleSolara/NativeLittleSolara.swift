import AppKit
import SolaraShaders
import SolaraShell
import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI
import Synchronization

@MainActor
enum NativeLittleSolara {
  private static var installed = false
  nonisolated private static let activeIds = Mutex<Set<String>>([])
  private static var hasHosts = false
  private static let lifetimes: ShellLifetimes<LittleSolaraHost> = {
    let lifetimes = ShellLifetimes<LittleSolaraHost> { $0.stop() }
    lifetimes.onIds = { ids in
      hasHosts = !ids.isEmpty
      activeIds.withLock { $0 = ids }
    }
    return lifetimes
  }()

  static func install() {
    guard !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    PageIssuer.lifecycleObservers.append { issuer, binding, name, payload in
      guard hasHosts, SmallBarPageFacts.events.contains(name), NativeStoreHandle.store === issuer.store,
        let windowId = issuer.store.state.tabs[binding.tabId]?.windowId,
        let host = host(windowId), issuer.isCurrent(binding) else { return }
      host.receive(binding, name: name, payload: payload)
    }
    WindowHost.makeContentView = { windowId in
      guard isSmallWindow(windowId) || WindowHost.openingKinds[windowId] == "small" else { return make(windowId) }
      let host = LittleSolaraHost(windowId: windowId, root: make(windowId))
      lifetimes.adopt(windowId, host)
      host.shell.onWindowChange = { [weak host] in
        guard let host, lifetimes.host(windowId) === host else { return }
        if host.shell.window != nil {
          host.attach()
        } else {
          DispatchQueue.main.async { [weak host] in
            guard let host, host.shell.window == nil else { return }
            remove(host)
          }
        }
      }
      return host.shell
    }
  }

  static func remove(_ host: LittleSolaraHost) {
    lifetimes.end(host.shell.windowId, ifHost: host)
  }

  static func overlay(_ windowId: String) -> NSView? {
    guard let host = host(windowId), host.acceptsOverlay else { return nil }
    return host.shell.overlay
  }

  static func isSmallWindow(_ windowId: String) -> Bool {
    NativeStoreHandle.store?.state.windows[windowId]?.kind == "small"
  }

  static func host(_ windowId: String) -> LittleSolaraHost? { lifetimes.host(windowId) }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  static func describe(_ windowId: String) -> [String: Any]? { host(windowId)?.describe() }

  static func barAction(_ action: SmallBarAction, windowId: String, bar: SmallBarView) {
    guard let host = host(windowId), host.shell.bar === bar, host.acceptsOverlay,
      let store = NativeStoreHandle.store,
      let tabId = bar.tabId,
      let command = SmallBarCommand.resolve(action, windowId: windowId, tabId: tabId, state: store.state, closing: store.memory.closingWindows)
    else { return }
    switch command {
    case .edit(let url):
      guard (try? store.dispatch(Command("openPanel", [.string(windowId), .string(url)]), origin: .native)) != nil else { return }
      host.refresh()
    case .menu:
      NativeOmniboxActions.urlMenu(tabId: tabId, windowId: windowId, in: bar)
    case .copy:
      guard let data = try? JSONEncoder().encode(["tabId": tabId]),
        NativeLinkCommands.perform("copyUrl", arg: String(decoding: data, as: UTF8.self), windowId: windowId) else { return }
      bar.showCopyConfirmation()
    case .expand:
      _ = NativeBrowserServiceCommands.perform("openFile", arg: nil, windowId: windowId)
    case .profile:
      NativeWorkspaceCommands.littleProfileMenu(windowId: windowId, store: store)
    }
  }
}

@MainActor
final class LittleSolaraHost {
  let shell: LittleSolaraShellView
  private weak var root: NSView?
  private let panel = NativeOmniboxView()
  private var placement: NativeOmniboxPanel?
  private var backdropJSON: String?
  private var appearance: ThemeScopeProjection?
  private var projectedBar: SmallBarState?
  private weak var store: Store?
  private var generation = -1
  private var subscription: Int?
  private var lifecycle: Int?
  private let cards = NSHashTable<SmallWindowPageHost>.weakObjects()
  private var pending = false
  private var stopped = false
  private var pageRegistration: PageRegistration?
  private var facts = SmallBarPageFacts()
  private weak var attachedWindow: NSWindow?
  private var closeObserver: NSObjectProtocol?
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?
  private var untrack: (() -> Void)?

  init(windowId: String, root: NSView) {
    shell = LittleSolaraShellView(windowId: windowId)
    self.root = root
    shell.mount(.react, root)
    shell.bar.isHidden = true
    shell.onResize = { [weak self] in
      self?.queueRefresh()
      NativeDownloadsPanel.smallGeometryChanged(windowId)
    }
    shell.bar.onAction = { [weak bar = shell.bar] action in
      if let bar { NativeLittleSolara.barAction(action, windowId: windowId, bar: bar) }
    }
    untrack = NativeMedia.track(NativeMedia.smallBar, windowId, shell.bar)
    let center = NotificationCenter.default
    let appeared = Notification.Name("RCTContentDidAppearNotification")
    observers.append(
      center.addObserver(forName: appeared, object: root, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.keepContentSized()
          center.post(name: appeared, object: self.shell)
        }
      })
    keepContentSized()
  }

  var acceptsOverlay: Bool {
    guard !stopped, let attachedWindow, shell.window === attachedWindow, let store,
      NativeStoreHandle.store === store, NativeStoreHandle.ownsWorkspace,
      NativeStoreHandle.ownershipGeneration == generation else { return false }
    return store.state.windows[shell.windowId]?.isSmall == true
      && !store.memory.closingWindows.contains(shell.windowId)
  }

  func ownsPanel(_ view: NativeOmniboxView) -> Bool { panel === view }

  func attach() {
    guard !stopped, let window = shell.window, attachedWindow !== window else { return }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    attachedWindow = window
    let id = shell.windowId
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) {
      [weak self, weak window] _ in
      MainActor.assumeIsolated {
        guard let self, let window, self.shell.window === window else { return }
        NativeLittleSolara.remove(self)
      }
    }
    ShellWindowEdge.setLightsCenter(id, LittleSolaraMetrics.lightsCenter)
    if lifecycle == nil {
      panel.mountSmallPanel(windowId: id, in: shell.overlay)
      lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.followStore() }
    } else {
      dismissOverlays()
      refresh()
    }
    NativeDownloadsPanel.queueRefresh()
  }

  private func followStore() {
    let current = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    let nextGeneration = NativeStoreHandle.ownershipGeneration
    guard store !== current || generation != nextGeneration else { return }
    if let subscription { store?.unsubscribe(subscription) }
    store = current
    generation = nextGeneration
    pageRegistration = nil
    facts = SmallBarPageFacts()
    let id = shell.windowId
    let appDark = Mutex(current?.state.ui.appDark ?? false)
    subscription = current?.subscribe { [weak self] commit in
      let changes = commit.changes
      let window = commit.state.windows[id]
      let tabId = commit.state.activeTabId(id)
      let appearanceChanged = appDark.withLock { dark in
        let next = commit.state.ui.appDark
        defer { dark = next }
        return dark != next
      }
      func affects(_ table: TableChange, _ key: String?) -> Bool {
        key.map { table.upserted.contains($0) || table.removed.contains($0) } ?? false
      }
      guard affects(changes.windows, id) || affects(changes.windowUi, id) || affects(changes.tabs, tabId)
        || affects(changes.live, tabId) || affects(changes.profiles, window?.profileId)
        || changes.lists.contains("profileOrder") || appearanceChanged
        || changes.settingsChanged.contains(where: ["spacesFollowAppearance", "lightColorsKeepWhiteText"].contains)
        || changes.settingsRemoved.contains(where: ["spacesFollowAppearance", "lightColorsKeepWhiteText"].contains)
        || commit.commands.contains(where: { $0.name == "setWindowClosing" && $0.args.first?.string == id }) else { return }
      DispatchQueue.main.async { self?.queueRefresh() }
    }
    refresh()
  }

  func receive(_ binding: PageHostBinding, name: String, payload: JSONValue) {
    guard acceptsOverlay, store?.state.activeTabId(shell.windowId) == binding.tabId else { return }
    if pageRegistration != binding.registration {
      pageRegistration = binding.registration
      facts = SmallBarPageFacts()
    }
    let previous = facts
    facts.receive(name, payload)
    if previous != facts { queueRefresh() }
  }

  private func queueRefresh() {
    guard !stopped, !pending else { return }
    pending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pending = false
      self.refresh()
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    if let subscription { store?.unsubscribe(subscription) }
    subscription = nil
    if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
    lifecycle = nil
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
    attachedWindow = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    untrack?()
    untrack = nil
    dismissOverlays()
    panel.unmountSmallPanel()
  }

  func dismissOverlays() {
    NativeExtensionActionPopup.close(windowId: shell.windowId, restoreFocus: false)
    NativeDownloadsPanel.removeSmall(shell.windowId)
    panel.projectSmallPanel(nil, profile: "", theme: panel.bar.theme)
    placement = nil
  }

  func refresh() {
    guard !stopped else { return }
    guard acceptsOverlay, let store else { return dismissOverlays() }
    let id = shell.windowId
    let state = store.state
    guard let window = state.windows[id] else { return }
    let page = SmallBarPage.resolve(windowId: id, state: state, closing: store.memory.closingWindows)
    let binding = page.flatMap { PageIssuer.shared?.binding(tabId: $0.id) }
    if pageRegistration != binding?.registration {
      pageRegistration = binding?.registration
      facts = SmallBarPageFacts()
    }
    let look = NativeLayoutAppearance(state: state, profileId: window.profileId, incognito: window.incognito)
    let cardAppearanceChanged = appearance?.dark != look.dark || projectedBar?.tabId != page?.id
    if cardAppearanceChanged {
      for host in cards.allObjects { host.project(dark: look.dark, activeTabId: page?.id) }
    }
    let scope = ThemeScopeProjection.project(state, windowId: id)
    updateBackdrop(scope)
    let ui = state.windowUi[id]
    let panelOpen = ui?.panelOpen == true
    let profile = SmallBarProfile.resolve(in: state, profileId: window.profileId) { NativeLayoutAppearance.profileSwatch($0) }
    var barTheme = NativeMediaStack.theme(look)
    barTheme.colors["iconDisabled"] = (scope.adjustInk ? scope.sidebarInk?["iconDisabled"] : nil)
      ?? (look.dark ? "#F7F5FF4D" : "#0000004D")
    let bar = SmallBarState(page: page, facts: facts, profileId: window.profileId, profile: profile,
      hidden: panelOpen, theme: barTheme, product: Bundle.main.productName)
    if projectedBar != bar {
      projectedBar = bar
      shell.bar.update(bar)
      shell.bar.isHidden = false
    }
    placement = nil
    if let page, panelOpen,
      let geometry = SmallBarMetrics.panelPlacement(width: shell.bounds.width, buttons: bar.buttons.count + (bar.profile == nil ? 0 : 1)) {
      let style = OmniboxPanelStyle(fill: CSSColor(look.tokens["panel"] ?? "") ?? CSSColor("#FFFFFF")!,
        border: CSSColor(look.tokens["panelBorder"] ?? "") ?? CSSColor("#0000001A")!, shadowOpacity: look.panel.shadowOpacity, radius: 12)
      placement = NativeOmniboxPanel(open: true, ready: false, tabId: page.id, text: ui?.json["panel"]?["initialText"]?.string ?? "",
        placement: geometry, style: style, variant: .sidebar)
    }
    panel.projectSmallPanel(placement, profile: window.profileId, theme: NewTabTheme(dark: look.dark, tokens: look.tokens))
  }

  func track(_ card: SmallWindowPageHost) {
    cards.add(card)
    card.project(dark: appearance?.dark ?? false, activeTabId: projectedBar?.tabId)
  }

  func untrack(_ card: SmallWindowPageHost) {
    cards.remove(card)
  }

  private func updateBackdrop(_ next: ThemeScopeProjection) {
    guard appearance != next, let data = try? JSONEncoder().encode(next.backdrop),
      var props = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    appearance = next
    props["vibrancy"] = true
    props["colors"] = next.windowTint
    props["grainOpacity"] = next.dark ? 0.006 : 0.05
    backdropJSON = (try? JSONSerialization.data(withJSONObject: props, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
    shell.mount(.backdrop, EarlyBackdrop.make(props as NSDictionary))
  }

  private func keepContentSized() {
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    guard let root, let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    content.postsFrameChangedNotifications = true
    contentSizer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) {
      [weak root, weak content] _ in
      MainActor.assumeIsolated {
        guard let root, let content, content.superview === root, root.window != nil, !root.bounds.isEmpty, content.frame.size != root.bounds.size
        else { return }
        root.needsLayout = true
        content.needsLayout = true
      }
    }
  }

  private func blankBarHit() -> Any {
    guard let superview = shell.superview else { return NSNull() }
    let point = superview.convert(NSPoint(x: 60, y: SmallBarMetrics.height / 2), from: shell)
    return shell.hitTest(point).map { NSStringFromClass(type(of: $0)) } ?? NSNull()
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    return [
      "bounds": rect(shell.bounds),
      "bar": rect(shell.barFrame),
      "card": rect(shell.cardFrame),
      "barShown": !shell.bar.isHidden,
      "blankBarHit": blankBarHit(),
      "reactFill": (root?.value(forKey: "backgroundColor") as? NSColor).map { $0.description } ?? NSNull(),
      "slots": LittleSolaraShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
      "panel": placement.map {
        ["from": $0.placement.from.map(rect) as Any? ?? NSNull(), "frame": [$0.placement.left, $0.placement.top, $0.placement.width],
          "radius": $0.style.radius, "variant": $0.variant.rawValue] as [String: Any]
      } as Any? ?? NSNull(),
    ]
  }
}
