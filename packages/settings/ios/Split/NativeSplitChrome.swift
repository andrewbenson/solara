import AppKit
import Foundation
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeSplitChrome {
  static let themeTopic = "split.theme"
  static let dragTopic = "split.drag"
  static let toastTopic = "split.toast"
  static let noticeTopic = "split.notice"
  static let toolbarTopic = "split.toolbar"
  nonisolated static var panesEnabled: Bool { NativeWindowShell.enabled && LaunchSwitches.shared.isOn(.nativePagesPool) }

  private static var started = false
  private static var owners: [String: NativePaneLayoutHost] = [:]
  private static var views: [String: SplitChromeView] = [:]
  private static var panes: [String: SplitPanesView] = [:]
  private static var overlays: [String: PaneOverlaysView] = [:]
  private static var dropZones: [String: SplitDropZone] = [:]
  private static var toolbars: [String: [String: ToolbarState]] = [:]
  private static var toolbarPresenters: [String: [String: NativeToolbarPresenter]] = [:]
  private static let favicons: SidebarFavicons = {
    let made = SidebarFavicons()
    made.loader = { request in try await NativeSidebar.favicon(request) }
    return made
  }()
  private static var listener: Int?
  private static let commits = SplitChromeCommits()

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(themeTopic) { value in applyTheme(value) }
    _ = SettingsJS.shared.observe(dragTopic) { value in applyDrag(value) }
    _ = SettingsJS.shared.observe(toastTopic) { value in applyToast(value) }
    _ = SettingsJS.shared.observe(noticeTopic) { value in applyNotice(value) }

    if panesEnabled { _ = SettingsJS.shared.observe(toolbarTopic) { value in applyToolbars(value) } }
    #if DEBUG
    _ = SettingsJS.shared.observe("split.dev") { value in SplitChromeDevRun.start(value, views) }
    #endif
    if !NativeWindowShell.nativeLayout, let store = NativeStoreHandle.store {
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
    applyTheme(SettingsJS.shared.latestValue(themeTopic))
  }

  private static let renderToken = NSObject()
  private static var pendingState: BrowserState?

  static func commit(_ state: BrowserState) {
    pendingState = state
    FrameUpdates.schedule(renderToken) {
      guard let state = pendingState else { return }
      pendingState = nil
      render(state)
    }
  }

  private static func render(_ state: BrowserState) {
    for (id, view) in views where owners[id] == nil {
      if view.superview == nil {
        views[id] = nil
        if let zone = dropZones.removeValue(forKey: id) { TabDragSession.unregister(zone) }
      } else {
        view.update(state: state)
      }
    }
    for (id, view) in overlays where owners[id] == nil {
      if view.superview == nil { overlays[id] = nil } else { view.update(state: state) }
    }
    for (id, view) in panes where owners[id] == nil {
      if view.superview == nil { panes[id] = nil } else { view.update(state: state) }
    }
  }

  private static func cardContainer(for window: String) -> NSView? { NativeWindowShell.host(window)?.shell.card }

  static func setShareBands(_ heights: [String: CGFloat], windowId: String) {
    if owners[windowId] != nil { NativeWindowShell.host(windowId)?.scheduleLayoutProjection() }
    if let overlay = overlays[windowId], overlay.superview != nil { overlay.bandHeights = heights }
    if let view = panes[windowId], view.superview != nil { view.bandHeights = heights }
  }

  static func setShareBandClip(_ clip: NSView?, windowId: String, tabId: String) {
    guard let overlay = overlays[windowId], overlay.superview != nil else { return }
    overlay.setBand(clip, tabId: tabId)
  }

  static func setLiveTop(_ top: CGFloat?, windowId: String, tabId: String) {
    if owners[windowId] != nil { NativeWindowShell.host(windowId)?.scheduleLayoutProjection(); return }
    guard let view = panes[windowId], view.superview != nil else { return }
    view.setLiveTop(top, tabId: tabId)
  }

  private static func panesView(_ windowId: String, shell supplied: WindowShellView? = nil) -> SplitPanesView? {
    if supplied == nil, NativeWindowShell.nativeLayoutActive(windowId) { return owners[windowId]?.panes }
    guard panesEnabled else { return nil }
    if supplied == nil, let view = panes[windowId], view.superview != nil { return view }
    panes[windowId] = nil
    guard let card = supplied?.card ?? cardContainer(for: windowId) else { return nil }
    let view = SplitPanesView(windowId: windowId)
    view.favicons = favicons
    view.frame = card.bounds
    view.autoresizingMask = [.width, .height]
    view.onToolbarClick = { [weak view] tabId, click in
      let source = view?.toolbar(tabId)
      if NativeToolbarActions.perform(click, source: source, windowId: windowId,
        target: source?.state?.tabId == tabId ? .pane(tabId) : nil) { return }
      if let toolbar = view?.toolbar(tabId),
        click.id == "urlEdit" || click.kind == .menu || toolbar.state?.url?.developer == nil,
        NativeOmniboxActions.addressClick(click, windowId: windowId, tabId: tabId, view: toolbar) {
        if click.id == "urlEdit", click.kind == .submit {
          Task { @MainActor in _ = await SettingsAdapters.js("split.toolbarClick", windowId, tabId, ["id": "urlEdit", "kind": "cancel", "nativeActions": true]) }
        }
        return
      }
      let payload: [String: Any] = ["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()]
      let send: () -> Void = {
        #if DEBUG
        didSendToolbarClick?(windowId, tabId, click)
        #endif
        Task { @MainActor in _ = await SettingsAdapters.js("split.toolbarClick", windowId, tabId, payload) }
      }
      if let toolbar = view?.toolbar(tabId), click.id == "urlEdit" {
        if click.kind == .focus { NativeExtensionActionPopup.dropHeldFieldBlur(from: toolbar) }
        if click.kind == .blur {
          toolbar.onHiddenOrDetached = { [weak toolbar] in
            guard let toolbar else { return }
            NativeExtensionActionPopup.flushHeldFieldBlur(from: toolbar)
          }
          if NativeExtensionActionPopup.holdFieldBlur(from: toolbar, fieldContainer: toolbar, flush: send) { return }
        }
      }
      send()
    }
    view.onToolbarGeometryChange = { _ in NativeWindowShell.host(windowId)?.layoutGeometryChanged() }
    view.onToolbarAnchors = { tabId, anchors in
      NativeExtensionActionPopup.anchorsChanged(window: ShellDrag.window(windowId), tabId: tabId, anchors: anchors)
      let payload = anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
      Task { @MainActor in _ = await SettingsAdapters.js("split.toolbarAnchors", windowId, tabId, payload) }
    }
    view.onNavigate = { tabId, text in _ = try? NativeStoreHandle.store?.dispatch(Command("navigate", [.string(tabId), .string(text)]), origin: .native) }
    view.onReplace = { tabId, other in _ = try? NativeStoreHandle.store?.dispatch(Command("replaceSplitPane", [.string(tabId), .string(other)]), origin: .native) }
    if let overlay = overlays[windowId], overlay.superview === card { card.addSubview(view, positioned: .below, relativeTo: overlay) } else { card.addSubview(view) }
    view.setToolbarStates(toolbars[windowId] ?? [:])
    if supplied == nil, let state = NativeStoreHandle.store?.state { view.update(state: state) }
    panes[windowId] = view
    return view
  }

  private static func view(_ windowId: String, shell supplied: WindowShellView? = nil) -> SplitChromeView? {
    if supplied == nil, NativeWindowShell.nativeLayoutActive(windowId) { return owners[windowId]?.chrome }
    if supplied == nil, let view = views[windowId], view.superview != nil { return view }
    views[windowId] = nil
    guard let shell = supplied ?? NativeWindowShell.host(windowId)?.shell else { return nil }
    let view = SplitChromeView(windowId: windowId)
    view.onResize = { splitId, sizes, stack in
      var options: JSONObject = [:]
      if let sizes { options["sizes"] = .array(sizes.map { .number($0) }) }
      if let stack { options["stackSizes"] = .array(stack.map { .number($0) }) }
      _ = try? NativeStoreHandle.store?.dispatch(Command("updateSplit", [.string(splitId), .object(options)]), origin: .native)
      FrameUpdates.flush()
    }
    view.onToastHidden = { [weak shell] id in
      shell?.coverChanged()
      Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "hidden") }
    }
    view.onToastAction = { id in Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "action") } }
    shell.mount(.splitChrome, view)
    let zone = SplitDropZone(windowId: windowId, chrome: view)
    zone.state = { NativeStoreHandle.store?.state }
    zone.covered = { NativeSidebarDock.peekCovers(windowId, point: $0) }
    zone.onDrop = { tabId, target, side in
      let options: JSONObject = ["tabId": .string(tabId), "anchorTabId": .string(target), "side": .string(side.rawValue)]
      _ = try? NativeStoreHandle.store?.dispatch(Command("openSplitPane", [.string(windowId), .object(options)]), origin: .native)
      FrameUpdates.flush()
    }
    if let old = dropZones[windowId] { TabDragSession.unregister(old) }
    dropZones[windowId] = zone
    TabDragSession.register(zone, windowId: windowId, priority: .split)
    let overlay = PaneOverlaysView(windowId: windowId)
    overlay.frame = shell.card.bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.onCoverChanged = { [weak shell] in shell?.coverChanged() }
    shell.card.addSubview(overlay)
    overlays[windowId]?.removeFromSuperview()
    overlays[windowId] = overlay
    if supplied == nil, let state = NativeStoreHandle.store?.state { overlay.update(state: state) }
    if supplied == nil, let state = NativeStoreHandle.store?.state { view.update(state: state) }
    if let notice = windows(SettingsJS.shared.latestValue(noticeTopic))?[windowId] { view.setNotice(SplitToastSpec(notice)) }
    views[windowId] = view
    return view
  }

  private static func windows(_ value: Any?) -> [String: [String: Any]]? {
    guard let o = value as? [String: Any], o["v"] as? Int == 1 else { return nil }
    return o["windows"] as? [String: [String: Any]]
  }

  private static func applyTheme(_ value: Any?) {
    guard let all = windows(value) else { return }
    for (windowId, entry) in all {
      guard let view = view(windowId) else { continue }
      let theme = SplitChromeTheme(entry["theme"] as? [String: Any] ?? [:])
      if let owner = owners[windowId] {
        owner.setTheme(theme, covered: false)
        continue
      }
      let fullscreenTab = entry["fullscreenTab"] as? String
      view.setChrome(theme: theme, fullscreenTab: fullscreenTab, covered: entry["covered"] as? Bool ?? false)
      if let overlay = overlays[windowId] {
        overlay.toolbarHeight = entry["toolbar"] as? Bool ?? true ? ShellMetrics.toolbarHeight : 0
        overlay.setFullscreenTab(fullscreenTab)
        overlay.pageTops = (entry["pageTops"] as? [String: NSNumber] ?? [:]).mapValues { CGFloat($0.doubleValue) }
      }
      guard let panes = panesView(windowId) else { continue }
      panes.theme = theme
      panes.cardColor = theme.color("card", dark: "rgba(18,18,18,0.5)", light: "rgba(255,255,255,0.7)")
      panes.toolbarHeight = entry["toolbar"] as? Bool ?? true ? ShellMetrics.toolbarHeight : 0
      panes.small = entry["small"] as? Bool ?? false
      panes.setFullscreenTab(fullscreenTab)
      panes.pagesPooled = TabPoolHost.available
      if let shell = NativeWindowShell.host(windowId)?.shell { panes.onCardStyle = { [weak shell] in shell?.cardStyle = $0 } }
    }
  }

  static func refreshPinnedPages() {
    for (id, owner) in owners { owner.setFrozen(NativePinnedPageCommands.presentations(windowId: id)) }
  }

  static func adopt(shell: WindowShellView, generation: UInt64) -> NativePaneLayoutHost? {
    let id = shell.windowId
    guard let chrome = view(id, shell: shell), let panes = panesView(id, shell: shell),
      let overlays = overlays[id], let zone = dropZones[id] else { return nil }
    let owner = NativePaneLayoutHost(shell: shell, generation: generation, chrome: chrome, panes: panes, overlays: overlays, zone: zone)
    owners[id] = owner
    return owner
  }

  static func end(_ owner: NativePaneLayoutHost) {
    let id = owner.shell.windowId
    if owners[id] === owner { owners[id] = nil }
    if views[id] === owner.chrome { views[id] = nil }
    if panes[id] === owner.panes { panes[id] = nil }
    if overlays[id] === owner.overlays { overlays[id] = nil }
    if dropZones[id] === owner.zone { dropZones[id] = nil }
  }

  static func toolbar(windowId: String, tabId: String) -> ToolbarView? { owners[windowId]?.panes.toolbar(tabId) }

  #if DEBUG
  private static var didSendToolbarClick: ((String, String, ToolbarClick) -> Void)?

  static func devRetireDeveloperURL(windowId: String, from tabId: String, to nextId: String, text: String) -> String {
    var result: [String: Any] = ["accepted": false]
    func encoded() -> String {
      guard let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return "{}" }
      return json
    }
    func refused(_ reason: String) -> String {
      result["reason"] = reason
      return encoded()
    }
    let environment = ProcessInfo.processInfo.environment
    guard environment["SOLARA_BACKGROUND"] == "1" else { return refused("background-required") }
    guard environment["SOLARA_DATA_DIR"]?.isEmpty == false else { return refused("data-directory-required") }
    guard NativeOmniboxActions.ownsActions else { return refused("native-actions-unavailable") }
    guard let store = NativeStoreHandle.store else { return refused("store-unavailable") }
    guard store.state.activeTabId(windowId) == tabId else { return refused("source-not-active") }
    guard tabId != nextId else { return refused("destination-is-source") }
    guard store.state.tabs[nextId]?.windowId == windowId else { return refused("destination-window-mismatch") }
    guard !store.state.splits.values.contains(where: { $0.tabIds.contains(tabId) || $0.tabIds.contains(nextId) }) else { return refused("split-tab") }
    guard let host = NativeWindowShell.host(windowId) else { return refused("window-host-unavailable") }
    guard let owner = owners[windowId] else { return refused("pane-owner-unavailable") }
    guard let toolbar = owner.panes.toolbar(tabId) else { return refused("toolbar-unavailable") }
    guard let field = toolbar.urlEditView as? NSTextField else { return refused("url-field-unavailable") }
    guard let window = field.window else { return refused("url-field-detached") }
    if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
      guard window.makeFirstResponder(field) else { return refused("url-field-focus-refused") }
    }
    guard let editor = field.currentEditor() as? NSTextView else { return refused("field-editor-unavailable") }
    editor.string = text
    var sent: [[String: Any]] = []
    didSendToolbarClick = { id, tab, click in
      sent.append(["windowId": id, "tabId": tab, "id": click.id, "kind": click.kind.rawValue,
        "text": click.text ?? "", "activeTabId": store.state.activeTabId(windowId) ?? ""])
    }
    defer { didSendToolbarClick = nil }
    do { _ = try store.dispatch(Command("activate", [.string(nextId)]), origin: .native) }
    catch { result["error"] = String(describing: error); return encoded() }
    result["activeBeforeProjection"] = store.state.activeTabId(windowId)
    host.scheduleLayoutProjection()
    FrameUpdates.flush()
    toolbar.onHiddenOrDetached()
    NativeExtensionActionPopup.flushHeldFieldBlur(from: toolbar)
    NativeExtensionActionPopup.flushHeldFieldBlur(from: toolbar)
    result["accepted"] = true
    result["sent"] = sent
    result["activeAfterProjection"] = store.state.activeTabId(windowId)
    result["replaced"] = owner.panes.toolbar(nextId) != nil && owner.panes.toolbar(nextId) !== toolbar
    return encoded()
  }

  static func bookmarksView(_ windowId: String) -> BookmarksBarView? { owners[windowId]?.bookmarksView }

  static func frozenSnapshot(_ windowId: String) -> [String: Any]? { owners[windowId]?.describeFrozenPages() }
  #endif

  private static func applyDrag(_ value: Any?) {
    guard let o = value as? [String: Any], let windowId = o["windowId"] as? String else { return }
    for (id, view) in views where id != windowId { view.setDrag(nil) }
    if owners[windowId] == nil { view(windowId)?.setDrag(SplitDragFrame(o)) }
  }

  private static func applyToast(_ value: Any?) {
    guard let all = windows(value) else { return }
    for (windowId, entry) in all {
      view(windowId)?.setToast(SplitToastSpec(entry))
      NativeWindowShell.host(windowId)?.shell.coverChanged()
    }
    for (id, view) in views where all[id] == nil { view.setToast(nil) }
  }

  private static func applyNotice(_ value: Any?) {
    guard let all = windows(value) else { return }
    for (windowId, entry) in all { view(windowId)?.setNotice(SplitToastSpec(entry)) }
    for (id, view) in views where all[id] == nil { view.setNotice(nil) }
  }

  private static func applyToolbars(_ value: Any?) {
    guard let o = value as? [String: Any], o["v"] as? Int == 1, let all = o["windows"] as? [String: [String: String]] else { return }
    for (windowId, presenters) in toolbarPresenters {
      for (tabId, presenter) in presenters where all[windowId]?[tabId] == nil {
        presenter.end()
        toolbarPresenters[windowId]?[tabId] = nil
      }
      if toolbarPresenters[windowId]?.isEmpty == true { toolbarPresenters[windowId] = nil }
    }
    for (windowId, feeds) in all {
      for (tabId, input) in feeds {
        if toolbarPresenters[windowId]?[tabId] == nil {
          toolbarPresenters[windowId, default: [:]][tabId] = NativeToolbarPresenter { state, _ in
            toolbars[windowId, default: [:]][tabId] = state
            if toolbars[windowId]?.isEmpty == true { toolbars[windowId] = nil }
            if let view = panes[windowId] {
              view.setToolbarStates(toolbars[windowId] ?? [:])
              if state != nil && owners[windowId] != nil {
                AutoHideHost.toolbarReady(windowId: windowId, tabId: tabId, toolbar: view.toolbar(tabId))
              }
            }
          }
        }
        toolbarPresenters[windowId]?[tabId]?.update(input)
      }
    }
  }

  static func sample(_ windowId: String) -> [String: Any]? {
    guard var out = views[windowId]?.sample() else { return nil }
    if let view = panes[windowId], view.window != nil { out["leaves"] = view.sample() }
    if let view = overlays[windowId], view.window != nil { out["overlays"] = view.sample() }
    if let owner = owners[windowId] { out["owner"] = owner.describe() }
    return out
  }
}

