import AppKit
import Foundation
import SolaraModel
import SolaraUI
#if canImport(SolaraShaders)
  import SolaraShaders
#endif

@MainActor
enum HostedPostcard {
  nonisolated static let postcardKind = "releaseNotesPostcard"
  nonisolated static let pageKind = "releaseNotesPage"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  @MainActor
  private final class Entry {
    let windowId: String
    let kind: String
    weak var view: PostcardView?
    let focus = HostedFocusRestoration()
    let context: HostedNoticeContext
    var payload: JSONObject?
    var listener: UUID?
    private var displayedReceipt: UUID?
    private var lastPageReceipt: UUID?
    var ended = false

    init(windowId: String, kind: String, view: PostcardView) {
      self.windowId = windowId
      self.kind = kind
      self.view = view
      context = HostedNoticeContext(windowId: windowId, explicitPage: kind == pageKind)
    }

    func refresh() {
      guard !ended else { return }
      let notices = NativeNewTabNotices.shared
      let page = notices.page.flatMap { $0.windowId == windowId ? $0 : nil }
      let pending = page == nil ? notices.pending : nil
      let receipt = kind == pageKind ? page?.id : pending?.id
      let version = kind == pageKind ? page?.version : pending?.version
      let product = NativeNewTabNotices.productName
      var state: PostcardState?
      if var input = payload, let receipt, let version,
        let notes = NewTabNoticeCatalog.notes(version: version, product: product),
        let bytes = try? JSONEncoder().encode(notes),
        let json = try? JSONValue.parse(String(decoding: bytes, as: UTF8.self)) {
        input["notes"] = json
        input["product"] = .string(product)
        state = context.project(input, receipt: receipt, receiptKey: "presentationId", postcard: true).flatMap(PostcardState.decode)
      }
      displayedReceipt = state == nil ? nil : receipt
      if kind == pageKind, let displayedReceipt { lastPageReceipt = displayedReceipt }
      focus.updateContext(state?.focusContext)
      if let view, view.state != state {
        if state == nil, let window = view.window, let responder = window.firstResponder as? NSView,
          responder === view || responder.isDescendant(of: view) {
          window.makeFirstResponder(nil)
        }
        view.update(state)
      }
    }

    func perform(_ action: String, state: PostcardState) {
      guard !ended, view?.state == state, let receipt = displayedReceipt,
        let current = context.current(state.presentationId) else { return }
      let notices = NativeNewTabNotices.shared
      let restore = {
        self.focus.updateContext(current.focusContext)
        if self.context.canRestoreFocus { self.focus.restore() }
      }
      switch (kind, action) {
      case (postcardKind, "open"):
        notices.open(state.notes.version, windowId: windowId, matching: receipt, beforeUpdate: restore)
      case (postcardKind, "dismiss"):
        notices.retire(receipt, beforeUpdate: restore)
      case (pageKind, "close"):
        notices.closePage(receipt, beforeUpdate: restore)
      default: break
      }
    }

    func end() {
      ended = true
      if let listener { NativeNewTabNotices.shared.unsubscribe(listener) }
      context.stop()
      focus.cancel()
      if let lastPageReceipt { NativeNewTabNotices.shared.closePage(lastPageReceipt) }
    }
  }

  static func register() {
    for (kind, mode) in [(postcardKind, PostcardView.Mode.postcard), (pageKind, .page)] {
      HostedViews.register(kind) { windowId in
        let view = PostcardView(mode: mode)
        let entry = Entry(windowId: windowId, kind: kind, view: view)
        entry.context.onChange = { [weak entry] in entry?.refresh() }
        entry.context.observe()
        entry.listener = NativeNewTabNotices.shared.subscribe { [weak entry] in entry?.refresh() }
        #if canImport(SolaraShaders)
          view.makeBackdrop = { colors in EarlyBackdrop.make(["colors": colors, "vibrancy": false, "angle": 150, "grainOpacity": 0.1]) }
        #endif
        #if DEBUG
          let id = UUID()
          entries[id] = entry
        #endif
        view.onAction = { [weak entry] in entry?.perform($0, state: $1) }
        return HostedContent(view: view, onUnmount: {
          entry.end()
          view.update(nil)
          view.onAction = { _, _ in }
          #if DEBUG
            entries[id] = nil
          #endif
        }, takesFocus: false, focusRestoration: entry.focus, onState: { json in
          guard !entry.ended else { return }
          entry.payload = (try? JSONValue.parse(json))?.object
          entry.refresh()
        })
      }
    }
  }

  #if DEBUG
    static func drive(_ windowId: String, _ kind: String, _ action: String, _ argument: String?) -> [String: Any] {
      guard let view = entries.values.first(where: { $0.windowId == windowId && $0.kind == kind && !$0.ended && $0.view?.window != nil })?.view
        ?? entries.values.first(where: { $0.windowId == windowId && $0.kind == kind && !$0.ended })?.view,
        let state = view.state else { return ["active": false, "found": false] }
      view.layoutSubtreeIfNeeded()
      func controls(_ root: NSView) -> [PostcardControl] {
        let own = (root as? PostcardControl).map { !$0.isHiddenOrHasHiddenAncestor && $0.isAccessibilityElement() ? [$0] : [] } ?? []
        return own + root.subviews.flatMap(controls)
      }
      func frame(_ rect: CGRect, from source: NSView) -> [Double] {
        let native = source.convert(rect, to: nil)
        let height = source.window?.contentView?.bounds.height ?? view.bounds.height
        return [native.minX, height - native.maxY, native.width, native.height]
      }
      func item(_ control: PostcardControl) -> [String: Any] {
        ["label": control.accessibilityLabel() ?? "", "frame": frame(control.bounds, from: control), "role": control.accessibilityRole()?.rawValue ?? "", "enabled": control.acceptsFirstResponder && control.interactionEnabled, "firstMouse": control.acceptsFirstMouse(for: nil), "found": true]
      }
      let all = controls(view)
      let target = all.first { $0.accessibilityLabel() == argument?.components(separatedBy: "|").first }
      switch action {
      case "find": return target.map(item) ?? ["found": false]
      case "press": return ["accepted": target?.accessibilityPerformPress() ?? false]
      case "focus": return ["accepted": target.map { view.window?.makeFirstResponder($0) ?? false } ?? false]
      case "hover": view.setHovered(argument == "true")
      case "motion": if let elapsed = argument.flatMap(Double.init) { view.inspectMotion(elapsed) }
      case "key":
        let key = argument?.components(separatedBy: "|").last ?? ""
        let keys: [String: (String, UInt16)] = ["Space": (" ", 49), "Return": ("\r", 36), "Enter": ("\u{3}", 76), "Tab": ("\t", 48), "Escape": ("\u{1b}", 53)]
        guard let pair = keys[key] else { return ["accepted": false] }
        let receiver: NSView = target ?? view
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: pair.0, charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)!
          if type == .keyDown { receiver.keyDown(with: event) } else { receiver.keyUp(with: event) }
        }
        return ["accepted": true]
      default: break
      }
      return ["active": true, "mode": view.mode.rawValue, "profileId": state.profileId, "version": state.notes.version, "dark": state.dark, "hovered": view.hovered, "leaving": view.leaving, "card": frame(view.cardFrame, from: view), "page": frame(view.pageFrame, from: view), "controls": controls(view).map(item), "motion": view.motion, "trace": view.trace]
    }
  #endif
}
