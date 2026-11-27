import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeDownloadMagnet {
  private static var views: [String: DownloadMagnetView] = [:]
  private static var seen: Set<String> = []

  static func seed(_ downloads: [Download]) { seen = Set(downloads.map(\.id)) }

  static func reset() {
    for view in views.values { view.removeFromSuperview() }
    views.removeAll()
    seen.removeAll()
  }

  static func attach(_ state: BrowserState) {
    for id in Array(views.keys) where state.windows[id] == nil || views[id]?.superview !== NativeDownloadsPanel.container(id) {
      views.removeValue(forKey: id)?.removeFromSuperview()
    }
    for (id, window) in state.windows where views[id] == nil && !window.isSmall {
      guard let container = NativeDownloadsPanel.container(id), container.window != nil else { continue }
      let view = DownloadMagnetView(frame: container.bounds)
      view.autoresizingMask = [.width, .height]
      if let panel = NativeDownloadsPanel.panel(id), panel.superview === container {
        container.addSubview(view, positioned: .below, relativeTo: panel)
      } else {
        container.addSubview(view)
      }
      views[id] = view
    }
  }

  static func downloadsChanged(_ state: BrowserState, fly: Bool) {
    let fresh = state.downloads.first { !seen.contains($0.id) }
    seed(state.downloads)
    guard fly, let download = fresh, let id = state.ui.focusedWindowId, let window = state.windows[id],
      state.downloadVisible(download, in: window), let view = views[id], !view.bounds.isEmpty else { return }
    let top = (window.tabLayout ?? state.settings.string("tabLayout")) == "top"
    let footer = !top && state.settings.string("addressBar") == "sidebar"
    let sidebarWidth = NativeWindowShell.host(id)?.shell.input.sidebarWidth ?? CGFloat(window.effectiveSidebarWidth(state.settings))
    let sidebar = !top && window.sidebarOpen ? sidebarWidth : 0
    let fallback = top ? CGPoint(x: view.bounds.width - 25, y: 21)
      : footer ? CGPoint(x: 25, y: view.bounds.height - 20)
      : sidebar > 0 ? CGPoint(x: sidebar - 24, y: 27) : CGPoint(x: 24, y: 24)
    let anchor = NativeDownloadsPanel.anchor(id, topStrip: top, in: view)
    let target = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? fallback
    let start = CGPoint(x: sidebar + (view.bounds.width - sidebar) / 2, y: view.bounds.height * 0.45)
    view.fly(DownloadFlight(id: download.id, path: download.path.isEmpty ? download.filename : download.path, start: start, target: target))
  }

  static func describe(_ windowId: String) -> String {
    guard let view = views[windowId] else { return "null" }
    let icon = view.layer?.sublayers?.first
    let shown = icon?.presentation() ?? icon
    var info: [String: Any] = [
      "flights": view.flights,
      "animating": !(icon?.animationKeys() ?? []).isEmpty,
      "inWindow": view.window != nil,
      "size": [view.bounds.width, view.bounds.height],
      "hasIcon": icon?.contents != nil,
      "position": [shown?.position.x ?? 0, shown?.position.y ?? 0],
      "opacity": Double(shown?.opacity ?? 0),
      "restingPosition": [icon?.position.x ?? 0, icon?.position.y ?? 0],
      "restingOpacity": Double(icon?.opacity ?? 0),
    ]
    if let flying = view.flying { info["flying"] = flying }
    if let flight = view.flight {
      info["flight"] = ["start": [flight.start.x, flight.start.y], "target": [flight.target.x, flight.target.y]]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
