import AppKit
import SolaraUI

@MainActor
enum HostedSmallWindowCard {
  nonisolated static let kind = "smallWindowCard"
  #if DEBUG
    private final class Entry {
      let windowId: String
      weak var view: SmallWindowCardView?
      init(windowId: String, view: SmallWindowCardView) { self.windowId = windowId; self.view = view }
    }
    private static var entries: [UUID: Entry] = [:]
  #endif

  static func register() {
    HostedViews.register(kind) { windowId, json in
      let view = SmallWindowCardView(frame: .zero)
      view.update(SmallWindowCardState.decode(json))
      #if DEBUG
        let id = UUID()
        entries[id] = Entry(windowId: windowId, view: view)
      #endif
      return HostedContent(view: view, onUnmount: {
        view.update(nil)
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: { json in
        view.update(SmallWindowCardState.decode(json))
      })
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [[String: Any]] {
      entries.values.compactMap { entry in
        guard entry.windowId == windowId, let view = entry.view, let state = view.state,
          let root = view.window?.contentView, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: root)
        let frame = root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return ["tabId": state.tabId, "fill": state.fill as Any? ?? NSNull(), "radius": state.radius,
          "frame": [frame.minX, frame.minY, frame.width, frame.height],
          "interceptsInput": view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY)) != nil,
          "focusable": view.acceptsFirstResponder, "accessibilityElement": view.isAccessibilityElement()]
      }
    }
  #endif
}