@MainActor
final class NativePaneLayoutHost {
  let shell: WindowShellView
  let generation: UInt64
  let chrome: SplitChromeView
  let panes: SplitPanesView
  let overlays: PaneOverlaysView
  let zone: SplitDropZone
  private var stopped = false
  private var snapshot: WindowLayoutSnapshot?
  private var state: BrowserState?
  private var theme = SplitChromeTheme.fallback
  private var covered = false
  private var frozen: [String: FrozenPageView] = [:]
  private var frozenStates: [String: [String: Any]] = [:]
  private var frozenURIs: [String: String] = [:]
  private var paintedTokens: [String: Int] = [:]
  private var bookmarks: BookmarksBarHost?
  private var features: PaneOverlayHost?
  private var featuresInstalled = false
  #if DEBUG
  var bookmarksView: BookmarksBarView? { stopped ? nil : bookmarks?.view }
  #endif

  init(shell: WindowShellView, generation: UInt64, chrome: SplitChromeView, panes: SplitPanesView, overlays: PaneOverlaysView, zone: SplitDropZone) {
    self.shell = shell
    self.generation = generation
    self.chrome = chrome
    self.panes = panes
    self.overlays = overlays
    self.zone = zone
    shell.ownsPaneSlots = true
    features = NativePaneOverlays.adopt(shell.windowId)
    panes.pagesPooled = true
    panes.onCardStyle = { [weak shell] in shell?.cardStyle = $0 }
  }

