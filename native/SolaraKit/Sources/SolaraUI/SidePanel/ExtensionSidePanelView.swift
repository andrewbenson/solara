import AppKit
import QuartzCore

public enum SidePanelMetrics {
  public static let minWidth: CGFloat = 320
  public static let maxWidth: CGFloat = 600
  public static let defaultWidth: CGFloat = 360
  public static let appearDuration: Double = 0.2
  public static let settleDuration: Double = 0.26
  public static let settleOvershoot: Double = 1.2
  public static let header: CGFloat = 40
  public static let padLeft: CGFloat = 12
  public static let padRight: CGFloat = 5
  public static let gap: CGFloat = 8
  public static let labelInset: CGFloat = 2
  public static let icon: CGFloat = 16
  public static let button: CGFloat = 30
  public static let gripOffset: CGFloat = -3
  public static let gripWidth: CGFloat = 7

  public static func rubberBand(_ width: CGFloat) -> CGFloat {
    let band = { (over: CGFloat) in 36 * (1 - exp(-over / 90)) }
    if width > maxWidth { return maxWidth + band(width - maxWidth) }
    if width < minWidth { return minWidth - band(minWidth - width) }
    return width
  }

  public static func clamp(_ width: CGFloat) -> CGFloat { min(maxWidth, max(minWidth, width)) }
}

public struct SidePanelLook: Equatable {
  public var card: NSColor
  public var text: NSColor
  public var icon: NSColor
  public var hover: NSColor
  public var pressed: NSColor
  public var hairline: NSColor
  public var radius: CGFloat

  public init(card: NSColor, text: NSColor, icon: NSColor, hover: NSColor, pressed: NSColor, hairline: NSColor, radius: CGFloat) {
    self.card = card
    self.text = text
    self.icon = icon
    self.hover = hover
    self.pressed = pressed
    self.hairline = hairline
    self.radius = radius
  }
}

public struct SidePanelFrames: Equatable {
  public let panel: CGRect
  public let grip: CGRect
  public let icon: CGRect?
  public let title: CGRect
  public let menu: CGRect
  public let close: CGRect
  public let hairline: CGRect
  public let content: CGRect

  public init(bounds: CGRect, width: CGFloat, hasIcon: Bool) {
    let m = SidePanelMetrics.self
    panel = CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    grip = CGRect(x: panel.minX + m.gripOffset, y: 0, width: m.gripWidth, height: bounds.height)
    close = CGRect(x: width - m.padRight - m.button, y: (m.header - m.button) / 2, width: m.button, height: m.button)
    menu = close.offsetBy(dx: -(m.gap + m.button), dy: 0)
    icon = hasIcon ? CGRect(x: m.padLeft, y: (m.header - m.icon) / 2, width: m.icon, height: m.icon) : nil
    let titleX = icon.map { $0.maxX + m.gap } ?? m.padLeft
    title = CGRect(x: titleX, y: 0, width: max(0, menu.minX - m.gap - titleX), height: m.header)
    hairline = CGRect(x: 0, y: m.header, width: width, height: 1)
    content = CGRect(x: 0, y: m.header + 1, width: width, height: max(0, bounds.height - m.header - 1))
  }
}

public final class ExtensionSidePanelView: NSView {
  public var onMenu: (() -> Void)?
  public var onClose: (() -> Void)?
  public var onResize: ((CGFloat, Bool) -> Void)?
  public var onResetWidth: (() -> Void)?
  public var onWillLeaveWindow: (() -> Void)?
  public let content = SidePanelFlippedView()
  public private(set) var width = SidePanelMetrics.defaultWidth

