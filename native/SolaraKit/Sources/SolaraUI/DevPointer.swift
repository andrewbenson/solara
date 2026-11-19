import AppKit
import ObjectiveC

public enum DevPointer {
  public static let changed = Notification.Name("SolaraDevPointerChanged")
  static let fullScreenChanged = Notification.Name("SolaraFullScreenPointerChanged")
  @MainActor private static var fullScreenObserverKey: UInt8 = 0
  #if DEBUG
  @MainActor private static var screenOverride: NSPoint?
  #endif

  @MainActor
  static func screenPoint(in window: NSWindow) -> NSPoint {
    #if DEBUG
    if let screenOverride { return screenOverride }
    #endif
    return window.convertPoint(toScreen: window.mouseLocationOutsideOfEventStream)
  }

  @MainActor
  static func inside(_ view: NSView, _ note: Notification) -> Bool {
    #if DEBUG
    if note.name == changed { screenOverride = (note.object as? NSValue)?.pointValue }
    #endif
    guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, let screen = (note.object as? NSValue)?.pointValue else { return false }
    let point = window.convertPoint(fromScreen: screen)
    guard !FullScreenIslandCoverage.contains(point, in: window) else { return false }
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
      let observer = FullScreenPointerObserver(view, selector)
      objc_setAssociatedObject(view, &fullScreenObserverKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

@MainActor
private final class FullScreenPointerObserver: NSObject {
  private weak var view: NSView?
  private let selector: Selector

  init(_ view: NSView, _ selector: Selector) {
    self.view = view
    self.selector = selector
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: DevPointer.fullScreenChanged, object: nil)
  }

  @objc private func receive(_ note: Notification) {
    guard let view, let window = view.window,
      let source = note.userInfo?["window"] as? NSWindow, source === window else { return }
    _ = view.perform(selector, with: note)
  }
}
