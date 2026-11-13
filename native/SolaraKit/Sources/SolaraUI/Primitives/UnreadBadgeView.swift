import AppKit
import QuartzCore

@MainActor
public enum UnreadBadgeLayout {
  public static func text(_ status: TabUnreadStatus) -> String? {
    switch status {
    case .count(let count): count > 99 ? "99+" : String(max(1, count))
    case .dot: nil
    }
  }

  static var font: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .semibold) }

  public static func size(_ status: TabUnreadStatus, scale: CGFloat = 2) -> CGSize {
    guard let text = text(status) else { return CGSize(width: 6, height: 6) }
    let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
    return CGSize(width: max(14, ceil((width + 6) * scale) / scale), height: 14)
  }

  public static func cornerFrame(_ status: TabUnreadStatus, in bounds: CGRect, leading: Bool = false, scale: CGFloat = 2) -> CGRect {
    var size = size(status, scale: scale)
    size.width = min(size.width, max(0, bounds.width - 6))
    return CGRect(x: leading ? bounds.minX + 3 : bounds.maxX - 3 - size.width, y: bounds.minY + 3, width: size.width, height: size.height)
  }

  public static func rowSlot(_ status: TabUnreadStatus?, affordance: CGFloat, scale: CGFloat = 2) -> CGFloat {
    guard let status else { return affordance }
    return max(22, max(affordance, size(status, scale: scale).width + 4))
  }

  public static func trailingFrame(_ status: TabUnreadStatus, in bounds: CGRect, scale: CGFloat = 2) -> CGRect {
    let size = size(status, scale: scale)
    return CGRect(x: bounds.maxX - 6 - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
  }
}

public final class UnreadBadgeView: NSView {
  let plate = CALayer()
  let label = NSTextField(labelWithString: "")
  public private(set) var status: TabUnreadStatus?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.backgroundColor = NSColor(srgbRed: 0.86, green: 0.20, blue: 0.22, alpha: 1).cgColor
    layer?.addSublayer(plate)
    label.font = UnreadBadgeLayout.font
    label.textColor = .white
    label.alignment = .center
    label.lineBreakMode = .byClipping
    label.maximumNumberOfLines = 1
    label.setAccessibilityElement(false)
    setAccessibilityElement(false)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @discardableResult
  public func set(_ status: TabUnreadStatus?) -> Bool {
    guard self.status != status else { return false }
    self.status = status
    isHidden = status == nil
    label.stringValue = status.flatMap(UnreadBadgeLayout.text) ?? ""
    label.isHidden = status == .dot
    if case .count = status {
      if label.superview == nil { addSubview(label) }
    } else {
      label.removeFromSuperview()
    }
    needsLayout = true
    return true
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    plate.cornerRadius = bounds.height / 2
    CATransaction.commit()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
  }
}
