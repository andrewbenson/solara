import AppKit

public enum FrozenPageIdentity {
  public static func admits(tabId: String, copyId: String, holder: String?, copyHolder: String?) -> Bool {
    if tabId == copyId { return holder?.isEmpty == false }
    return holder == copyId || copyHolder == tabId
  }
}

@MainActor
public final class FrozenPageView: NSView {
  public static let lightWash = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4)
  public static let darkWash = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)

  public var onPress: (() -> Void)?
  public var onPainted: (() -> Void)?
  public private(set) var image: NSImage?
  public var dark = false { didSet { if dark != oldValue { applyWash() } } }

  private let picture = CALayer()
  private let wash = CALayer()

  public override var isFlipped: Bool { true }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    picture.contentsGravity = .resizeAspectFill
    picture.masksToBounds = true
    for sublayer in [picture, wash] {
      sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "backgroundColor": NSNull()]
      layer?.addSublayer(sublayer)
    }
    setAccessibilityRole(.button)
    setAccessibilityLabel("Bring this tab to this window")
    applyWash()
  }

  required init?(coder: NSCoder) { fatalError() }

  public var washColor: NSColor { dark ? Self.darkWash : Self.lightWash }

  public func show(_ image: NSImage?) {
    guard image !== self.image else { return }
    self.image = image
    picture.contents = image?.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    if image != nil { onPainted?() }
  }

  public override func layout() {
    super.layout()
    picture.frame = bounds
    wash.frame = bounds
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  public override func mouseDown(with event: NSEvent) {}

  public override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onPress?()
  }

  public override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  private func applyWash() {
    wash.backgroundColor = washColor.cgColor
  }

  var washLayerColor: CGColor? { wash.backgroundColor }
  var pictureContents: Any? { picture.contents }
}
