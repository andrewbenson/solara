import AppKit

public enum DevPointer {
  public static let changed = Notification.Name("SolaraDevPointerChanged")
  static let fullScreenChanged = Notification.Name("SolaraFullScreenPointerChanged")

  @MainActor
  static func inside(_ view: NSView, _ note: Notification) -> Bool {
    guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, let screen = (note.object as? NSValue)?.pointValue else { return false }
    let point = window.convertPoint(fromScreen: screen)
    if note.name == fullScreenChanged {
      guard let source = note.userInfo?["window"] as? NSWindow, source === window,
        let frame = window.contentView?.superview, let hit = frame.hitTest(point),
        hit === view || hit.isDescendant(of: view) else { return false }
    }
    return view.bounds.contains(view.fullScreenPoint(point))
  }

  @MainActor
  static func observe(_ view: NSView, _ selector: Selector) {
    NotificationCenter.default.addObserver(view, selector: selector, name: changed, object: nil)
    if !(view is WindowShellView) {
      NotificationCenter.default.addObserver(view, selector: selector, name: fullScreenChanged, object: nil)
    }
  }
}
