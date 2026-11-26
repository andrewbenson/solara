import AppKit
import Foundation
import SolaraUI
import SolaraStore

@MainActor
enum HostedPersonalize {
  nonisolated static let kind = "personalize"
  private static var entries: [UUID: Entry] = [:]
  private static var openWindowId: String?

  private static var workspaceStore: Store? {
    guard NativeStoreHandle.ownsWorkspace, !NativeStoreHandle.frozen else { return nil }
    return NativeStoreHandle.store
  }

  @MainActor private final class Entry {
    let windowId: String
    weak var view: PersonalizeView?
    var ended = false
    var appearance: PersonalizeAppearance?
    var store: Store?
    var subscription: Int?
    var lifecycle: Int?

    init(windowId: String, view: PersonalizeView) { self.windowId = windowId; self.view = view }

    func bind() {
      let next = HostedPersonalize.workspaceStore
      if store !== next {
        update(nil)
        if openWindowId == windowId { setOpen(nil) }
        if let subscription { store?.unsubscribe(subscription) }
        subscription = nil
        store = next
        if let next {
          let windowId = self.windowId
          subscription = next.subscribe { [weak self] commit in
            let changes = commit.changes
            let profileId = commit.state.windows[windowId]?.profileId
            guard changes.windows.upserted.contains(windowId) || changes.windows.removed.contains(windowId)
              || changes.settingsChanged.contains("tabLayout") || changes.settingsRemoved.contains("tabLayout")
              || profileId.map({ changes.profiles.upserted.contains($0) || changes.profiles.removed.contains($0) }) == true else { return }
            DispatchQueue.main.async { self?.refresh() }
          }
        }
      }
      refresh()
    }

    func refresh() {
      guard !ended else { return }
      guard let store, store === HostedPersonalize.workspaceStore, let appearance else {
        update(nil)
        return
      }
      let projected = PersonalizeBehavior.project(store.displayState, windowId: windowId,
        open: openWindowId == windowId, appearance: appearance)
      update(projected)
      if projected == nil && openWindowId == windowId { setOpen(nil) }
    }

    private func update(_ projected: PersonalizeState?) {
      guard let view, view.state != projected else { return }
      view.update(projected)
    }

    func perform(_ action: String, value: String) {
      guard let store else { return }
      do {
        let dispatched = try store.sequence {
          guard !ended, store === HostedPersonalize.workspaceStore,
            let command = PersonalizeBehavior.command(action, value: value, presented: view?.state,
              state: store.state, windowId: windowId, closing: store.memory.closingWindows) else { return false }
          try store.dispatch(command, origin: .native)
          return true
        }
        if dispatched { refresh() }
      } catch let refusal as CommandError where action == "color" && store.config.safeMode {
        let alert = NSAlert()
        alert.messageText = "Safe Mode"
        alert.informativeText = refusal.description
        alert.addButton(withTitle: "OK")
        guard !ended, store === HostedPersonalize.workspaceStore, store.state.windows[windowId] != nil,
          !store.memory.closingWindows.contains(windowId), let window = view?.window,
          window.alphaValue > 0, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else { return }
        alert.beginSheetModal(for: window)
      } catch { NSLog("[new-tab] Personalize action failed: %@", String(describing: error)) }
    }

    func end() {
      ended = true
      if let subscription { store?.unsubscribe(subscription) }
      if let lifecycle { NativeStoreHandle.unsubscribeLifecycle(lifecycle) }
      store = nil
      subscription = nil
      lifecycle = nil
      update(nil)
      if openWindowId == windowId { setOpen(nil) }
    }
  }