  func placementIsCurrent(revision: Int) -> Bool {
    !stopped && snapshot?.input.storeRevision == revision && snapshot?.input.windowGeneration == generation
      && panes.placementIsCurrent(revision: revision, generation: generation)
  }

  func install(_ snapshot: WindowLayoutSnapshot, state: BrowserState) {
    #if DEBUG || SOLARA_PERF_TRACE
    let trace = LayoutTrace.begin("paneInstall", "\(shell.windowId) \(snapshot.input.storeRevision)")
    defer { LayoutTrace.end(trace) }
    #endif
    guard !stopped, snapshot.input.windowGeneration == generation else { return }
    self.snapshot = snapshot
    self.state = state
    TabSlots.shared.performBatch {
      PaneOverlays.shared.performBatch {
        let fullscreen = snapshot.fullscreenTabId
        chrome.setChrome(theme: theme, fullscreenTab: fullscreen, covered: state.peeks[shell.windowId] != nil && fullscreen == nil)
        panes.theme = theme
        panes.cardColor = theme.color("card", dark: "rgba(18,18,18,0.5)", light: "rgba(255,255,255,0.7)")
        panes.small = false
        #if DEBUG || SOLARA_PERF_TRACE
        let paneChromeTrace = LayoutTrace.begin("paneChrome", shell.windowId)
        #endif
        chrome.install(snapshot, state: state)
        #if DEBUG || SOLARA_PERF_TRACE
        LayoutTrace.end(paneChromeTrace)
        #endif
        #if DEBUG || SOLARA_PERF_TRACE
        let paneGeometryTrace = LayoutTrace.begin("paneGeometry", shell.windowId)
        #endif
        panes.install(snapshot, state: state)
        #if DEBUG || SOLARA_PERF_TRACE
        LayoutTrace.end(paneGeometryTrace)
        #endif
        #if DEBUG || SOLARA_PERF_TRACE
        let paneOverlaysTrace = LayoutTrace.begin("paneOverlays", shell.windowId)
        #endif
        overlays.install(snapshot, state: state)
        #if DEBUG || SOLARA_PERF_TRACE
        LayoutTrace.end(paneOverlaysTrace)
        #endif
        #if DEBUG || SOLARA_PERF_TRACE
        let paneBookmarksTrace = LayoutTrace.begin("paneBookmarks", shell.windowId)
        #endif
        placeBookmarks(snapshot, state: state)
        #if DEBUG || SOLARA_PERF_TRACE
        LayoutTrace.end(paneBookmarksTrace)
        #endif
        #if DEBUG || SOLARA_PERF_TRACE
        let paneFrozenTrace = LayoutTrace.begin("paneFrozen", shell.windowId)
        #endif
        frozenStates = NativePinnedPageCommands.presentations(windowId: shell.windowId)
    placeFrozen()
        #if DEBUG || SOLARA_PERF_TRACE
        LayoutTrace.end(paneFrozenTrace)
        #endif
      }
    }
    for id in snapshot.panes.keys { AutoHideHost.toolbarReady(windowId: shell.windowId, tabId: id, toolbar: panes.toolbar(id)) }
    #if DEBUG || SOLARA_PERF_TRACE
    let featuresTrace = LayoutTrace.begin("paneFeatures", shell.windowId)
    #endif
    if featuresInstalled {
      features?.relayout()
    } else {
      featuresInstalled = true
      features?.refresh()
    }
    #if DEBUG || SOLARA_PERF_TRACE
    LayoutTrace.end(featuresTrace)
    #endif
  }

