import AppKit
import SolaraShaders
import SolaraShell
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import Synchronization
import SolaraUI

@MainActor
enum NativeWindowShell {
  private static var installed = false
  private static var storeListener: Int?
  private static let lifetimes: ShellLifetimes<ShellHost> = {
    let lifetimes = ShellLifetimes<ShellHost> { host in
      host.stop()
      if NativeWindowShell.lifetimes.host(host.shell.windowId) == nil { NativeShareBand.windowEnded(host.shell.windowId) }
    }
    lifetimes.onIds = { ids in
      activeIds.withLock { $0 = ids }
      nativeLayoutGenerations.withLock { generations in
        generations = generations.filter { ids.contains($0.key) }
      }
    }
    return lifetimes
  }()
  private static let commits = ShellStoreCommits()
  private static var nextGeneration: UInt64 = 0
  private static var latestRevision = -1
  nonisolated private static let activeIds = Mutex<Set<String>>([])
  nonisolated private static let nativeLayoutGenerations = Mutex<[String: UInt64]>([:])

  nonisolated static var enabled: Bool {
    LaunchSwitches.shared.isOn(.nativeShell)
  }

  nonisolated static var mainOnTop: Bool {
    TabPoolHost.available && LaunchSwitches.shared.isOn(.shellMainTop)
  }

  nonisolated static var nativeLayout: Bool {
    LaunchSwitches.shared.isOn(.nativeWindowLayout) && mainOnTop
  }

  nonisolated static var legacyLayoutReason: String? {
    if !enabled { return "native shell disabled" }
    if !NativeStoreHandle.ownedWorkspaceAtLaunch { return "native workspace disabled" }
    if !NativeStoreHandle.opened { return "native workspace not opened" }
    if !LaunchSwitches.shared.isOn(.nativeWindowLayout) { return "native layout switch or prerequisite disabled" }
    if !NativePaneRoots.available { return "pane guest factory unavailable" }
    if !mainOnTop { return "native page pool unavailable" }
    return nil
  }

  nonisolated static func nativeLayoutActive(_ windowId: String) -> Bool {
    nativeLayoutGenerations.withLock { $0[windowId] != nil }
  }

  nonisolated static func nativeLayoutGeneration(_ windowId: String) -> UInt64 {
    nativeLayoutGenerations.withLock { $0[windowId] ?? 0 }
  }

  static func install() {
    guard enabled, !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    NativeLaunchWork.install()
    let prepare = WindowHost.prepareContent
    WindowHost.prepareContent = { windowId, root, committed in
      guard let host = lifetimes.host(windowId), host.shell === root else {
        return prepare?(windowId, root, committed) ?? false
      }
      host.prepareLaunch(committed)
      return true
    }
    NativeSplitChrome.start()
    NativeShareBand.start()
    NativePeek.start()
    if !nativeLayout, let store = NativeStoreHandle.store {
      let sink = commits
      #if SOLARA_PROBES
      NativeWorkCounters.shellStoreSubscriptions = 1
      #endif
      storeListener = store.subscribe { commit in
        sink.receive(commit.state, revision: commit.rev)
        NativePaneRoots.storeChanged()
      }
    }
    WindowHost.makeContentView = { windowId in
      guard isBrowserWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      nextGeneration += 1
      let ownsNativeLayout = nativeLayout
      if !ownsNativeLayout { NSLog("[window layout] %@ uses the complete legacy path: %@", windowId, legacyLayoutReason ?? "unavailable") }
      if ownsNativeLayout { nativeLayoutGenerations.withLock { $0[windowId] = nextGeneration } }
      #if DEBUG || SOLARA_PERF_TRACE
      let rootTrace = LayoutTrace.begin("windowRoot", windowId)
      #endif
      let root = make(windowId)
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.end(rootTrace)
      let shellTrace = LayoutTrace.begin("windowShell", windowId)
      #endif
      let host = ShellHost(windowId: windowId, generation: nextGeneration, nativeLayout: ownsNativeLayout, root: root)
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.end(shellTrace)
      #endif
      lifetimes.adopt(windowId, host)
      if !host.ownsNativeLayout, let store = NativeStoreHandle.store {
        store.sequence { windowsChanged(store.state, revision: store.rev) }
      }
      host.onClose = { [weak host] in lifetimes.end(windowId, ifHost: host) }
      return host.shell
    }
  }

  static func windowsChanged(_ state: BrowserState, revision: Int) {
    guard revision >= latestRevision else { return }
    latestRevision = revision
    for id in lifetimes.ids { lifetimes.host(id)?.applyLayoutState(state, revision: revision) }
    lifetimes.prune(keeping: Set(state.windows.keys))
  }

  static func isBrowserWindow(_ windowId: String) -> Bool {
    if let kind = WindowHost.openingKinds[windowId] { return kind == "browser" }
    guard let window = NativeStoreHandle.store?.state.windows[windowId] else { return false }
    return window.kind == nil || window.kind == "browser"
  }

  static func host(_ windowId: String) -> ShellHost? { lifetimes.host(windowId) }
  static var windowIds: Set<String> { lifetimes.ids }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  nonisolated static var activeWindowIds: Set<String> { activeIds.withLock { $0 } }

  static func preparePagePlacement(_ state: BrowserState, revision: Int) -> Set<String> {
    let hosts = lifetimes.ids.compactMap { id -> ShellHost? in
      guard let host = lifetimes.host(id), host.queuePagePlacement(state, revision: revision) else { return nil }
      return host
    }
    guard !hosts.isEmpty else { return [] }
    FrameUpdates.flush()
    return Set(hosts.compactMap { host in
      host.finishPagePlacement(state, revision: revision) ? host.shell.windowId : nil
    })
  }

  static func overlay(_ windowId: String) -> NSView? { host(windowId)?.shell.overlay }

  static func hiddenPages(_ windowId: String) -> NSView? { host(windowId)?.shell.hiddenPages }

  static func setBackdrop(_ windowId: String, _ json: String) {
    host(windowId)?.setBackdrop(json)
  }

  static func describe(_ windowId: String) -> [String: Any]? {
    host(windowId)?.describe()
  }
}

@MainActor
final class ShellHost {
  let shell: WindowShellView
  private weak var root: NSView?
  private var backdropJSON: String?
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?
  private var closing: NSObjectProtocol?
  private var panes: PaneRootsHost?
  private var profilePager: ProfilePagerHost?
  private var sidePanel: SidePanelHost?
  let ownsNativeLayout: Bool
  private var layoutController: WindowLayoutController?
  private var layoutChrome: NativeLayoutChrome?
  private var paneLayout: NativePaneLayoutHost?
  private var toolbarPresentation: ToolbarAutoHideController?
  private var fullscreenObservers: [NSObjectProtocol] = []
  private var spacesFullscreen: Bool?
  private var spacesTransitioning = false
  private var presentedTabIds = Set<String>()
  private var presentationURLs: [String: String] = [:]
  private var toolbarHolds = Set<String>()
  private var commandHold: String?
  private var commandHoldGeneration: UInt64 = 0
  private let legacyLayoutAnchors: WindowAnchors
  private var layoutAnchors: WindowAnchors { layoutController?.anchors ?? legacyLayoutAnchors }
  private let windowGeneration: UInt64
  private var layoutState: BrowserState?
  private var layoutRevision = -1
  private var layoutGeneration: UInt64 = 0
  private var lastLayoutInput: WindowLayoutInput?
  private var lastChildAnchors: [String: CGRect] = [:]
  private var layoutStopped = false
  private var layoutProjectionPending = false
  private var layoutCollectingAnchors = false
  private var layoutReader: String?
  private var lastSentLayoutAnchors: WindowAnchorBatch?
  private var layoutToolbarReady = false
  private var launchReadiness: NativeLaunchReadiness?
  #if DEBUG
  var devSidePanelResizeLinkActive: Bool { sidePanel?.devResizeLinkActive ?? false }
  #endif
  #if SOLARA_PROBES
  private var probeStopped = false
  #endif
  var onClose: (() -> Void)?

