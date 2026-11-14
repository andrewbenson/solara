import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedGroupPanel {
  nonisolated static let kind = "groupPanel"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  private struct State: Decodable {
    var card: SidebarGroupCardState
    var live: Bool
    var token: String
    var newTabMark: String?
  }

  @MainActor
  private final class Entry {
    let windowId: String
    let view: SidebarGroupCardView
    var state: State?
    var ended = false
    private var mark: String?
    private var markTask: Task<Void, Never>?

    init(windowId: String) {
      self.windowId = windowId
      let favicons = SidebarFavicons()
      favicons.loader = { request in try await NativeSidebar.favicon(request) }
      view = SidebarGroupCardView(favicons: favicons)
      view.onPointer = { [weak self] inside in self?.send(inside ? "enter" : "leave") }
      view.onEvent = { [weak self] event in
        guard let self else { return }
        switch event {
        case .choose(let id): send("choose", ["tabId": id])
        case .close: send("close")
        case .hold(let held): send(held ? "hold" : "release")
        case .focusPage: send("focusPage")
        }
      }
    }

    func update(_ json: String) {
      guard !ended else { return }
      guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(State.self, from: data) else {
        view.live = false
        view.isHidden = true
        state = nil
        return
      }
      state = next
      view.live = next.live
      view.isHidden = false
      view.set(next.card)
      if mark != next.newTabMark { loadMark(next.newTabMark) }
    }

    func send(_ name: String, _ payload: [String: Any] = [:]) {
      guard !ended, let state else { return }
      var payload = payload
      payload["groupId"] = state.card.groupId
      payload["token"] = state.token
      HostedViews.send(kind, windowId: windowId, name, payload)
    }

    private func loadMark(_ uri: String?) {
      markTask?.cancel()
      mark = uri
      view.favicons.newTabMark = nil
      guard let uri, !uri.isEmpty else { return }
      if let image = SettingsAdapters.image(uri) {
        view.favicons.newTabMark = image
        if let state { view.set(state.card) }
        return
      }
      markTask = Task { @MainActor [weak self] in
        guard let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        let data = try? await URLSession.shared.data(for: request).0
        guard !Task.isCancelled, let self, !ended, mark == uri else { return }
        view.favicons.newTabMark = data.flatMap(NSImage.init(data:))
        if let state { view.set(state.card) }
      }
    }

    func end() {
      view.live = false
      ended = true
      markTask?.cancel()
      markTask = nil
      view.onEvent = nil
      view.onPointer = nil
      state = nil
    }
  }

  static func register() {
    HostedViews.register(kind) { windowId, json in
      let entry = Entry(windowId: windowId)
      #if DEBUG
        let id = UUID()
        entries[id] = entry
      #endif
      entry.update(json)
      return HostedContent(view: entry.view, onUnmount: {
        entry.end()
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: { entry.update($0) })
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ action: String, _ argument: String?) -> [String: Any] {
      guard let entry = entries.values.first(where: { $0.windowId == windowId && !$0.ended && !$0.view.isHiddenOrHasHiddenAncestor }),
        let state = entry.state else { return ["found": false] }
      let view = entry.view
      let fields = view.subviews.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
      let field = fields.first
      switch action {
      case "query":
        field?.stringValue = argument ?? ""
        if let field { view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field)) }
      case "down", "up", "Return", "Escape":
        let selectors = ["down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
          "Return": #selector(NSResponder.insertNewline(_:)), "Escape": #selector(NSResponder.cancelOperation(_:))]
        if let field, let selector = selectors[action] { _ = view.control(field, textView: NSTextView(), doCommandBy: selector) }
      case "press":
        walk(view).first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == argument }?.accessibilityPerformPress()
      default: break
      }
      view.layoutSubtreeIfNeeded()
      func frame(_ control: NSView) -> [Double] {
        let rect = control.convert(control.bounds, to: nil)
        return [rect.minX, (control.window?.contentView?.bounds.height ?? 0) - rect.maxY, rect.width, rect.height]
      }
      let rows = walk(view).filter { $0.accessibilityRole() == .button }
      var buttons: [String: [Double]] = [:]
      for control in rows {
        if let label = control.accessibilityLabel() { buttons[label] = frame(control) }
      }
      return ["found": true, "groupId": state.card.groupId, "live": state.live, "frame": frame(view),
        "rows": state.card.rows.map(\.id), "query": field?.stringValue ?? "", "buttons": buttons,
        "typingInCard": (view.window?.firstResponder as? NSView).map { $0.isDescendant(of: view) } ?? false,
        "searchLabel": field?.accessibilityLabel() ?? "", "firstMouse": rows.first?.acceptsFirstMouse(for: nil) ?? false]
    }

    private static func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
  #endif
}
