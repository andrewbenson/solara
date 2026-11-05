import AppKit

@MainActor
final class BookmarksBarNavigation {
  private weak var view: BookmarksBarView?
  private(set) var controls: [BookmarksBarButton] = []
  private var pendingFocus: Focus?
  private weak var previousBoundary: NSView?
  private weak var nextBoundary: NSView?
  private weak var keyViewLoopWindow: NSWindow?

  private struct Focus {
    let id: String
    let ids: [String]
    weak var button: BookmarksBarButton?
  }

  init(view: BookmarksBarView) { self.view = view }

  func captureFocus() {
    guard pendingFocus == nil, let button = focusedButton else { return }
    pendingFocus = Focus(id: button.controlId, ids: controls.map(\.controlId), button: button)
  }

  func prepareToHide(_ button: BookmarksBarButton) {
    guard let window = view?.window, window.firstResponder === button else { return }
    captureFocus()
    window.makeFirstResponder(nil)
  }

  func update(_ buttons: [BookmarksBarButton]) {
    captureFocus()
    let focus = pendingFocus
    pendingFocus = nil
    let visible = buttons.filter(\.isVisibleControl)
    let controlsChanged = visible.map(ObjectIdentifier.init) != controls.map(ObjectIdentifier.init)
    controls = visible
    for button in controls {
      button.onKey = { [weak self, weak button] key, flags in
        guard let self, let button else { return false }
        return self.handle(key: key, flags: flags, from: button)
      }
    }
    if controlsChanged || view?.window !== keyViewLoopWindow { rebuildKeyViewLoop() }
    guard let focus, let window = view?.window,
      window.firstResponder === focus.button || window.firstResponder === window else { return }
    let id = BookmarksBarKeyboard.repairedFocus(focusedId: focus.id, previousIds: focus.ids, controlIds: controls.map(\.controlId))
    if let button = controls.first(where: { $0.controlId == id }), button.acceptsFirstResponder {
      if window.firstResponder !== button { window.makeFirstResponder(button) }
    } else {
      leaveBar()
    }
  }

  private var focusedButton: BookmarksBarButton? {
    guard let button = view?.window?.firstResponder as? BookmarksBarButton,
      controls.contains(where: { $0 === button }) else { return nil }
    return button
  }

  private func rebuildKeyViewLoop() {
    keyViewLoopWindow = view?.window
    guard let window = view?.window else { return }
    window.recalculateKeyViewLoop()
    previousBoundary = nil
    nextBoundary = nil
    guard let first = controls.first, let last = controls.last else { return }
    let previous = outsideKeyView(from: first, forward: false)
    let next = outsideKeyView(from: last, forward: true)
    previousBoundary = previous
    nextBoundary = next
    if let previous { previous.nextKeyView = first }
    for (button, following) in zip(controls, controls.dropFirst()) { button.nextKeyView = following }
    last.nextKeyView = next
  }

  func detach() {
    if let view, let next = previousBoundary?.nextKeyView, next === view || next.isDescendant(of: view) {
      previousBoundary?.nextKeyView = nextBoundary
    }
    previousBoundary = nil
    nextBoundary = nil
    keyViewLoopWindow = nil
    pendingFocus = nil
  }

  private func outsideKeyView(from button: NSView, forward: Bool) -> NSView? {
    var candidate = forward ? button.nextKeyView : button.previousKeyView
    var visited: Set<ObjectIdentifier> = []
    while let current = candidate, visited.insert(ObjectIdentifier(current)).inserted {
      if current !== view && !(current.isDescendant(of: view ?? button)) { return current }
      candidate = forward ? current.nextKeyView : current.previousKeyView
    }
    return nil
  }

  @discardableResult
  private func handle(key: String, flags: NSEvent.ModifierFlags, from button: BookmarksBarButton, focus: ((BookmarksBarButton?) -> Void)? = nil) -> Bool {
    guard controls.contains(where: { $0 === button }),
      BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: button.fullKeyboardAccessEnabled, visible: button.isVisibleControl) else { return false }
    let action = BookmarksBarKeyboard.action(key: key, modifiers: flags, kind: button.controlKind)
    switch action {
    case .previous, .next, .first, .last:
      let id = BookmarksBarKeyboard.destination(for: action, focusedId: button.controlId, controlIds: controls.map(\.controlId))
      guard let target = controls.first(where: { $0.controlId == id }) else { return false }
      if let focus { focus(target) } else { view?.window?.makeFirstResponder(target) }
    case .press(let flags): button.onPress(flags, false)
    case .menu: button.onOpenMenu()
    case .contextMenu: button.onContext()
    case .page:
      if let focus { focus(nil) } else { view?.cancelOperation(nil) }
    case .unhandled: return false
    }
    return true
  }

  func leaveBar() {
    guard let view, let window = view.window, window.makeFirstResponder(nil) else { return }
    view.onFocusPage()
  }

  #if DEBUG
  func devKey(key: String, id: String?, flags: NSEvent.ModifierFlags, fullKeyboardAccess: Bool) -> [String: Any] {
    let access = controls.map(\.devFullKeyboardAccess)
    for button in controls { button.devFullKeyboardAccess = fullKeyboardAccess }
    defer { for (button, value) in zip(controls, access) { button.devFullKeyboardAccess = value } }
    let keyViews = controls.filter { $0.acceptsFirstResponder && (view?.window == nil || $0.canBecomeKeyView) }.map(\.controlId)
    guard let button = controls.first(where: { $0.controlId == id }), keyViews.contains(button.controlId) else {
      if focusedButton != nil { leaveBar() }
      return ["accepted": false, "focusedId": NSNull(), "keyViews": keyViews]
    }
    var focusedId: String? = button.controlId
    let accepted: Bool
    if let window = view?.window {
      guard window.makeFirstResponder(button) else { return ["accepted": false, "focusedId": NSNull(), "keyViews": keyViews] }
      accepted = handle(key: key, flags: flags, from: button)
      focusedId = focusedButton?.controlId
    } else {
      accepted = handle(key: key, flags: flags, from: button) { focusedId = $0?.controlId }
    }
    return ["accepted": accepted, "focusedId": focusedId as Any? ?? NSNull(), "keyViews": keyViews]
  }
  #endif
}