  init(windowId: String, generation: UInt64, nativeLayout: Bool, root: NSView) {
    ownsNativeLayout = nativeLayout
    windowGeneration = generation
    legacyLayoutAnchors = WindowAnchors(windowId: windowId, windowGeneration: generation)
    shell = WindowShellView(windowId: windowId, reactOnTop: NativeWindowShell.mainOnTop)
    self.root = root
    launchReadiness = NativeLaunchReadiness(windowId: windowId, generation: generation, shell: shell, root: root)
    launchReadiness?.coherent = { [weak self] in
      guard let self, let last = self.lastLayoutInput, let input = self.makeLayoutInput() else { return false }
      return last.hasSameLayout(as: input) && NativeStoreHandle.store?.rev == self.layoutRevision
        && !self.shell.frames.card.isEmpty && !self.shell.frames.page.isEmpty
    }
    launchReadiness?.revision = { [weak self] in self?.layoutRevision ?? -1 }
    launchReadiness?.guestsReady = { [weak self] in
      guard let self, let input = self.lastLayoutInput else { return false }
      guard NativePaneRoots.active(windowId) else { return true }
      let ids = input.split?.tabIds ?? input.selectedTabId.map { [$0] } ?? []
      return ids.allSatisfy { id in
        guard let slot = PaneOverlays.shared.container(windowId: windowId, tabId: id, layer: .rn) else { return false }
        guard !slot.isHiddenOrHasHiddenAncestor else { return true }
        return slot.subviews.contains { !$0.isHidden && !$0.bounds.isEmpty }
      }
    }
    #if SOLARA_PROBES
    NativeWorkCounters.host(self, windowId: windowId, kind: "ShellHost") { (host: ShellHost) -> (Bool, Int) in
      let contentSubscriptions = host.contentSizer == nil ? 0 : 1
      let closeSubscriptions = host.closing == nil ? 0 : 1
      let subscriptions = host.observers.count + contentSubscriptions + closeSubscriptions
      return (!host.probeStopped, subscriptions)
    }
    #endif
    if shell.reactOnTop, root.responds(to: Selector(("setPassThroughTouches:"))) { root.setValue(true, forKey: "passThroughTouches") }
    shell.mount(.react, root)
    let center = NotificationCenter.default
    let appeared = Notification.Name("RCTContentDidAppearNotification")
    observers.append(
      center.addObserver(forName: appeared, object: root, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.layoutStopped else { return }
          self.keepContentSized()
          center.post(name: appeared, object: self.shell)
        }
      })
    keepContentSized()
    shell.onWindow = { [weak self] window in
      self?.watchClose(of: window)
      self?.profilePager?.windowChanged()
      self?.sidePanel?.windowChanged(window)
      self?.scheduleLayoutProjection()
      if let self, window != nil {
        NativeTabPickers.prepare(windowId, in: self.shell.overlay)
        NativeSidebarHoverCard.prepare(windowId)
      }
    }
    shell.onCaptionLayout = { [weak self] in
      guard let self, !self.layoutStopped, let window = self.shell.window else { return }
      WindowCaptionLayout.refresh(in: window)
    }
    panes = NativePaneRoots.start(windowId, prepareSelected: !ownsNativeLayout)
    profilePager = NativeProfilePager.start(shell)
    shell.onFrames = { [weak self] _ in
      self?.profilePager?.place()
      self?.sidePanel?.place()
      self?.scheduleLayoutProjection()
    }
    if ownsNativeLayout, let store = NativeStoreHandle.store {
      layoutChrome = NativeLayoutChrome(windowId: windowId, shell: shell, generation: generation)
      NativeSidebarShell.column(windowId)?.host.view.onLayoutAnchorsChange = { [weak self] in self?.layoutGeometryChanged() }
      paneLayout = NativeSplitChrome.adopt(shell: shell, generation: generation)
      toolbarPresentation = ToolbarAutoHideController(windowId: windowId, windowGeneration: generation)
      let controller = WindowLayoutController(shell: shell, generation: generation, store: store)
      layoutController = controller
      controller.onState = { [weak self] state, revision in
        guard let self, !self.layoutStopped else { return }
        self.applyLayoutState(state, revision: revision)
        self.layoutChrome?.apply(state: state, revision: revision)
        NativePaneRoots.storeChanged()
      }
      controller.onRemoved = { [weak self] in self?.onClose?() }
      controller.start()
    }
  }

  private func watchClose(of window: NSWindow?) {
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
    fullscreenObservers = []
    guard let window else { return }
    spacesFullscreen = window.styleMask.contains(.fullScreen) && !rendererOwnsFullscreen(window)
    for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      fullscreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] notification in
        let entering = notification.name == NSWindow.willEnterFullScreenNotification || notification.name == NSWindow.didEnterFullScreenNotification
        let transitioning = notification.name == NSWindow.willEnterFullScreenNotification || notification.name == NSWindow.willExitFullScreenNotification
        MainActor.assumeIsolated {
          guard let self, let window, !self.layoutStopped else { return }
          self.spacesFullscreen = entering && !self.rendererOwnsFullscreen(window)
          self.spacesTransitioning = transitioning
          self.scheduleLayoutProjection()
        }
      })
    }
    fullscreenObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name("SolaraCommandWillDispatch"), object: window, queue: .main) { [weak self] notification in
      let command = notification.userInfo?["command"] as? String
      MainActor.assumeIsolated {
        guard let self, let command,
          command == "focusCommandBar" || command == "findInPage",
          let state = NativeStoreHandle.store?.state, let id = state.peeks[self.shell.windowId]?.tabId ?? state.activeTabId(self.shell.windowId) else { return }
        self.commandHold = id
        self.commandHoldGeneration += 1
        let generation = self.commandHoldGeneration
        if let store = NativeStoreHandle.store { self.applyLayoutState(store.state, revision: store.rev) }
        self.refreshLayoutProjection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
          guard let self, self.commandHoldGeneration == generation, !self.layoutStopped else { return }
          self.commandHold = nil
          self.scheduleLayoutProjection()
        }
      }
    })
    closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClose?() }
    }
  }

  func stop() {
    guard !layoutStopped else { return }
    layoutStopped = true
    NativeTabPickers.windowEnded(shell.windowId, in: shell.overlay)
    NativeSidebarHoverCard.windowEnded(shell.windowId)
    SidebarAddressBars.shared.removeNavigationView(shell.windowId)
    toolbarPresentation?.stop()
    toolbarPresentation = nil
    AutoHideHost.windowEnded(shell.windowId)
    for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
    fullscreenObservers = []
    launchReadiness?.stop()
    launchReadiness = nil
    layoutController?.stop()
    layoutChrome?.stop()
    layoutChrome = nil
    paneLayout?.stop()
    paneLayout = nil
    layoutAnchors.stop()
    shell.onFrames = nil
    shell.onCaptionLayout = nil
    #if SOLARA_PROBES
    probeStopped = true
    #endif
    sidePanel?.stop()
    sidePanel = nil
    NativePeek.windowEnded(shell.windowId)
    NativeSidebarDock.setReactPeekRight(shell.windowId, 0)
    if let panes { NativePaneRoots.end(shell.windowId, ifHost: panes) }
    panes = nil
    profilePager?.stop()
    profilePager = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let closing { NotificationCenter.default.removeObserver(closing) }
    closing = nil
    onClose = nil
    shell.onWindow = nil
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
  }

  func prepareLaunch(_ committed: @escaping () -> Void) {
    #if DEBUG || SOLARA_PERF_TRACE
    let windowId = shell.windowId
    LayoutTrace.event("windowAwaitReady", windowId)
    launchReadiness?.attach {
      LayoutTrace.event("windowReady", windowId)
      committed()
    }
    #else
    launchReadiness?.attach(committed)
    #endif
  }

  private func keepContentSized() {
    guard !layoutStopped else { return }
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

  func setSidePanel(_ json: String?) {
    if sidePanel == nil {
      guard let json, !json.isEmpty, SidePanelState.decode(json) != nil else { return }
      sidePanel = SidePanelHost(windowId: shell.windowId, shell: shell)
    }
    sidePanel?.apply(json)
  }

  func setBackdrop(_ json: String) {
    guard json != backdropJSON else { return }
    backdropJSON = json
    defer { NativePeek.backdropChanged(shell.windowId) }
    guard let view = makeBackdrop() else { return shell.mount(.backdrop, nil) }
    shell.mount(.backdrop, view)
  }

  func makeBackdrop() -> NSView? {
    guard let data = backdropJSON?.data(using: .utf8), let props = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary else { return nil }
    return EarlyBackdrop.make(props)
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull() }
    let f = shell.frames
    return [
      "bounds": rect(shell.bounds),
      "trafficLights": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> [String: Any]? in
        guard let button = shell.window?.standardWindowButton(kind) else { return nil }
        return ["rect": rect(button.convert(button.bounds, to: shell)), "hidden": button.isHiddenOrHasHiddenAncestor]
      },
      "nativeLayout": ownsNativeLayout,
      "legacyLayoutReason": ownsNativeLayout ? NSNull() : NativeWindowShell.legacyLayoutReason as Any,
      "nativeLayoutChrome": layoutChrome?.describe() ?? NSNull(),
      "layoutControllerSubscriptions": layoutController?.subscriptionCount ?? 0,
      "layout": describeLayout() ?? NSNull(),
      "card": rect(f.card),
      "sidebar": rect(f.sidebar),
      "sidebarShift": f.sidebarShift,
      "topStrip": rect(f.topStrip),
      "slots": WindowShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
      "fill": shell.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "windowFill": shell.window?.backgroundColor.map { String(describing: $0) } ?? NSNull(),
      "appearance": shell.window?.effectiveAppearance.name.rawValue ?? NSNull(),
      "split": NativeSplitChrome.sample(shell.windowId) ?? NSNull(),
      "shareBand": NativeShareBand.describe(shell.windowId) ?? NSNull(),
      "shareBandWindows": NativeShareBand.windowIds,
      "paneRoots": NativePaneRoots.sample(shell.windowId) ?? NSNull(),
      "reactOnTop": shell.reactOnTop,
      "peek": NativePeek.sample(shell.windowId) ?? NSNull(),
      "sidebarDock": NativeSidebarDock.describe(shell.windowId) ?? NSNull(),
    ]
  }
}

