import AppKit
import Foundation
import SolaraUI

final class SwitcherPresses: @unchecked Sendable {
  private let lock = NSLock()
  private var pressed: [String: Int] = [:]

  func press(_ windowId: String, _ index: Int) { lock.withLock { pressed[windowId] = index } }
  func clear(_ windowId: String) { lock.withLock { pressed[windowId] = nil } }
  func take(_ windowId: String) -> Int { lock.withLock { pressed.removeValue(forKey: windowId) ?? -1 } }
}

@MainActor
enum NativeTabPickers {
  static let kind = "tabPickers"
  static let searchTopic = "sidebar.tabSearch"
  static let switcherTopic = "sidebar.switcher"
  private static var registered = false
  private static var searches: [String: TabSearchPanelView] = [:]
  private static var switchers: [String: TabSwitcherPanelView] = [:]
  nonisolated static let switcherPresses = SwitcherPresses()

  static func register() {
    guard !registered else { return }
    registered = true
    HostedViews.register(kind) { _ in nil }
  }

  private static func favicons(_ windowId: String) -> SidebarFavicons {
    NativeSidebar.hosts[windowId]?.view.favicons ?? SidebarFavicons()
  }

  static func prepare(_ windowId: String, in overlay: NSView) {
    NativeTabFocusCommands.attach(windowId)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak overlay] in
      guard let overlay, NativeWindowShell.overlay(windowId) === overlay, overlay.window != nil else { return }
      let view = search(windowId, in: overlay)
      guard view.isHidden else { return }
      let dark = NativeSidebarShell.column(windowId)?.chrome.state?.dark ?? (overlay.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
      view.prepare(dark: dark)
    }
  }

  static func windowEnded(_ windowId: String, in overlay: NSView) {
    guard NativeWindowShell.overlay(windowId) === overlay || searches[windowId]?.superview === overlay else { return }
    NativeTabFocusCommands.end(windowId)
    switchers.removeValue(forKey: windowId)?.removeFromSuperview()
    guard let view = searches[windowId], view.superview === overlay else { return }
    view.hide()
    view.removeFromSuperview()
    searches[windowId] = nil
  }

  private static func search(_ windowId: String, in overlay: NSView) -> TabSearchPanelView {
    if let view = searches[windowId], view.superview === overlay { return view }
    if let previous = searches[windowId] {
      previous.hide()
      previous.removeFromSuperview()
    }
    let view = TabSearchPanelView(favicons: favicons(windowId))
    view.frame = overlay.bounds
    view.autoresizingMask = [.width, .height]
    view.onEvent = { event in
      switch event {
      case .close: send(searchTopic, windowId, "close")
      case .choose(let kind, let id): send(searchTopic, windowId, "choose", kind, id)
      }
    }
    overlay.addSubview(view)
    searches[windowId] = view
    return view
  }

  static func showSearch(_ windowId: String, _ state: TabSearchState) {
      guard let overlay = NativeWindowShell.overlay(windowId), overlay.window != nil else { return }
      let view = search(windowId, in: overlay)
      if view.isHidden || view.openId != state.openId {
        if view.isHidden, overlay.subviews.last !== view { overlay.addSubview(view, positioned: .above, relativeTo: nil) }
        view.favicons = favicons(windowId)
        view.open(state)
      } else {
        view.set(state)
      }
  }

  static func showSwitcher(_ windowId: String, _ state: TabSwitcherState) {
      guard let overlay = NativeWindowShell.overlay(windowId) else { return }
      let view = switchers[windowId] ?? {
        let made = TabSwitcherPanelView(favicons: favicons(windowId))
        made.onEvent = { event in
          switch event {
          case .hover(let index): send(switcherTopic, windowId, "hover", index)
          case .leave(let index): send(switcherTopic, windowId, "leave", index)
          case .commit(let index):
            switcherPresses.press(windowId, index)
            send(switcherTopic, windowId, "commit", index)
          }
        }
        return made
      }()
      switchers[windowId] = view
      if view.superview !== overlay { overlay.addSubview(view) }
      view.set(state, windowSize: overlay.bounds.size)
  }

  static func hide(_ windowId: String) {
    switcherPresses.clear(windowId)
    searches[windowId]?.hide()
    switchers.removeValue(forKey: windowId)?.removeFromSuperview()
  }

  static func containsSwitcher(_ windowId: String, _ point: CGPoint) -> Bool {
    guard let view = switchers[windowId] else { return false }
    return view.bounds.contains(view.convert(point, from: nil))
  }

  static func describe(_ windowId: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: info(windowId)) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func info(_ windowId: String) -> [String: Any] {
    var info: [String: Any] = [:]
    if let window = NativeWindowShell.overlay(windowId)?.window {
      info["responder"] = window.firstResponder.map { $0 === window ? "window" : String(describing: type(of: $0)) } ?? "none"
    }
    func rect(_ view: NSView, _ r: CGRect) -> [Double] {
      guard let root = view.window?.contentView else { return [] }
      let w = view.convert(r, to: nil)
      return [w.minX, root.bounds.height - w.maxY, w.width, w.height]
    }
    if let search = searches[windowId], !search.isHidden {
      info["search"] = [
        "frame": rect(search, search.panelFrame), "query": search.query, "selected": search.selectedIndex, "rows": search.shownRows.map { "\($0.kind):\($0.id)" },
        "typing": search.typing,
      ] as [String: Any]
    }
    if let switcher = switchers[windowId] {
      info["switcher"] = ["frame": rect(switcher, switcher.bounds), "ids": switcher.shownIds, "index": switcher.state?.index ?? -1] as [String: Any]
    }
    return info
  }

  private static func send(_ topic: String, _ windowId: String, _ event: String, _ args: Any...) {
    NativeTabFocusCommands.event(windowId, event, args: args)
  }
}