  private let panel = SidePanelFlippedView()
  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let menuButton = SidebarIconButton()
  private let closeButton = SidebarIconButton()
  private let hairline = CALayer()
  private let grip = SidePanelGrip()
  private var look: SidePanelLook?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    panel.wantsLayer = true
    panel.layer?.masksToBounds = true
    panel.layer?.cornerCurve = .continuous
    hairline.actions = SurfaceLayer.noActions
    panel.layer?.addSublayer(hairline)
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.white.cgColor
    iconView.imageScaling = .scaleProportionallyUpOrDown
    titleField.font = .systemFont(ofSize: 13, weight: .medium)
    titleField.lineBreakMode = .byTruncatingTail
    titleField.maximumNumberOfLines = 1
    titleField.cell?.truncatesLastVisibleLine = true
    menuButton.onPress = { [weak self] in self?.onMenu?() }
    closeButton.onPress = { [weak self] in self?.onClose?() }
    grip.onDrag = { [weak self] width, ended in self?.onResize?(width, ended) }
    grip.onDoubleClick = { [weak self] in self?.onResetWidth?() }
    grip.startWidth = { [weak self] in self?.width ?? SidePanelMetrics.defaultWidth }
    for view in [content, iconView, titleField, menuButton, closeButton] as [NSView] { panel.addSubview(view) }
    addSubview(panel)
    addSubview(grip)
  }

  required init?(coder: NSCoder) { nil }

  public func set(title: String, icon: NSImage?, width: CGFloat, look: SidePanelLook) {
    titleField.stringValue = title
    iconView.image = icon
    iconView.isHidden = icon == nil
    self.width = width
    if self.look != look {
      self.look = look
      titleField.textColor = look.text
      for button in [menuButton, closeButton] {
        button.hoverFill = look.hover
        button.pressedFill = look.pressed
        button.radius = 7
      }
      menuButton.set("ellipsis", size: 13, weight: .regular, color: look.icon, tooltip: "More")
      closeButton.set("xmark", size: 12, weight: .medium, color: look.icon, tooltip: "Close Side Panel")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      panel.layer?.backgroundColor = look.card.cgColor
      panel.layer?.cornerRadius = look.radius
      hairline.backgroundColor = look.hairline.cgColor
      CATransaction.commit()
    }
    needsLayout = true
  }

  public var frames: SidePanelFrames { SidePanelFrames(bounds: bounds, width: width, hasIcon: iconView.image != nil) }

  public override func layout() {
    super.layout()
    let f = frames
    panel.frame = f.panel
    grip.frame = f.grip
    iconView.frame = f.icon ?? .zero
    let lineHeight = ceil(titleField.intrinsicContentSize.height)
    let inset = SidePanelMetrics.labelInset
    titleField.frame = CGRect(x: f.title.minX - inset, y: f.title.midY - lineHeight / 2, width: f.title.width + 2 * inset, height: lineHeight)
    menuButton.frame = f.menu
    closeButton.frame = f.close
    content.frame = f.content
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hairline.frame = f.hairline
    CATransaction.commit()
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, window != nil { onWillLeaveWindow?() }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if grip.frame.contains(local) { return grip }
    guard panel.frame.contains(local) else { return nil }
    return super.hitTest(point)
  }
}

public final class SidePanelFlippedView: NSView {
  public override var isFlipped: Bool { true }
}

final class SidePanelGrip: NSView {
  var onDrag: ((CGFloat, Bool) -> Void)?
  var onDoubleClick: (() -> Void)?
  var startWidth: (() -> CGFloat)?
  private var start: (x: CGFloat, width: CGFloat)?

  override var isFlipped: Bool { true }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      start = nil
      return onDoubleClick?() ?? ()
    }
    start = (event.locationInWindow.x, startWidth?() ?? SidePanelMetrics.defaultWidth)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    onDrag?(SidePanelMetrics.rubberBand(start.width - (event.locationInWindow.x - start.x)), false)
  }

  override func mouseUp(with event: NSEvent) {
    guard let start else { return }
    self.start = nil
    onDrag?(SidePanelMetrics.rubberBand(start.width - (event.locationInWindow.x - start.x)), true)
  }
}