extension ShellHost {
  func setToolbarHold(_ tabId: String, held: Bool) {
    guard !layoutStopped else { return }
    let changed = held ? toolbarHolds.insert(tabId).inserted : toolbarHolds.remove(tabId) != nil
    if changed { scheduleLayoutProjection() }
  }

  var presentationFacts: [String: WindowLayoutPageFacts] { toolbarPresentation?.facts ?? [:] }

  private func rendererOwnsFullscreen(_ window: NSWindow) -> Bool {
    let selector = NSSelectorFromString("windowFullScreenIsForPage:")
    guard let host = NSClassFromString("ACChromeWindowHost") as? NSObject.Type,
      (host as AnyObject).responds(to: selector), let call = (host as AnyObject).method(for: selector) else { return false }
    typealias Call = @convention(c) (AnyObject, Selector, NSWindow) -> ObjCBool
    return unsafeBitCast(call, to: Call.self)(host, selector, window).boolValue
  }

  func receivePresentation(_ registration: PageRegistration, name: String, payload: [String: Any]) {
    guard !layoutStopped, ownsNativeLayout, let toolbarPresentation else { return }
    let previous = toolbarPresentation.facts[registration.tabID]
    toolbarPresentation.register(registration)
    if name == "onNavigationChange", let url = payload["url"] as? String {
      let key = String(url.prefix { $0 != "#" })
      if let previous = presentationURLs[registration.tabID], previous != key { toolbarPresentation.reveal(tabId: registration.tabID) }
      presentationURLs[registration.tabID] = key
    }
    if name == "onPageMessage", payload["kind"] as? String == "scroll",
      let state = (payload["data"] as? [String: Any])?["state"] as? String {
      _ = toolbarPresentation.noteScroll(registration, state: state)
    } else if name == "onFullscreen", let on = payload["fullscreen"] as? Bool {
      _ = toolbarPresentation.setFullscreen(registration, on: on)
    } else if name == "onCrashed" || name == "onDiscarded" {
      _ = toolbarPresentation.setFullscreen(registration, on: false)
      toolbarPresentation.reveal(tabId: registration.tabID)
    }
    if previous != toolbarPresentation.facts[registration.tabID] { scheduleLayoutProjection() }
  }

  func retirePresentation(_ registration: PageRegistration) {
    guard !layoutStopped, ownsNativeLayout,
      toolbarPresentation?.facts[registration.tabID]?.registration == String(registration.registrationGeneration) else { return }
    toolbarPresentation?.retire(registration)
    presentationURLs[registration.tabID] = nil
    AutoHideHost.remove(windowId: shell.windowId, tabId: registration.tabID)
    scheduleLayoutProjection()
  }

  func toolbarPresentationEvent(_ tabId: String, _ event: AutoHideStripEvent) {
    guard !layoutStopped, let toolbarPresentation, let registration = TabPoolHost.shared.presentationRegistration(tabId) else { return }
    toolbarPresentation.register(registration)
    switch event {
    case .reveal: toolbarPresentation.reveal(tabId: tabId)
    case .peek(let on): _ = toolbarPresentation.setPeek(registration, on: on)
    }
    scheduleLayoutProjection()
  }

  func nativeShownTop(_ tabId: String) -> Double? {
    guard ownsNativeLayout, let input = makeLayoutInput() else { return nil }
    return WindowLayoutSnapshot.of(input, generation: layoutGeneration).shownTops[tabId].map(Double.init)
  }

  func queuePagePlacement(_ state: BrowserState, revision: Int) -> Bool {
    guard ownsNativeLayout, !layoutStopped, state.windows[shell.windowId] != nil,
      NativeWindowShell.nativeLayoutGeneration(shell.windowId) == windowGeneration else { return false }
    layoutController?.receive(state, revision: revision, generation: windowGeneration)
    return true
  }

  func finishPagePlacement(_ state: BrowserState, revision: Int) -> Bool {
    guard ownsNativeLayout, !layoutStopped, state.windows[shell.windowId] != nil,
      NativeWindowShell.nativeLayoutGeneration(shell.windowId) == windowGeneration else { return false }
    if pagePlacementReady(revision: revision) { return true }
    applyLayoutState(state, revision: revision)
    refreshLayoutProjection()
    return pagePlacementReady(revision: revision)
  }

  private func pagePlacementReady(revision: Int) -> Bool {
    !layoutProjectionPending && lastLayoutInput?.storeRevision == revision && lastLayoutInput?.windowGeneration == windowGeneration
      && shell.window != nil && paneLayout != nil
  }

  func applyLayoutState(_ state: BrowserState, revision: Int) {
    guard !layoutStopped, revision >= layoutRevision, state.windows[shell.windowId] != nil else { return }
    if ownsNativeLayout, revision == layoutRevision { return }
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("layoutState", "\(shell.windowId) \(revision)")
    defer { LayoutTrace.end(trace) }
    #endif
    layoutState = state
    layoutRevision = revision
    scheduleLayoutProjection()
  }

  func layoutGeometryChanged(_ origin: StaticString = #function, line: Int = #line) {
    guard !layoutCollectingAnchors else { return }
    scheduleLayoutProjection(origin, line: line)
  }

  func scheduleLayoutProjection(_ origin: StaticString = #function, line: Int = #line) {
    guard !layoutStopped else { return }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.event("layoutScheduled", "\(shell.windowId) \(layoutRevision) \(origin):\(line)")
    if LayoutTrace.enabled, ProcessInfo.processInfo.environment["SOLARA_LAYOUT_STACKS"] == "1" {
      LayoutTrace.event("layoutRequester", "\(shell.windowId) \(layoutRevision) \(Thread.callStackSymbols.joined(separator: " | "))")
    }
    #endif
    layoutProjectionPending = true
    FrameUpdates.schedule(self) { [weak self] in self?.refreshLayoutProjection() }
  }

