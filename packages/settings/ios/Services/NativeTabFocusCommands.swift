import AppKit
import SolaraModel
import SolaraOmnibox
import SolaraShell
import SolaraStore
import SolaraUI
@MainActor
enum NativeTabFocusCommands {
  private static var store: Store?
  private static var listener: Int?, lifecycle: Int?
  private static var generation = 0
  private static var windowId: String?, active: String?
  private static var profile = ""
  private static var hold: TabFocusCommand?
  private static weak var host: NSView?
  private static var attached = false, shown = false
  private static var monitor: Any?
  private static var token = UUID()
  private static var pointer = NSEvent.mouseLocation
  private static var hovered: Int?
  private static var openId = 0
  static func perform(_ command: String, arg: String?, windowId requested: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let current = NativeStoreHandle.store else { return true }
    if lifecycle == nil {
      lifecycle = NativeStoreHandle.subscribeLifecycle { if NativeStoreHandle.ownershipGeneration != generation { end() } }
      NativeMenuCommands.switcherRelease = { release(); return true }
    }
    let route = CommandRoute.resolve(command, windowId: requested, state: current.state, closing: current.memory.closingWindows)
    guard let id = route.windowId, let window = current.state.windows[id], !current.memory.closingWindows.contains(id) else { return true }
    if command == "tabSwitcher", windowId == id, hold != nil { step(arg == "backward" ? -1 : 1); return true }
    end()
    store = current; generation = NativeStoreHandle.ownershipGeneration
    windowId = id; profile = window.profileId; active = current.state.activeTabId(id)
    host = NativeWindowShell.overlay(id); attached = host != nil
    if let focus = route.focusWindow { ShellDrag.focus(focus) }
    if command == "tabSwitcher" {
      hold = TabFocusCommand.begin(current.state, windowId: id, backward: arg == "backward", now: Date().timeIntervalSince1970 * 1000)
      guard hold != nil, host?.window != nil else { end(); return true }
    }
    let receipt = token, expectedProfile = profile, expectedActive = active
    listener = current.subscribe { commit in
      let validSelection = commit.state.windows[id]?.profileId == expectedProfile && commit.state.activeTabId(id) == expectedActive
      Task { @MainActor in if token == receipt { if validSelection { refresh() } else { end() } } }
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved]) { event in
      let swallowed = MainActor.assumeIsolated { () -> Bool in
        guard hold != nil else { return false }
        if event.type == .mouseMoved { if pointer != NSEvent.mouseLocation, let hovered { select(hovered) }; return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
          if event.window !== host?.window { end() }
          else if !NativeTabPickers.containsSwitcher(id, event.locationInWindow) { end() }
          return false
        }
        if event.keyCode == 53 { end(); return true }
        if event.keyCode == 123 || event.keyCode == 124 { step(event.keyCode == 123 ? -1 : 1); return true }
        return false
      }
      return swallowed ? nil : event
    }
    if hold != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { if token == receipt { shown = true; refresh() } }
    } else { shown = true; openId += 1; refresh() }
    return true
  }
  private static func valid() -> Bool {
    guard let id = windowId, let store, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
      NativeStoreHandle.ownershipGeneration == generation, !store.memory.closingWindows.contains(id),
      store.state.windows[id]?.profileId == profile, store.state.activeTabId(id) == active else { return false }
    return !attached || (host != nil && NativeWindowShell.overlay(id) === host && host?.window != nil)
  }
  static func attach(_ id: String) {
    guard windowId == id, !attached else { return }
    host = NativeWindowShell.overlay(id); attached = host != nil
    refresh()
  }
  private static func refresh() {
    guard valid(), let id = windowId, let store else { end(); return }
    guard shown, host?.window != nil else { return }
    let look = NativeSidebarShell.column(id)?.chrome.state
    let dark = look?.dark ?? (host?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    let theme = look?.theme ?? [:]
    if let hold {
      let rows = Dictionary(uniqueKeysWithValues: hold.ids.compactMap { key -> (String, TabSwitcherState.Row)? in
        guard let tab = store.state.tabs[key] else { return nil }
        return (key, .init(id: key, title: tab.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? (tab.title.isEmpty ? (tab.url.isEmpty ? "New Tab" : tab.url) : tab.title), url: tab.url, display: displayUrl(tab.url), favicon: tab.favicon, icon: tab.customIcon, profileId: tab.profileId))
      })
      NativeTabPickers.showSwitcher(id, TabSwitcherState(ids: hold.ids, index: hold.index, rows: rows, dark: dark, theme: theme))
    } else {
      var state = TabFocusCommand.search(store.state, windowId: id, dark: dark, theme: theme)
      state.openId = openId
      NativeTabPickers.showSearch(id, state)
    }
  }
  private static func step(_ direction: Int) {
    guard valid(), let store else { end(); return }
    hold?.step(direction, state: store.state); pointer = NSEvent.mouseLocation; hovered = nil; refresh()
  }
  private static func select(_ index: Int) {
    guard let hold, hold.ids.indices.contains(index), let store else { return }
    for _ in hold.ids where self.hold?.index != index { self.hold?.step(1, state: store.state) }
    refresh()
  }
  private static func release() {
    guard hold != nil else { return }
    guard valid(), let store else { end(); return }
    if shown, let hovered, pointer != NSEvent.mouseLocation { select(hovered) }
    let selected = hold?.release(store.state); end()
    if let selected { _ = try? store.dispatch(Command("activate", [.string(selected)]), origin: .native); FrameUpdates.flush() }
  }
  static func event(_ id: String, _ event: String, args: [Any]) {
    guard id == windowId, valid(), let store else { end(id); return }
    if event == "hover", let index = args.first as? Int { hovered = index; if pointer != NSEvent.mouseLocation { select(index) }; return }
    if event == "leave" { hovered = nil; return }
    if event == "commit", let index = args.first as? Int {
      guard let hold, hold.ids.indices.contains(index), store.state.tabs[hold.ids[index]] != nil else { end(); return }
      select(index); release(); return
    }
    if event == "choose", let kind = args.first as? String, let key = args.last as? String {
      let state = TabFocusCommand.search(store.state, windowId: id, dark: false, theme: [:])
      guard (kind == "tab" ? state.open : state.closed).contains(where: { $0.id == key }) else { return }
      let target = store.state.tabs[key]?.windowId
      end()
      _ = try? store.dispatch(Command(kind == "tab" ? "activate" : "restoreClosed", kind == "tab" ? [.string(key)] : [.string(key), .string(id)]), origin: .native)
      if let target, target != id { ShellDrag.focus(target) }
      FrameUpdates.flush()
      return
    }
    end()
  }
  static func end(_ id: String? = nil) {
    if let id, id != windowId { return }
    if let listener { store?.unsubscribe(listener) }; if let monitor { NSEvent.removeMonitor(monitor) }
    if let windowId { NativeTabPickers.hide(windowId) }
    token = UUID(); hold = nil; windowId = nil; listener = nil; monitor = nil; store = nil; host = nil; shown = false; hovered = nil; attached = false
  }
}
