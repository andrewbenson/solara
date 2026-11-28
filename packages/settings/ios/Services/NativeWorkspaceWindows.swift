import AppKit
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeWorkspaceWindows {
  private static var lifecycle: Int?
  private static var observer: Int?
  private static weak var store: Store?
  private static var titles = [String: String]()
  private static var focusedFirst = false
  private static var syncedRevision = -1

  static func start(focusedFirst: Bool) {
    guard lifecycle == nil else { return }
    self.focusedFirst = focusedFirst
    lifecycle = NativeStoreHandle.subscribeLifecycle { bind() }
    _ = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraCoreQuitCancelled"), object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        if let store { sync(store, launching: false) }
      }
    }
  }

  static func materializeChanges(before: BrowserState, after: BrowserState) {
    let existing = WindowHost.browserWindowIDs
    for id in after.windowOrder where before.windows[id] == nil && !existing.contains(id) {
      open(after, id: id, focus: after.ui.focusedWindowId == id, behind: nil, launching: false)
    }
    for id in before.windowOrder where after.windows[id] == nil && before.windows[id]?.isSmall == false { WindowHost.closeBrowserWindow(id) }
  }

  private static func bind() {
    let next = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    guard next !== store else { return }
    if let observer { store?.unsubscribe(observer) }
    observer = nil
    store = next
    titles.removeAll()
    syncedRevision = -1
    guard let next else { return }
    observer = next.subscribe { [weak next] commit in
      let changes = commit.changes
      guard changes.windows != TableChange() || changes.tabs != TableChange() || changes.profiles != TableChange() else { return }
      DispatchQueue.main.async {
        guard let next, next === store, commit.rev > syncedRevision else { return }
        sync(next, launching: false)
      }
    }
    sync(next, launching: true)
    let state = next.state
    let fullscreen = state.windowOrder.filter { state.windows[$0]?.isSmall == false && (state.windows[$0]?.fullScreen ?? 0) > 0 }
      .sorted { (state.windows[$0]?.fullScreen ?? 0) < (state.windows[$1]?.fullScreen ?? 0) }
    if !fullscreen.isEmpty { WindowHost.restoreBrowserFullScreen(fullscreen, focus: state.ui.focusedWindowId) }
  }

  private static func sync(_ store: Store, launching: Bool) {
    guard !NativeStoreHandle.frozen, WindowHost.canSyncWorkspaceWindows else { return }
    let (state, revision) = store.sequence { (store.state, store.rev) }
    syncedRevision = revision
    let existing = WindowHost.browserWindowIDs
    let new = state.windowOrder.filter { state.windows[$0]?.isSmall == false && !existing.contains($0) }
    let focused = state.ui.focusedWindowId.flatMap { new.contains($0) ? $0 : nil }
    let openFocusedFirst = launching && focusedFirst && focused != nil
    let rest = new.filter { $0 != focused }
    let first = focused.map { [$0] } ?? []
    for id in openFocusedFirst ? first + rest : rest + first {
      open(state, id: id, focus: id == focused, behind: openFocusedFirst && id != focused ? focused : nil, launching: launching)
    }
    for id in existing where state.windows[id] == nil { WindowHost.closeBrowserWindow(id) }
    titles = titles.filter { state.windows[$0.key] != nil }
    for id in state.windowOrder where state.windows[id]?.isSmall == false {
      let title = ScriptState.windowTitle(state, id)
      if titles[id] != title {
        titles[id] = title
        WindowHost.setBrowserWindowTitle(id, title: title)
      }
    }
  }

  private static func open(_ state: BrowserState, id: String, focus: Bool, behind: String?, launching: Bool) {
    guard let window = state.windows[id], !window.isSmall else { return }
    let title = ScriptState.windowTitle(state, id)
    titles[id] = title
    let center = (window.tabLayout ?? state.settings["tabLayout"]?.string) == "top"
      ? ShellMetrics.topStripLightsCenter : ShellMetrics.lightsCenter
    WindowHost.openBrowserWindow(id, frame: window.frame, incognito: window.incognito, profile: state.engineProfile(window.profileId),
      title: title, focus: focus, chromeWindow: window.chromeWindow, small: false,
      size: nil, behind: behind, animated: !launching && window.chromeWindow == nil, lightsCenter: center)
  }
}