  func makeLayoutInput() -> WindowLayoutInput? {
    guard !layoutStopped, let state = layoutState, let window = shell.window, !shell.bounds.isEmpty else { return nil }
    let update = NativeSidebarShell.column(shell.windowId)?.chrome.state?.update
    let updateHeight: CGFloat = update == nil ? 0 : shell.railFraction > 0 ? SidebarUpdatePillMetrics.railBand : SidebarUpdatePillMetrics.band
    guard let base = WindowLayoutInput(state: state, windowId: shell.windowId, windowGeneration: windowGeneration,
      storeRevision: layoutRevision, bounds: shell.bounds, backingScale: window.backingScaleFactor, presentation: shell.input,
      sidebarUpdateHeight: updateHeight, sidebarPositionAllowed: ownsNativeLayout) else { return nil }
    var ids = base.split?.tabIds ?? base.selectedTabId.map { [$0] } ?? []
    if let peek = state.peeks[shell.windowId]?.tabId { ids.append(peek) }
    if let held = commandHold {
      let current = state.peeks[shell.windowId]?.tabId ?? state.activeTabId(shell.windowId)
      if current != held || state.windowUi[shell.windowId]?.panelOpen == true || state.find[held]?.json["open"]?.truthy == true { commandHold = nil }
    }
    let alive = Set(state.tabs.values.filter { $0.windowId == shell.windowId }.map(\.id))
    toolbarPresentation?.retain(tabIds: alive)
    toolbarHolds.formIntersection(alive)
    presentationURLs = presentationURLs.filter { alive.contains($0.key) }
    let presented = Set(ids)
    for id in presented.subtracting(presentedTabIds) { toolbarPresentation?.reveal(tabId: id) }
    presentedTabIds = presented
    var facts: [String: WindowLayoutPageFacts] = [:]
    for id in ids {
      if let registration = TabPoolHost.shared.presentationRegistration(id) { toolbarPresentation?.register(registration) }
      let fact = toolbarPresentation?.facts[id]
      facts[id] = WindowLayoutPageFacts(registration: fact?.registration ?? "", fullscreen: fact?.fullscreen ?? false,
        top: base.hideToolbarWhileScrolling && !base.layout.addressBarInSidebar
          ? AutoHideHost.layoutTop(windowId: shell.windowId, tabId: id) : nil,
        band: NativeShareBand.height(windowId: shell.windowId, tabId: id),
        scrolledDown: fact?.scrolledDown ?? false, peek: fact?.peek ?? false)
    }
    return WindowLayoutInput(state: state, windowId: shell.windowId, windowGeneration: windowGeneration,
      storeRevision: layoutRevision, bounds: shell.bounds, backingScale: window.backingScaleFactor, presentation: shell.input,
      sidebarUpdateHeight: updateHeight, sidebarPositionAllowed: ownsNativeLayout, pageFacts: facts, windowFullscreen: spacesFullscreen, windowTransitioning: spacesTransitioning,
      toolbarHolds: toolbarHolds.union(commandHold.map { [$0] } ?? []).union(ids.filter {
        NativeToolbarHostView.toolbar(windowId: shell.windowId, tabId: $0)?.state?.url?.developer?.editing == true
      }))
  }

  private func refreshLayoutProjection() {
    #if DEBUG || SOLARA_PERF_TRACE
    if LayoutTrace.enabled, ProcessInfo.processInfo.environment["SOLARA_LAYOUT_STACKS"] == "1" {
      LayoutTrace.event("layoutExecution", "\(shell.windowId) \(layoutRevision) \(Thread.callStackSymbols.joined(separator: " | "))")
    }
    #endif
    TabSlots.shared.performBatch { refreshLayoutProjectionInBatch() }
  }

  private func refreshLayoutProjectionInBatch() {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("layout", "\(shell.windowId) \(layoutRevision)")
    defer { LayoutTrace.end(trace) }
    #endif
    guard !layoutStopped else { return }
    layoutProjectionPending = false
    layoutCollectingAnchors = ownsNativeLayout
    defer {
      layoutCollectingAnchors = false
      launchReadiness?.refresh()
    }
    #if DEBUG || SOLARA_PERF_TRACE
    let chromeTrace = LayoutTrace.begin("layoutChrome", shell.windowId)
    #endif
    layoutChrome?.refresh()
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.end(chromeTrace)
    let subtreeTrace = LayoutTrace.begin("layoutShellSubtree", shell.windowId)
    #endif
    if ownsNativeLayout { shell.layoutFrameIfNeeded() } else { shell.layoutSubtreeIfNeeded() }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.end(subtreeTrace)
    let inputTrace = LayoutTrace.begin("layoutMakeInput", shell.windowId)
    #endif
    let madeInput = makeLayoutInput()
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.end(inputTrace)
    #endif
    guard let input = madeInput else { return }
    if input.presentation.chromeNavigationRow {
      SidebarAddressBridge.install()
      let navigation = SidebarAddressBars.shared.navigationView(shell.windowId)
      navigation.navigationLeadingInset = shell.trafficLightsLeadingInset(at: 0)
      if shell.view(in: .navigation) !== navigation { shell.mount(.navigation, navigation) }
    } else if shell.view(in: .navigation) != nil {
      shell.mount(.navigation, nil)
      SidebarAddressBars.shared.removeNavigationView(shell.windowId)
    }
    let snapshot = WindowLayoutSnapshot.of(input, generation: layoutGeneration + 1)
    if let state = layoutState { paneLayout?.install(snapshot, state: state) }
    AutoHideHost.install(snapshot)
    NativePeek.presentationChanged(shell.windowId, fullscreenTabId: snapshot.fullscreenTabId)
    if let state = layoutState { NativePeek.install(state, shell: shell, fullscreenTabId: snapshot.fullscreenTabId) }
    let toolbar = input.selectedTabId.flatMap { NativeSplitChrome.toolbar(windowId: shell.windowId, tabId: $0) }
    let toolbarReady = !ownsNativeLayout || toolbar?.state != nil && toolbar?.window != nil && toolbar?.window === shell.window
    let toolbarBecameReady = toolbarReady && !layoutToolbarReady
    layoutToolbarReady = toolbarReady
    #if DEBUG || SOLARA_PERF_TRACE
    let anchorsTrace = LayoutTrace.begin("layoutChildAnchors", shell.windowId)
    #endif
    let children = childLayoutAnchors(snapshot)
    layoutCollectingAnchors = false
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.end(anchorsTrace)
    #endif
    if let layoutController {
      #if DEBUG || SOLARA_PERF_TRACE
      if LayoutTrace.enabled, ProcessInfo.processInfo.environment["SOLARA_LAYOUT_STACKS"] == "1" {
        LayoutTrace.event("layoutInputs", "\(shell.windowId) \(layoutRevision) sameInput:\(lastLayoutInput?.hasSameLayout(as: input) ?? false) sameAnchors:\(children == lastChildAnchors) \(String(reflecting: input)) anchors:\(children)")
      }
      #endif
      let changed = layoutController.apply(input: input, anchors: children)
      #if DEBUG || SOLARA_PERF_TRACE
      LayoutTrace.event("layoutPublished", "\(shell.windowId) \(layoutRevision) changed:\(changed)")
      #endif
      layoutGeneration = layoutController.layoutGeneration
      lastLayoutInput = input
      lastChildAnchors = children
      if changed || toolbarBecameReady, layoutReader != nil { sendLayoutAnchors(toolbarReady: toolbarReady) }
      return
    }
    if let lastLayoutInput, lastLayoutInput.hasSameLayout(as: input), children == lastChildAnchors {
      _ = layoutAnchors.restamp(input)
      return
    }
    layoutGeneration += 1
    guard layoutAnchors.publish(WindowAnchorBatch(snapshot: snapshot, anchors: children)) else { return }
    lastLayoutInput = input
    lastChildAnchors = children
    if layoutReader != nil { sendLayoutAnchors(toolbarReady: toolbarReady) }
  }