  func setTheme(_ theme: SplitChromeTheme, covered: Bool) {
    guard !stopped else { return }
    self.theme = theme
    self.covered = covered
    NativeWindowShell.host(shell.windowId)?.scheduleLayoutProjection()
  }

  private func placeBookmarks(_ snapshot: WindowLayoutSnapshot, state: BrowserState) {
    guard snapshot.input.split == nil, let id = snapshot.input.selectedTabId,
      let pane = snapshot.panes[id], let page = snapshot.pages[id], let bar = snapshot.toolbars[id],
      state.windows[shell.windowId]?.incognito != true,
      snapshot.input.bookmarksBar == "always" || snapshot.input.bookmarksBar == "newTab" && state.tabs[id]?.url.isEmpty == true,
      snapshot.input.pageFacts[id]?.fullscreen != true else {
      bookmarks?.view.removeFromSuperview()
      bookmarks = nil
      return
    }
    let host = bookmarks ?? BookmarksBarHost(windowId: shell.windowId)
    bookmarks = host
    if host.view.superview !== shell.card { shell.card.addSubview(host.view, positioned: .below, relativeTo: overlays) }
    let band = snapshot.input.pageFacts[id]?.band ?? 0
    let top = min(max(bar.maxY, page.minY - band - 30), pane.maxY)
    host.view.frame = CGRect(x: pane.minX - snapshot.frames.card.minX, y: top - snapshot.frames.card.minY,
      width: pane.width, height: min(30, max(0, page.minY - band - top)))
    host.updateNative(state, profileId: snapshot.input.profileId, theme: theme)
  }

