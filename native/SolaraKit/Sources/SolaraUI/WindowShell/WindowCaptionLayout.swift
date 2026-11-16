import AppKit

@MainActor
@objc(SolaraWindowCaptionLayout)
public final class WindowCaptionLayout: NSObject {
  private static let centers = NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)

  @objc(configureWindow:)
  public static func configure(_ window: NSWindow) {
    let frame = window.frame
    window.styleMask.insert(.fullSizeContentView)
    if window.frame != frame { window.setFrame(frame, display: false) }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
  }

  @objc(positionInWindow:center:)
  public static func position(in window: NSWindow, center: CGPoint) {
    centers.setObject(NSValue(point: center), forKey: window)
    guard !window.styleMask.contains(.fullScreen), let frame = window.contentView?.superview,
      let close = window.standardWindowButton(.closeButton) else { return }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    let rects = buttons.map { frame.convert($0.bounds, from: $0) }
    let closeRect = frame.convert(close.bounds, from: close)
    let targetY = frame.isFlipped ? frame.bounds.minY + center.y : frame.bounds.maxY - center.y
    let delta = CGPoint(x: frame.bounds.minX + center.x - closeRect.midX, y: targetY - closeRect.midY)
    let moved = abs(delta.x) > 0.01 || abs(delta.y) > 0.01
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (button, rect) in zip(buttons, rects) {
      guard let parent = button.superview else { continue }
      if moved { button.frame = parent.convert(rect.offsetBy(dx: delta.x, dy: delta.y), from: frame) }
      var ancestor: NSView? = parent
      while let view = ancestor, view !== frame {
        if !view.bounds.contains(view.convert(button.bounds, from: button)) {
          if view.clipsToBounds { view.clipsToBounds = false }
          if view.layer?.masksToBounds == true { view.layer?.masksToBounds = false }
        }
        ancestor = view.superview
      }
    }
    CATransaction.commit()
  }

  public static func refresh(in window: NSWindow) {
    guard let center = centers.object(forKey: window) else { return }
    position(in: window, center: center.pointValue)
  }
}