  private func childLayoutAnchors(_ snapshot: WindowLayoutSnapshot) -> [String: CGRect] {
    let input = snapshot.input
    var guests = NativePeek.anchors(shell.windowId)
    if let id = input.selectedTabId {
      guests["tour:page"] = snapshot.pages[id]
      if let column = NativeSidebarShell.column(shell.windowId), !column.isHiddenOrHasHiddenAncestor {
        column.layoutSubtreeIfNeeded()
        if let page = column.host.view.current, let row = page.frameOf(id) {
          guests["tour:tabs"] = page.convert(row, to: shell)
        }
      }
    }
    if input.presentation.chromeNavigationRow, let navigation = shell.view(in: .navigation) as? SidebarAddressBarView {
      navigation.layoutSubtreeIfNeeded()
      guests.merge(navigation.navigationFrames.mapValues { navigation.fullScreenRect($0, to: shell) }) { _, new in new }
      return guests
    }
    if input.layout.addressBarInSidebar {
      guard let bar = SidebarAddressBars.shared.existing(shell.windowId), bar.window === shell.window else { return guests }
      let field = bar.fullScreenRect(bar.fieldFrame, to: shell)
      guests.merge(["url": field, "urlField": field, "tour:commandBar": field]) { _, new in new }
      return guests
    }
    guard let id = input.selectedTabId else { return guests }
    let split = shell.card.subviews.compactMap { $0 as? SplitPanesView }.first
    guard let toolbar = split?.toolbar(id) ?? NativeToolbarHostView.host(windowId: shell.windowId, tabId: id)?.toolbar,
      toolbar.window === shell.window else { return guests }
    var anchors = toolbar.layoutAnchors.mapValues { toolbar.fullScreenRect($0, to: shell) }
    anchors["nativeURLBand"] = anchors["url"]
    anchors["url"] = snapshot.residualURLBand(tabId: id, trailingReservation: CGFloat(toolbar.state?.geometry.urlRight ?? 12), trafficLightsInset: shell.trafficLightsLeadingInset(for: toolbar))?.offsetBy(dx: 0, dy: shell.fullScreenPresentationOffset(for: toolbar))
    anchors["tour:commandBar"] = anchors["urlField"]
    if input.split == nil, !input.layout.topTabs { anchors["tour:sidebarButton"] = anchors["button:sidebar"] }
    return guests.merging(anchors) { _, new in new }
  }

  private func actualLayoutEndpoints(_ snapshot: WindowLayoutSnapshot) -> [String: CGRect] {
    var endpoints = childLayoutAnchors(snapshot)
    endpoints["card"] = shell.card.convert(shell.card.bounds, to: shell)
    if let panes = shell.card.subviews.first(where: { $0 is SplitPanesView }) {
      endpoints["paneHost"] = panes.convert(panes.bounds, to: shell)
    }
    if let overlays = PaneOverlays.shared.layer(windowId: shell.windowId) {
      endpoints["overlayHost"] = overlays.convert(overlays.bounds, to: shell)
    }
    if let sidebar = shell.view(in: .sidebar) { endpoints["sidebar"] = sidebar.convert(sidebar.bounds, to: shell) }
    if let chrome = NativeSidebarShell.column(shell.windowId)?.chrome, !chrome.isHidden {
      endpoints["sidebarHeader"] = chrome.convert(CGRect(x: 0, y: 0, width: chrome.bounds.width, height: chrome.headerHeight), to: shell)
      endpoints["sidebarFooter"] = chrome.convert(CGRect(x: 0, y: chrome.bounds.height - chrome.footerHeight,
        width: chrome.bounds.width, height: chrome.footerHeight), to: shell)
    }
    if let strip = shell.view(in: .topStrip) {
      endpoints["topStrip"] = strip.convert(strip.bounds, to: shell)
    } else if let strip = NativeTopStrip.hosts[shell.windowId]?.view {
      var ancestor: NSView? = strip
      while let view = ancestor, view !== shell {
        let frame = view.convert(view.bounds, to: shell)
        if abs(frame.width - shell.bounds.width) <= 0.5, abs(frame.height - ShellMetrics.topStripHeight) <= 0.5 {
          endpoints["topStrip"] = frame
          break
        }
        ancestor = view.superview
      }
    }
    for id in snapshot.panes.keys {
      if let layer = PaneOverlays.shared.layer(windowId: shell.windowId) as? PaneOverlaysView, layer.window === shell.window,
        let frame = layer.paneFrames[id] {
        endpoints["pane:\(id)"] = layer.convert(frame, to: shell)
      }
      if id == snapshot.input.peekTabId, let frame = NativePeek.paneFrame(shell.windowId, in: shell) {
        endpoints["pane:\(id)"] = frame
      }
      let slot: TabSlotKey = id == snapshot.input.peekTabId ? .peek(shell.windowId) : snapshot.input.split == nil ? .card(shell.windowId) : .pane(shell.windowId, id)
      if let page = TabSlots.shared.container(for: slot), page.window === shell.window {
        let viewport = page.convert(page.bounds, to: shell)
        endpoints["viewport:\(id)"] = viewport
        if let pane = endpoints["pane:\(id)"] { endpoints["page:\(id)"] = viewport.intersection(pane) }
      }
    }
    return endpoints
  }

  func anchorPayload() -> [String: Any]? {
    guard !layoutStopped, let batch = layoutAnchors.current else { return nil }
    let input = batch.snapshot.input
    return ["windowId": shell.windowId, "windowGeneration": windowGeneration, "generation": batch.snapshot.generation,
      "storeRevision": input.storeRevision, "anchors": batch.anchors.mapValues(Self.layoutRect),
      "sidebar": input.layout.addressBarInSidebar, "profileTitle": input.profileTitle, "profileNameWidth": input.profileNameWidth,
      "stripAvailableWidth": batch.snapshot.stripAvailableWidth]
  }

  func observationPayload() -> [String: Any] {
    ["windowGeneration": windowGeneration, "batch": anchorPayload() ?? NSNull()]
  }

  func observeLayoutAnchors(_ enabled: Bool, generation: UInt64?, reader: String) {
    guard !layoutStopped, enabled || generation != nil, generation == nil || generation == windowGeneration else { return }
    if enabled {
      if layoutReader != reader { lastSentLayoutAnchors = nil }
      layoutReader = reader
    } else if layoutReader == reader {
      layoutReader = nil
      lastSentLayoutAnchors = nil
    }
  }

  private func sendLayoutAnchors(toolbarReady: Bool) {
    let generation = layoutGeneration
    let reader = layoutReader
    Task { @MainActor [weak self] in
      guard let self, !self.layoutStopped, let reader, self.layoutReader == reader, self.layoutGeneration == generation,
        let batch = self.layoutAnchors.current, let payload = self.anchorPayload() else { return }
      guard batch.shouldSendGuestProjection(after: self.lastSentLayoutAnchors, toolbarReady: toolbarReady) else { return }
      self.lastSentLayoutAnchors = batch
      _ = await SettingsAdapters.js("window.layoutAnchors", self.shell.windowId, payload)
    }
  }