  func setFrozen(_ next: [String: [String: Any]]) {
    guard !stopped else { return }
    frozenStates = next
    frozenStates = NativePinnedPageCommands.presentations(windowId: shell.windowId)
    placeFrozen()
  }

  private func placeFrozen() {
    guard !stopped, let snapshot, let state else { return }
    let wanted = frozenStates.filter { id, entry in
      guard snapshot.fullscreenTabId == nil, snapshot.pages[id] != nil,
        let copyId = entry["copyId"] as? String, state.tabs[copyId] != nil else { return false }
      return state.tabs[id]?.windowId == shell.windowId
        && FrozenPageIdentity.admits(tabId: id, copyId: copyId, holder: state.sharedPageHolder(id)?.id, copyHolder: state.sharedPageHolder(copyId)?.id)
    }
    for (id, view) in frozen where wanted[id] == nil { view.removeFromSuperview(); frozen[id] = nil; frozenURIs[id] = nil; paintedTokens[id] = nil }
    for (id, entry) in wanted {
      guard let rect = snapshot.pages[id], let token = PinnedPageCommand.token(in: entry),
        let copyId = entry["copyId"] as? String else { continue }
      let view = frozen[id] ?? FrozenPageView(frame: .zero)
      frozen[id] = view
      if view.superview !== shell.card { shell.card.addSubview(view, positioned: .below, relativeTo: overlays) }
      view.frame = rect.offsetBy(dx: -snapshot.frames.card.minX, dy: -snapshot.frames.card.minY)
      view.dark = entry["dark"] as? Bool ?? theme.dark
      let send: (String) -> Void = { [weak self, weak view] name in
        guard let self, !self.stopped, self.frozen[id] === view,
          self.frozenStates[id].flatMap { PinnedPageCommand.token(in: $0) } == token,
          self.frozenStates[id]?["copyId"] as? String == copyId,
          let state = NativeStoreHandle.store?.state, state.tabs[id]?.windowId == self.shell.windowId,
          FrozenPageIdentity.admits(tabId: id, copyId: copyId, holder: state.sharedPageHolder(id)?.id, copyHolder: state.sharedPageHolder(copyId)?.id) else { return }
        if name == "painted" {
          guard self.paintedTokens[id] != token else { return }
          self.paintedTokens[id] = token
        }
        if name == "painted" { NativePinnedPageCommands.didPaint(windowId: self.shell.windowId, tabId: id, copyId: copyId, token: token) }
        if name == "press", id == copyId { NativePinnedPageCommands.request("handOffPin", tabId: copyId) }
      }
      view.onPress = { send("press") }
      view.onPainted = { send("painted") }
      let uri = entry["uri"] as? String
      if frozenURIs[id] == uri, view.image != nil { send("painted"); continue }
      frozenURIs[id] = uri
      let image = uri.flatMap { uri -> NSImage? in
        guard uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
          let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
      }
      view.show(image)
      if image != nil { send("painted") }
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    TabDragSession.unregister(zone)
    zone.clear()
    TabSlots.shared.performBatch {
      PaneOverlays.shared.performBatch {
        panes.stop()
        overlays.stop()
        chrome.stop()
      }
    }
    for view in frozen.values { view.onPress = nil; view.onPainted = nil; view.removeFromSuperview() }
    frozen = [:]
    frozenStates = [:]
    frozenURIs = [:]
    paintedTokens = [:]
    bookmarks?.view.removeFromSuperview()
    bookmarks = nil
    if let features { NativePaneOverlays.end(shell.windowId, ifHost: features) }
    features = nil
    snapshot = nil
    state = nil
    NativeSplitChrome.end(self)
  }

  #if DEBUG
  func describeFrozenPages() -> [String: Any]? {
    guard !stopped else { return nil }
    var tabs: [String: [String: Any]] = [:]
    for (id, view) in frozen {
      guard let entry = frozenStates[id], let token = PinnedPageCommand.token(in: entry),
        let copyId = entry["copyId"] as? String else { continue }
      let frame = view.convert(view.bounds, to: nil)
      let height = view.window?.contentView?.bounds.height ?? 0
      tabs[id] = ["frozenPage": [
        "token": token, "copyId": copyId, "hasImage": view.image != nil, "dark": view.dark,
        "frame": [frame.minX, height - frame.maxY, frame.width, frame.height],
      ]]
    }
    return ["tabs": tabs]
  }
  #endif

  func describe() -> [String: Any] {
    ["generation": generation, "stopped": stopped, "identity": String(describing: ObjectIdentifier(self)),
      "panes": String(describing: ObjectIdentifier(panes)), "overlays": String(describing: ObjectIdentifier(overlays)),
      "frozen": frozen.mapValues { ["image": $0.image != nil] }]
  }
}

#if SOLARA_PROBES
@MainActor
public enum SplitChromeRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let source = NativeSplitChrome.sample(windowId) else { return nil }
    func entries(_ key: String) -> [String: [String: Any]] {
      let source = source[key] as? [String: [String: Any]] ?? [:]
      return source.mapValues { entry in
        var result: [String: Any] = ["window": entry["window"] ?? NSNull(), "hidden": entry["hidden"] ?? NSNull()]
        if key == "leaves" { result["covered"] = entry["covered"] ?? NSNull() }
        return result
      }
    }
    return ["overlays": entries("overlays"), "leaves": entries("leaves")]
  }
}
#endif

