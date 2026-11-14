import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedSelectionBar {
  static let kind = "selectionBar"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  private final class Entry {
    let windowId: String
    weak var view: SelectionBarView?
    var tabId = ""
    var ended = false

    init(windowId: String, view: SelectionBarView) {
      self.windowId = windowId
      self.view = view
    }
  }

  private struct State: Decodable {
    var tabId: String
    var selection: SelectionBarState?
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let view = SelectionBarView(frame: .zero)
      #if DEBUG
        let id = UUID()
      #endif
      let entry = Entry(windowId: windowId, view: view)
      #if DEBUG
        entries[id] = entry
      #endif
      view.onSearch = { [weak entry] click in
        guard let entry, entry.view?.state != nil else { return }
        HostedViews.send(kind, windowId: entry.windowId, "search", ["tabId": entry.tabId, "metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt])
      }
      return HostedContent(
        view: view,
        onUnmount: { [weak view] in
          entry.ended = true
          #if DEBUG
            entries[id] = nil
          #endif
          view?.onSearch = { _ in }
          view?.update(nil)
        },
        takesFocus: false,
        onState: { [weak view] json in
          guard !entry.ended else { return }
          guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(State.self, from: data) else {
            entry.tabId = ""
            view?.update(nil)
            return
          }
          entry.tabId = state.tabId
          view?.update(state.selection)
        })
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [String: Any]? {
      let matches = entries.values.filter { $0.windowId == windowId && $0.view != nil }
      guard !matches.isEmpty else { return nil }
      var tabs: [String: [String: Any]] = [:]
      for entry in matches {
        guard let view = entry.view, view.state != nil else { continue }
        func inWindow(_ rect: CGRect) -> [Double] {
          let frame = view.convert(rect, to: nil)
          let height = view.window?.contentView?.bounds.height ?? 0
          return [frame.minX, height - frame.maxY, frame.width, frame.height]
        }
        tabs[entry.tabId] = ["selection": [
          "hidden": view.isHiddenOrHasHiddenAncestor,
          "area": inWindow(view.bounds),
          "bar": view.barFrame.map(inWindow) ?? NSNull(),
          "button": view.buttonFrame.map(inWindow) ?? NSNull(),
          "above": view.above,
          "opacity": view.presentedOpacity,
        ]]
      }
      return ["tabs": tabs]
    }
  #endif
}