  private static func layoutRect(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

  func describeLayout() -> [String: Any]? {
    guard !layoutStopped, let batch = layoutAnchors.current else { return nil }
    let snapshot = batch.snapshot
    let input = snapshot.input
    let actual = actualLayoutEndpoints(snapshot)
    var expected = ["card": snapshot.frames.card]
    if let sidebar = snapshot.frames.sidebar { expected["sidebar"] = sidebar.offsetBy(dx: snapshot.frames.sidebarShift, dy: 0) }
    if let strip = snapshot.frames.topStrip { expected["topStrip"] = strip }
    if let header = snapshot.sidebarHeader { expected["sidebarHeader"] = header }
    if let footer = snapshot.sidebarFooter { expected["sidebarFooter"] = footer }
    for (id, rect) in snapshot.panes { expected["pane:\(id)"] = rect }
    for (id, rect) in snapshot.pages { expected["page:\(id)"] = rect }
    for (id, rect) in snapshot.pageViewports { expected["viewport:\(id)"] = rect }
    var errors: [String: CGFloat] = [:]
    var missing: [String] = []
    for (name, wanted) in expected {
      guard let found = actual[name] else { missing.append(name); continue }
      errors[name] = max(abs(wanted.minX - found.minX), abs(wanted.minY - found.minY), abs(wanted.maxX - found.maxX), abs(wanted.maxY - found.maxY))
    }
    func optional(_ rect: CGRect?) -> Any { rect.map(Self.layoutRect) ?? NSNull() }
    return ["windowGeneration": windowGeneration, "generation": snapshot.generation, "storeRevision": input.storeRevision,
      "latestStoreRevision": layoutRevision, "sidebarPosition": input.layout.sidebarSide.rawValue, "backingScale": input.backingScale, "bounds": Self.layoutRect(input.bounds),
      "sidebarWidth": input.layout.sidebarWidth,
      "presentation": ["sidebarWidth": shell.input.sidebarWidth, "railProgress": shell.input.railProgress.map { $0 as Any } ?? NSNull()],
      "card": Self.layoutRect(snapshot.frames.card), "content": Self.layoutRect(snapshot.content), "sidebar": optional(expected["sidebar"]), "topStrip": optional(snapshot.frames.topStrip),
      "sidebarHeader": optional(snapshot.sidebarHeader), "sidebarFooter": optional(snapshot.sidebarFooter),
      "stripAvailableWidth": snapshot.stripAvailableWidth, "panes": snapshot.panes.mapValues(Self.layoutRect),
      "pages": snapshot.pages.mapValues(Self.layoutRect), "pageViewports": snapshot.pageViewports.mapValues(Self.layoutRect),
      "toolbars": snapshot.toolbars.mapValues(Self.layoutRect),
      "anchors": batch.anchors.mapValues(Self.layoutRect), "actual": actual.mapValues(Self.layoutRect), "errors": errors,
      "missing": missing.sorted(), "maxError": errors.values.max() ?? 0,
      "current": makeLayoutInput().map { $0.storeRevision == input.storeRevision && $0.hasSameLayout(as: input) && childLayoutAnchors(WindowLayoutSnapshot.of($0, generation: snapshot.generation)) == lastChildAnchors } ?? false,
      "profileId": input.profileId, "selectedTabId": input.selectedTabId ?? NSNull(),
      "toolbarModes": snapshot.toolbarModes.mapValues { $0.rawValue }, "shownTops": snapshot.shownTops,
      "fullscreenTabId": snapshot.fullscreenTabId ?? NSNull(), "windowFullscreen": input.windowFullscreen, "windowTransitioning": input.windowFullscreenTransition,
      "presentationFacts": input.pageFacts.mapValues { fact -> [String: Any] in
        ["registration": fact.registration, "fullscreen": fact.fullscreen, "scrolledDown": fact.scrolledDown, "peek": fact.peek, "top": fact.top.map { $0 as Any } ?? NSNull()]
      },
      "topTabs": input.layout.topTabs, "addressBarInSidebar": input.layout.addressBarInSidebar]
  }
}

#if SOLARA_PROBES
@MainActor
enum WindowShellProbeSamples {
  static var hitCosts: [String: [String: String]] = [:]
  static var pointerStreams: [String: [String: Double]] = [:]
  static var pointerLatencies: [String: [String: Any]] = [:]
}

@MainActor
public enum WindowShellRead {
  public static func hoverMeasurements(windowId: String) -> [String: Any]? {
    guard NativeWindowShell.host(windowId) != nil else { return nil }
    return ["hitCost": WindowShellProbeSamples.hitCosts[windowId] ?? [:],
      "pointerStream": WindowShellProbeSamples.pointerStreams[windowId] ?? [:],
      "pointerLatency": WindowShellProbeSamples.pointerLatencies[windowId] ?? [:],
      "sidebarDockLive": NativeSidebarDock.describe(windowId)?["live"] ?? NSNull()]
  }

  public static func accessibilityReach(windowId: String) -> [String: Int]? {
    NativeWindowShell.host(windowId)?.shell.accessibilityReach()
  }

  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let source = NativeWindowShell.describe(windowId) else { return nil }
    let work = NativeWorkCounters.snapshot()
    let hosts = (work["hosts"] as? [[String: Any]] ?? []).filter { $0["windowId"] as? String == windowId }
    let counts = Dictionary(uniqueKeysWithValues: hosts.compactMap { host -> (String, Int)? in
      guard let kind = host["kind"] as? String, let count = host["count"] as? Int else { return nil }
      return (kind, count)
    })
    let chrome = source["nativeLayoutChrome"] as? [String: Any]
    return ["card": source["card"] ?? NSNull(), "order": source["order"] ?? [],
      "reactOnTop": source["reactOnTop"] ?? false, "nativeWork": work,
      "contract": ["bounds": source["bounds"] ?? NSNull(), "sidebar": source["sidebar"] ?? NSNull(),
        "topStrip": source["topStrip"] ?? NSNull(), "slots": source["slots"] ?? [],
        "nativeLayout": source["nativeLayout"] ?? false,
        "controllerStoreSubscriptions": source["layoutControllerSubscriptions"] ?? 0,
        "legacyLayoutStoreSubscriptions": NativeWorkCounters.shellStoreSubscriptions,
        "childStoreSubscriptions": chrome?["childStoreSubscriptions"] ?? 0,
        "ownerCount": counts["ShellHost"] ?? 0,
        "hostCounts": ["ShellHost": counts["ShellHost"] ?? 0, "WindowLayoutController": counts["WindowLayoutController"] ?? 0,
          "sidebar": counts["sidebar"] ?? 0, "topStrip": counts["topStrip"] ?? 0],
        "pageIdentities": TabPoolHost.shared.probePageIdentities(windowId)]]
  }

  public static func hitSlot(windowId: String, x: Double, y: Double) -> String? {
    guard let shell = NativeWindowShell.host(windowId)?.shell, shell.window != nil else { return nil }
    let point = shell.convert(NSPoint(x: x, y: y), to: nil)
    return shell.slotUnderPointer(at: point)?.rawValue
  }

  public static func hitView(windowId: String, x: Double, y: Double) -> String? {
    guard let window = NativeWindowShell.host(windowId)?.shell.window, let content = window.contentView else { return nil }
    let point = content.convert(NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y), to: nil)
    return content.superview?.hitTest(point).map { String(describing: type(of: $0)) }
  }

  public static func reactBlockers(windowId: String, step: Double) -> [[String: Any]]? {
    NativeWindowShell.host(windowId)?.reactBlockers(step: CGFloat(step))
  }
}
#endif

#if DEBUG
extension ShellHost {
  func reactBlockers(step: CGFloat) -> [[String: Any]] {
    guard shell.reactOnTop, let root = shell.view(in: .react), !root.isHidden, step > 0 else { return [] }
    let frames = shell.frames
    let areas = [frames.card, frames.sidebar?.offsetBy(dx: frames.sidebarShift, dy: 0), frames.topStrip].compactMap { $0 }.filter { !$0.isEmpty }
    var found: [ObjectIdentifier: [String: Any]] = [:]
    for area in areas {
      for y in stride(from: area.minY + step / 2, to: area.maxY, by: step) {
        for x in stride(from: area.minX + step / 2, to: area.maxX, by: step) {
          guard let hit = root.hitTest(NSPoint(x: x, y: y)), Self.drawsNothing(hit), found[ObjectIdentifier(hit)] == nil else { continue }
          let box = hit.convert(hit.bounds, to: shell)
          found[ObjectIdentifier(hit)] = [
            "class": NSStringFromClass(type(of: hit)),
            "nativeID": (hit.responds(to: Selector(("nativeID"))) ? hit.value(forKey: "nativeID") as? String : nil) ?? NSNull(),
            "testID": hit.accessibilityIdentifier(),
            "reactTag": (hit.responds(to: Selector(("reactTag"))) ? hit.value(forKey: "reactTag") : nil) ?? NSNull(),
            "frame": [box.minX, box.minY, box.width, box.height],
            "at": [x, y],
            "ancestors": Self.reactAncestors(of: hit, below: root),
          ]
        }
      }
    }
    return Array(found.values)
  }