final class SplitChromeCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false

  func receive(_ state: BrowserState) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { NativeSplitChrome.commit(state) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let state = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let state else { return }
      MainActor.assumeIsolated { NativeSplitChrome.commit(state) }
    }
  }
}

#if DEBUG
@MainActor
final class SplitChromeDevRun {
  private static var current: SplitChromeDevRun?
  private let run: Int
  private let view: SplitChromeView?
  private let steps: Int
  private let step: CGFloat
  private var frame = 0
  private var timer: Timer?
  private var observer: CFRunLoopObserver?
  private var woke: CFAbsoluteTime?
  private var busy: Double = 0
  private var longest: Double = 0
  private var iterations = 0
  private let dispatchesBefore: Int
  private let began = CFAbsoluteTimeGetCurrent()

  static func start(_ value: Any?, _ views: [String: SplitChromeView]) {
    guard let o = value as? [String: Any], o["v"] as? Int == 1, let run = o["run"] as? Int, let windowId = o["windowId"] as? String else { return }
    let native = o["mode"] as? String == "native"
    let view = native ? views[windowId] : nil
    if native, view?.devDragBegin(o["key"] as? String ?? "r0") != true {
      Task { @MainActor in _ = await SettingsAdapters.js("split.devResult", run, "{\"error\": \"no divider\"}") }
      return
    }
    current = SplitChromeDevRun(run: run, view: view, steps: o["steps"] as? Int ?? 60, step: CGFloat((o["step"] as? NSNumber)?.doubleValue ?? 4))
  }