  static func setOpen(_ windowId: String?) {
    if let windowId {
      guard let store = workspaceStore, let window = store.state.windows[windowId],
        !window.incognito, !store.memory.closingWindows.contains(windowId),
        entries.values.contains(where: { !$0.ended && $0.windowId == windowId && $0.appearance != nil }) else { return }
    }
    openWindowId = windowId
    for entry in entries.values { entry.refresh() }
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      let view = PersonalizeView(frame: .zero)
      let entry = Entry(windowId: windowId, view: view)
      let id = UUID()
      entries[id] = entry
      entry.lifecycle = NativeStoreHandle.subscribeLifecycle { [weak entry] in entry?.bind() }
      view.onOpen = { [weak entry] open in
        guard let entry, !entry.ended, let store = entry.store, store === workspaceStore,
          !store.memory.closingWindows.contains(entry.windowId), entry.view?.state != nil else { return }
        if open { setOpen(entry.windowId) }
        else if openWindowId == entry.windowId { setOpen(nil) }
      }
      view.onColor = { [weak entry] in entry?.perform("color", value: $0) }
      view.onLayout = { [weak entry] in entry?.perform("layout", value: $0) }
      return HostedContent(view: view, onUnmount: {
        entry.end()
        view.onOpen = { _ in }
        view.onColor = { _ in }
        view.onLayout = { _ in }
        entries[id] = nil
      }, takesFocus: false, onState: { json in
        guard !entry.ended else { return }
        entry.appearance = PersonalizeAppearance.decode(json)
        if entry.appearance == nil && openWindowId == entry.windowId { setOpen(nil) }
        entry.bind()
      })
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ action: String, _ argument: String?) -> [String: Any] {
      guard let view = entries.values.first(where: { $0.windowId == windowId && !$0.ended && $0.view?.window != nil })?.view
        ?? entries.values.first(where: { $0.windowId == windowId && !$0.ended })?.view,
        let state = view.state else { return ["active": false, "found": false] }
      view.layoutSubtreeIfNeeded()
      func controls(_ root: NSView) -> [NSView] {
        let own: [NSView] = root is PersonalizeControl && !root.isHiddenOrHasHiddenAncestor ? [root] : []
        return own + root.subviews.flatMap(controls)
      }
      let all = controls(view)
      func frame(_ rect: CGRect, from source: NSView) -> [Double] {
        let native = source.convert(rect, to: nil)
        let height = source.window?.contentView?.bounds.height ?? view.bounds.height
        return [native.minX, height - native.maxY, native.width, native.height]
      }
      func item(_ control: NSView) -> [String: Any] {
        ["label": control.accessibilityLabel() ?? "", "frame": frame(control.bounds, from: control), "role": control.accessibilityRole()?.rawValue ?? "", "value": control.accessibilityValue() ?? NSNull(), "enabled": true, "found": true]
      }
      let target = all.first { $0.accessibilityLabel() == argument?.components(separatedBy: "|").first }
      switch action {
      case "find": return target.map(item) ?? ["found": false]
      case "press": return ["accepted": target?.accessibilityPerformPress() ?? false]
      case "focus": return ["accepted": target.map { view.window?.makeFirstResponder($0) ?? false } ?? false]
      case "key":
        guard let target, let key = argument?.components(separatedBy: "|").last else { return ["accepted": false] }
        let keys: [String: (String, UInt16)] = ["Space": (" ", 49), "Return": ("\r", 36), "Enter": ("\u{3}", 76), "Tab": ("\t", 48), "Escape": ("\u{1b}", 53)]
        guard let pair = keys[key] else { return ["accepted": false] }
        view.window?.makeFirstResponder(target)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: pair.0, charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)!
          if type == .keyDown { target.keyDown(with: event) } else { target.keyUp(with: event) }
        }
        return ["accepted": true]
      case "close": view.onOpen(false); return ["accepted": true]
      default:
        return ["active": true, "open": state.open, "dark": state.dark, "color": state.color as Any? ?? NSNull(), "layout": state.layout, "profileId": state.profileId as Any? ?? NSNull(), "button": frame(view.buttonFrame, from: view), "panel": view.panelFrame.map { frame($0, from: view) } as Any? ?? NSNull(), "controls": all.map(item)]
      }
    }
  #endif
}