  private static func reactAncestors(of view: NSView, below root: NSView) -> [[Any]] {
    var out: [[Any]] = []
    for ancestor in sequence(first: view.superview, next: { $0?.superview }) {
      guard let ancestor, ancestor !== root, ancestor.responds(to: Selector(("reactTag"))), let tag = ancestor.value(forKey: "reactTag") as? NSNumber else { break }
      out.append([tag, ancestor.bounds.width, ancestor.bounds.height])
    }
    return out
  }

  private static func drawsNothing(_ view: NSView) -> Bool {
    let name = NSStringFromClass(type(of: view))
    guard name.hasPrefix("RCT"), !name.contains("Text"), !name.contains("Image") else { return false }
    if view.responds(to: Selector(("backgroundColor"))), let color = view.value(forKey: "backgroundColor") as? NSColor, (color.usingColorSpace(.sRGB)?.alphaComponent ?? 1) > 0 { return false }
    return view.layer?.contents == nil
  }
}
#endif

enum ShellLayoutPush {
  static func apply(_ given: [String: Any], to input: inout DockedLayoutInput, keepWidth: Bool = false) {
    let number = { (key: String) in (given[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
    let flag = { (key: String) in (given[key] as? NSNumber)?.boolValue }
    if let dock = number("dock") { input.dock = dock }
    if !keepWidth, let width = number("sidebarWidth") { input.sidebarWidth = width }
    if let room = number("sidePanel") { input.sidePanel = max(0, room) }
    if let topTabs = flag("topTabs") { input.topTabs = topTabs }
    if let fullscreen = flag("fullscreen") { input.fullscreen = fullscreen }
    if let addressBar = flag("addressBarInSidebar") { input.addressBarInSidebar = addressBar }
    if let away = flag("away") { input.away = away }
  }
}

final class ShellStoreCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: (BrowserState, Int)?
  private var acceptedRevision = -1
  private var scheduled = false

  func receive(_ state: BrowserState, revision: Int) {
    let admitted = lock.withLock { () -> Bool in
      guard revision > acceptedRevision else { return false }
      acceptedRevision = revision
      latest = (state, revision)
      return true
    }
    guard admitted else { return }
    if Thread.isMainThread {
      let pending = lock.withLock { () -> (BrowserState, Int)? in
        defer { latest = nil }
        return latest
      }
      if let pending { MainActor.assumeIsolated { NativeWindowShell.windowsChanged(pending.0, revision: pending.1) } }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let pending = lock.withLock { () -> (BrowserState, Int)? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      if let pending { MainActor.assumeIsolated { NativeWindowShell.windowsChanged(pending.0, revision: pending.1) } }
    }
  }
}

public class WindowShellModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraWindowShell")

    #if DEBUG || SOLARA_PERF_TRACE
    Function("layoutTrace") { (reset: Bool) -> String in
      if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SolaraLayoutTraceFlush") {
        unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
      }
      return LayoutTrace.take(reset: reset)
    }
    Function("layoutTraceMark") { (stage: String, detail: String) in LayoutTrace.event("command", "\(stage) \(detail)") }
    #endif

    OnCreate {
      if Thread.isMainThread {
        MainActor.assumeIsolated { NativeWindowShell.install() }
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { NativeWindowShell.install() } }
      }
    }

    Function("active") { (windowId: String) -> Bool in
      NativeWindowShell.enabled && NativeWindowShell.active(windowId)
    }

    Function("nativeLayout") { (windowId: String) -> Bool in NativeWindowShell.nativeLayoutActive(windowId) }
    Function("nativeLayoutGeneration") { (windowId: String) -> Double in Double(NativeWindowShell.nativeLayoutGeneration(windowId)) }

    Function("pagesPool") { () -> Bool in NativeSplitChrome.panesEnabled }
    Function("paneRoots") { (windowId: String) -> Bool in NativePaneRoots.active(windowId) }
    Function("paneFallbacks") { (windowId: String) -> String in NativePaneRoots.fallbackSnapshot(windowId) }
    Function("paneFallbackState") { (windowId: String) -> String in NativePaneRoots.fallbackState(windowId) }
    Function("admitPaneFallback") { (windowId: String, generation: Double, revision: Double) -> String in
      guard generation.isFinite, revision.isFinite, generation >= 0, revision >= 0,
        generation <= 9_007_199_254_740_991, revision <= 9_007_199_254_740_991,
        generation.rounded(.towardZero) == generation, revision.rounded(.towardZero) == revision else { return "{}" }
      return NativePaneRoots.admitFallbackSnapshot(windowId, windowGeneration: UInt64(generation), revision: UInt64(revision))
    }

    AsyncFunction("releasePaneFallback") { (windowId: String, tabId: String, generation: Double, lease: Double) in
      MainActor.assumeIsolated {
        guard generation.isFinite, generation >= 0, generation <= 9_007_199_254_740_991, generation.rounded(.towardZero) == generation,
          lease.isFinite, lease > 0, lease <= 9_007_199_254_740_991, lease.rounded(.towardZero) == lease else { return }
        NativePaneRoots.releaseFallback(windowId, tabId: tabId, generation: UInt64(generation), lease: UInt64(lease))
      }
    }.runOnQueue(.main)
    Function("mainOnTop") { (windowId: String) -> Bool in NativeWindowShell.mainOnTop && NativeWindowShell.active(windowId) }

    AsyncFunction("setBackdrop") { (windowId: String, json: String) in
      FrameUpdates.readOnMain { NativeWindowShell.setBackdrop(windowId, json) }
    }.runOnQueue(.main)

