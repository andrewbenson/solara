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
  private static var views: [String: SplitChromeView] = [:]
  private static var panes: [String: SplitPanesView] = [:]
  private static var overlays: [String: PaneOverlaysView] = [:]
  private static var dropZones: [String: SplitDropZone] = [:]
  private static var toolbars: [String: [String: String]] = [:]
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
    if let store = NativeStoreHandle.store {
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
    applyTheme(SettingsJS.shared.latestValue(themeTopic))
  }

  static func commit(_ state: BrowserState) {
    for (id, view) in views {
      if view.superview == nil {
        views[id] = nil
        if let zone = dropZones.removeValue(forKey: id) { TabDragSession.unregister(zone) }
      } else {
        view.update(state: state)
      }
    }
    for (id, view) in overlays {
      if view.superview == nil { overlays[id] = nil } else { view.update(state: state) }
    }
    for (id, view) in panes {
      if view.superview == nil { panes[id] = nil } else { view.update(state: state) }
    }
  }

  private static func cardContainer(for window: String) -> NSView? { NativeWindowShell.host(window)?.shell.card }

  static func setShareBands(_ heights: [String: CGFloat], windowId: String) {
    if let overlay = overlays[windowId], overlay.superview != nil { overlay.bandHeights = heights }
    if let view = panes[windowId], view.superview != nil { view.bandHeights = heights }
  }

  static func setShareBandClip(_ clip: NSView?, windowId: String, tabId: String) {
    guard let overlay = overlays[windowId], overlay.superview != nil else { return }
    overlay.setBand(clip, tabId: tabId)
  }

  static func setLiveTop(_ top: CGFloat?, windowId: String, tabId: String) {
    guard let view = panes[windowId], view.superview != nil else { return }
    view.setLiveTop(top, tabId: tabId)
  }

  private static func panesView(_ windowId: String) -> SplitPanesView? {
    guard panesEnabled else { return nil }
    if let view = panes[windowId], view.superview != nil { return view }
    panes[windowId] = nil
    guard let card = cardContainer(for: windowId) else { return nil }
    let view = SplitPanesView(windowId: windowId)
    view.favicons = favicons
    view.frame = card.bounds
    view.autoresizingMask = [.width, .height]
    view.onToolbarClick = { tabId, click in
      let payload: [String: Any] = ["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()]
      Task { @MainActor in _ = await SettingsAdapters.js("split.toolbarClick", windowId, tabId, payload) }
    }
    view.onToolbarAnchors = { tabId, anchors in
      NativeExtensionActionPopup.anchorsChanged(window: ShellDrag.window(windowId), tabId: tabId, anchors: anchors)
      let payload = anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
      Task { @MainActor in _ = await SettingsAdapters.js("split.toolbarAnchors", windowId, tabId, payload) }
    }
    view.onNavigate = { tabId, text in _ = try? NativeStoreHandle.store?.dispatch(Command("navigate", [.string(tabId), .string(text)]), origin: .native) }
    view.onReplace = { tabId, other in _ = try? NativeStoreHandle.store?.dispatch(Command("replaceSplitPane", [.string(tabId), .string(other)]), origin: .native) }
    if let overlay = overlays[windowId], overlay.superview === card { card.addSubview(view, positioned: .below, relativeTo: overlay) } else { card.addSubview(view) }
    view.setToolbars(toolbars[windowId] ?? [:])
    if let state = NativeStoreHandle.store?.state { view.update(state: state) }
    panes[windowId] = view
    return view
  }

  private static func view(_ windowId: String) -> SplitChromeView? {
    if let view = views[windowId], view.superview != nil { return view }
    views[windowId] = nil
    guard let host = NativeWindowShell.host(windowId) else { return nil }
    let view = SplitChromeView(windowId: windowId)
    view.onResize = { splitId, sizes, stack in
      var options: JSONObject = [:]
      if let sizes { options["sizes"] = .array(sizes.map { .number($0) }) }
      if let stack { options["stackSizes"] = .array(stack.map { .number($0) }) }
      _ = try? NativeStoreHandle.store?.dispatch(Command("updateSplit", [.string(splitId), .object(options)]), origin: .native)
    }
    view.onToastHidden = { [weak shell = host.shell] id in
      shell?.coverChanged()
      Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "hidden") }
    }
    view.onToastAction = { id in Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "action") } }
    host.shell.mount(.splitChrome, view)
    let zone = SplitDropZone(windowId: windowId, chrome: view)
    zone.state = { NativeStoreHandle.store?.state }
    zone.covered = { NativeSidebarDock.peekCovers(windowId, x: $0.x) }
    zone.onDrop = { tabId, target, side in
      let options: JSONObject = ["tabId": .string(tabId), "anchorTabId": .string(target), "side": .string(side.rawValue)]
      _ = try? NativeStoreHandle.store?.dispatch(Command("openSplitPane", [.string(windowId), .object(options)]), origin: .native)
    }
    if let old = dropZones[windowId] { TabDragSession.unregister(old) }
    dropZones[windowId] = zone
    TabDragSession.register(zone, windowId: windowId, priority: .split)
    let overlay = PaneOverlaysView(windowId: windowId)
    overlay.frame = host.shell.card.bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.onCoverChanged = { [weak shell = host.shell] in shell?.coverChanged() }
    host.shell.card.addSubview(overlay)
    overlays[windowId]?.removeFromSuperview()
    overlays[windowId] = overlay
    if let state = NativeStoreHandle.store?.state { overlay.update(state: state) }
    if let state = NativeStoreHandle.store?.state { view.update(state: state) }
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

  private static func applyDrag(_ value: Any?) {
    guard let o = value as? [String: Any], let windowId = o["windowId"] as? String else { return }
    for (id, view) in views where id != windowId { view.setDrag(nil) }
    view(windowId)?.setDrag(SplitDragFrame(o))
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
    toolbars = all
    for (windowId, view) in panes { view.setToolbars(all[windowId] ?? [:]) }
  }

  static func sample(_ windowId: String) -> [String: Any]? {
    guard var out = views[windowId]?.sample() else { return nil }
    if let view = panes[windowId], view.window != nil { out["leaves"] = view.sample() }
    if let view = overlays[windowId], view.window != nil { out["overlays"] = view.sample() }
    return out
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
