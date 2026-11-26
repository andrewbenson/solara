import AppKit
import SolaraStore
import SolaraUI

@MainActor
enum HostedToolbarBackdrop {
  nonisolated static let kind = "toolbarBackdrop"

  @MainActor
  private final class Mount {
    private struct Input: Decodable {
      let tabId: String
      let dark: Bool
    }

    let windowId: String
    let view = ToolbarBackdropView(frame: .zero)
    private var input: Input?
    private var store: Store?
    private var listener: Int?
    private var lifecycle: Int?

    init(windowId: String, json: String) {
      self.windowId = windowId
      input = try? JSONDecoder().decode(Input.self, from: Data(json.utf8))
      lifecycle = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.reconcile() }
    }

    func update(_ json: String) {
      let next = try? JSONDecoder().decode(Input.self, from: Data(json.utf8))
      if input?.tabId != next?.tabId { unsubscribe() }
      input = next
      reconcile()
    }

    func end() {
      if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
      lifecycle = nil
      unsubscribe()
      view.update(nil)
    }

    private func unsubscribe() {
      if let listener { store?.unsubscribe(listener) }
      listener = nil
      store = nil
    }

    private func reconcile() {
      let current = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
      if store !== current {
        unsubscribe()
        if let current, let tabId = input?.tabId {
          store = current
          listener = current.subscribe { [weak self, weak current] commit in
            let changes = commit.changes
            guard changes.settings || changes.tabs.upserted.contains(tabId) || changes.tabs.removed.contains(tabId)
              || changes.live.upserted.contains(tabId) || changes.live.removed.contains(tabId) else { return }
            Task { @MainActor in
              guard let self, let current, self.store === current, self.input?.tabId == tabId else { return }
              self.refresh()
            }
          }
        }
      }
      refresh()
    }

    private func refresh() {
      guard let store, let input else { view.update(nil); return }
      view.update(ToolbarBackdropState.resolve(windowId: windowId, tabId: input.tabId, state: store.state, dark: input.dark))
    }
  }

  #if DEBUG
    private final class Entry {
      let windowId: String
      weak var view: ToolbarBackdropView?
      init(windowId: String, view: ToolbarBackdropView) { self.windowId = windowId; self.view = view }
    }
    private static var entries: [UUID: Entry] = [:]
  #endif

  static func register() {
    HostedViews.register(kind) { windowId, json in
      let mount = Mount(windowId: windowId, json: json)
      #if DEBUG
        let id = UUID()
        entries[id] = Entry(windowId: windowId, view: mount.view)
      #endif
      return HostedContent(view: mount.view, onUnmount: {
        mount.end()
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: mount.update)
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [[String: Any]] {
      entries.values.compactMap { entry in
        guard entry.windowId == windowId, let view = entry.view, let state = view.state,
          let root = view.window?.contentView, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: root)
        let frame = root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return ["tabId": state.tabId, "background": state.background as Any? ?? NSNull(), "divider": state.divider,
          "hairline": state.hairline, "stripes": state.stripes as Any? ?? NSNull(),
          "frame": [frame.minX, frame.minY, frame.width, frame.height], "interceptsInput": view.hitTest(view.bounds.origin) != nil]
      }
    }
  #endif
}