    AsyncFunction("setSidePanel") { (windowId: String, json: String?) in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.setSidePanel(json) }
    }.runOnQueue(.main)

    AsyncFunction("setSheet") { (windowId: String, json: String?) in
      FrameUpdates.readOnMain { NativeSheets.set(windowId, json) }
    }.runOnQueue(.main)

    AsyncFunction("setLayout") { (windowId: String, layout: [String: Any]) in
      nonisolated(unsafe) let given = layout
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), !host.ownsNativeLayout else { return }
        let shell = host.shell
        if let right = given["peekRight"] as? NSNumber {
          NativeSidebarDock.setReactPeekRight(windowId, CGFloat(right.doubleValue))
        } else if given["sidebarWidth"] != nil {
          NativeSidebarDock.setReactPeekRight(windowId, 0)
        }
        var layout = given
        if !shell.widthDragActive, given["sidebarWidth"] is NSNumber, NativeSidebarDock.railShown(windowId) {
          layout["sidebarWidth"] = SidebarRail.width
        }
        shell.update { ShellLayoutPush.apply(layout, to: &$0, keepWidth: shell.widthDragActive) }
      }
    }.runOnQueue(.main)

    AsyncFunction("setModal") { (windowId: String, owner: String, shown: Bool) in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.shell.setModal(owner, shown: shown) }
    }.runOnQueue(.main)

    AsyncFunction("accessibilityReach") { (windowId: String) -> [String: Int]? in
      FrameUpdates.readOnMain { NativeWindowShell.host(windowId)?.shell.accessibilityReach() }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devCaptionIslandSnapshot") { (windowId: String, path: String) -> Bool in
      FrameUpdates.readOnMain {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false,
          let shell = NativeWindowShell.host(windowId)?.shell,
          let frame = shell.window?.contentView?.superview,
          let island = frame.subviews.compactMap({ $0 as? FullScreenIslandView }).first else { return false }
        return island.devSnapshot(path)
      }
    }.runOnQueue(.main)

    AsyncFunction("devCaptionIsland") { (windowId: String, reveal: Double, menuBottom: Double) -> String in
      FrameUpdates.readOnMain {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOLARA_BACKGROUND"] == "1", environment["SOLARA_DATA_DIR"]?.isEmpty == false,
          reveal.isFinite, menuBottom.isFinite,
          let shell = NativeWindowShell.host(windowId)?.shell,
          let window = shell.window, let frame = window.contentView?.superview,
          let island = frame.subviews.compactMap({ $0 as? FullScreenIslandView }).first else { return "null" }
        let payload = island.devReveal(CGFloat(reveal), menuBottom: CGFloat(menuBottom), fullscreen: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
    #endif

    AsyncFunction("devCover") { (windowId: String, rect: [Double]?, hidden: Bool?) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId) else { return false }
        let id = NSUserInterfaceItemIdentifier("devCover")
        if let hidden, let cover = host.shell.overlay.subviews.first(where: { $0.identifier == id }) {
          cover.isHidden = hidden
          return true
        }
        host.shell.overlay.subviews.filter { $0.identifier == id }.forEach { $0.removeFromSuperview() }
        if let rect, rect.count == 4 {
          let cover = NSView(frame: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
          cover.identifier = id
          cover.wantsLayer = true
          cover.layer?.backgroundColor = NSColor.systemPink.cgColor
          host.shell.overlay.addSubview(cover)
        }
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devRefusePaneRoot") { (tabId: String, refused: Bool) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        if refused { NativePaneRoots.refusedTabs.insert(tabId) } else { NativePaneRoots.refusedTabs.remove(tabId) }
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devLatePaneTeardown") { (seconds: Double) -> Bool in
      #if DEBUG
      return FrameUpdates.readOnMain {
        NativePaneRoots.lateTeardown = seconds
        return true
      }
      #else
      return false
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devHitCost") { (windowId: String, x: Double, y: Double) -> [String: String] in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), host.shell.window != nil else { return [:] }
        let point = host.shell.convert(NSPoint(x: x, y: y), to: nil)
        let start = DispatchTime.now().uptimeNanoseconds
        var slot: WindowShellView.Slot?
        for _ in 0..<1000 { slot = host.shell.slotUnderPointer(at: point) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / 1000
        let result = ["micros": String(micros), "slot": slot?.rawValue ?? ""]
        #if SOLARA_PROBES
        WindowShellProbeSamples.hitCosts[windowId] = result
        #endif
        return result
      }
      #else
      return [:]
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devLayerHitCosts") { (windowId: String, x: Double, y: Double) -> [[String: String]] in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), host.shell.window != nil else { return [] }
        let shell = host.shell
        let point = NSPoint(x: x, y: y)
        return shell.subviews.reversed().filter { !$0.isHidden }.map { layer in
          let start = DispatchTime.now().uptimeNanoseconds
          var hit: NSView?
          for _ in 0..<1000 { hit = layer.hitTest(point) }
          let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / 1000
          var views = 0
          func count(_ view: NSView) {
            views += 1
            view.subviews.forEach(count)
          }
          count(layer)
          return [
            "layer": shell.slot(of: layer)?.rawValue ?? NSStringFromClass(type(of: layer)), "micros": String(micros),
            "hit": hit.map { NSStringFromClass(type(of: $0)) } ?? "", "frame": NSStringFromRect(layer.frame), "views": String(views),
          ]
        }
      }
      #else
      return []
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devPointerStream") { (windowId: String, points: [[Double]], hz: Double, promise: Promise) in
      #if DEBUG
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let window = host.shell.window else { return reply.resolve([String: Double]()) }
        let shell = host.shell
        let inWindow = points.map { shell.convert(NSPoint(x: $0[0], y: $0[1]), to: nil) }
        shell.devResetPointerStats()
        let start = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
          for point in inWindow {
            shell.devNotePointer(point)
            try? await Task.sleep(nanoseconds: UInt64(1e9 / hz))
          }
          try? await Task.sleep(nanoseconds: 50_000_000)
          let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
          let result = [
            "moves": Double(inWindow.count), "lookups": Double(shell.devPointerLookups), "seconds": seconds,
            "frame": 1 / Double(window.screen?.maximumFramesPerSecond ?? 60),
            "lookupMicros": Double(shell.devPointerLookupNanos) / 1000, "coreShare": Double(shell.devPointerLookupNanos) / 1e9 / seconds,
          ]
          #if SOLARA_PROBES
          WindowShellProbeSamples.pointerStreams[windowId] = result
          #endif
          reply.resolve(result)
        }
      }
      #else
      promise.resolve([String: Double]())
      #endif
    }.runOnQueue(.main)

    AsyncFunction("devPointerLatency") { (windowId: String, x: Double, y: Double, promise: Promise) in
      #if DEBUG
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let window = host.shell.window else { return reply.resolve([String: Any]()) }
        let shell = host.shell
        let start = DispatchTime.now().uptimeNanoseconds
        var answered = false
        let finish: (Bool) -> Void = { changed in
          guard !answered else { return }
          answered = true
          shell.devPointerResolved = nil
          let result: [String: Any] = [
            "changed": changed, "slot": x < 0 ? "" : shell.slotUnderPointer(at: shell.convert(NSPoint(x: x, y: y), to: nil))?.rawValue ?? "",
            "ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, "frameMs": 1000 / Double(window.screen?.maximumFramesPerSecond ?? 60),
          ]
          #if SOLARA_PROBES
          WindowShellProbeSamples.pointerLatencies[windowId] = result
          #endif
          reply.resolve(result)
        }
        shell.devPointerResolved = { changed in finish(changed) }
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          finish(false)
        }
        shell.devNotePointer(x < 0 ? nil : shell.convert(NSPoint(x: x, y: y), to: nil))
      }
      #else
      promise.resolve([String: Any]())
      #endif
    }.runOnQueue(.main)

    Function("peekNative") { (windowId: String) -> Bool in NativePeek.enabled && NativeWindowShell.active(windowId) }

    AsyncFunction("peekClose") { (windowId: String, tabId: String, generation: UInt64) -> Bool in
      FrameUpdates.readOnMain { NativePeek.close(windowId, tabId: tabId, generation: generation) }
    }.runOnQueue(.main)

    AsyncFunction("peekExpand") { (windowId: String, tabId: String, generation: UInt64, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      FrameUpdates.readOnMain { NativePeek.expand(windowId, tabId: tabId, generation: generation) { reply.resolve($0) } }
    }.runOnQueue(.main)

    AsyncFunction("devReactBlockers") { (windowId: String, step: Double) -> String in
      #if DEBUG
      return FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId), let data = try? JSONSerialization.data(withJSONObject: host.reactBlockers(step: step)) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
      #else
      return "null"
      #endif
    }.runOnQueue(.main)

    #if SOLARA_PROBES
    AsyncFunction("devLaunchWork") { (command: String, options: [String: Any]) -> String in
      let given = NativeLaunchWorkOptions(options)
      return MainActor.assumeIsolated { NativeLaunchWork.dev(command, given) }
    }.runOnQueue(.main)

    AsyncFunction("nativeWork") { (reset: Bool) -> String in
      MainActor.assumeIsolated {
        let work = NativeWorkCounters.snapshot()
        if reset { NativeWorkCounters.reset() }
        guard let data = try? JSONSerialization.data(withJSONObject: work) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
    #endif

    Function("layoutAnchorsAvailable") { (windowId: String) -> Bool in
      NativeWindowShell.active(windowId) && NativeStoreHandle.ownedWorkspaceAtLaunch
    }

    AsyncFunction("observeLayoutAnchors") { (windowId: String, enabled: Bool, generation: Int?, reader: String) -> String in
      FrameUpdates.readOnMain {
        guard let host = NativeWindowShell.host(windowId) else { return "null" }
        if let generation, generation < 0 { return "null" }
        host.observeLayoutAnchors(enabled, generation: generation.map(UInt64.init), reader: reader)
        guard let data = try? JSONSerialization.data(withJSONObject: host.observationPayload()) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)

    AsyncFunction("layoutAnchors") { (windowId: String) -> String in
      FrameUpdates.readOnMain {
        guard let info = NativeWindowShell.host(windowId)?.anchorPayload(), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)

    AsyncFunction("describe") { (windowId: String) -> String in
      FrameUpdates.readOnMain {
        guard let info = NativeWindowShell.describe(windowId), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)
  }
}