  private init(run: Int, view: SplitChromeView?, steps: Int, step: CGFloat) {
    self.run = run
    self.view = view
    self.steps = steps
    self.step = step
    dispatchesBefore = view?.dispatches ?? 0
    let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 2_000_001) { [weak self] _, activity in
      MainActor.assumeIsolated { self?.observe(activity) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    let made = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    made.tolerance = 0
    RunLoop.main.add(made, forMode: .common)
    timer = made
  }

  private func observe(_ activity: CFRunLoopActivity) {
    let now = CFAbsoluteTimeGetCurrent()
    if activity == .afterWaiting {
      woke = now
    } else if let woke {
      let spent = (now - woke) * 1000
      busy += spent
      longest = max(longest, spent)
      iterations += 1
      self.woke = nil
    }
  }

  private func tick() {
    frame += 1
    if frame <= steps {
      view?.devDragMove(step * CGFloat(frame))
      if frame == steps { view?.devDragEnd() }
      return
    }
    guard frame >= steps + 6 else { return }
    timer?.invalidate()
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    let result: [String: Any] = [
      "busy": busy, "longest": longest, "iterations": iterations, "ms": (CFAbsoluteTimeGetCurrent() - began) * 1000,
      "dispatches": (view?.dispatches ?? 0) - dispatchesBefore, "frames": steps,
    ]
    let run = run
    let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    Task { @MainActor in _ = await SettingsAdapters.js("split.devResult", run, json) }
    if Self.current === self { Self.current = nil }
  }
}
#endif
