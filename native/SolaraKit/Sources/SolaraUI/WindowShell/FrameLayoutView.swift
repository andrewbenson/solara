import AppKit

@MainActor
public class FrameLayoutView: NSView {
  private var frameNeedsLayout = true

  public override class var requiresConstraintBasedLayout: Bool { false }

  public override var needsLayout: Bool {
    get { frameNeedsLayout }
    set {
      frameNeedsLayout = newValue
      super.needsLayout = newValue
    }
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = true
  }

  public required init?(coder: NSCoder) { fatalError() }

  public func layoutFrameIfNeeded() {
    guard needsLayout else { return }
    layout()
  }

  public override func layout() {
    frameNeedsLayout = false
    super.layout()
  }

  public override func setBoundsSize(_ newSize: NSSize) {
    let changed = bounds.size != newSize
    super.setBoundsSize(newSize)
    if changed { needsLayout = true }
  }

  public override func setBoundsOrigin(_ newOrigin: NSPoint) {
    let changed = bounds.origin != newOrigin
    super.setBoundsOrigin(newOrigin)
    if changed { needsLayout = true }
  }
}
