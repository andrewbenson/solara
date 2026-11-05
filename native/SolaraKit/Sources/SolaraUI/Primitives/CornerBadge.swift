import AppKit
import QuartzCore

public enum CornerBadgeCorner: Equatable, Sendable {
  case topTrailing
  case bottomTrailing
}

public enum CornerBadgeShape: Equatable {
  case glyph(symbol: String, scale: CGFloat, color: NSColor)
  case dot(ring: NSColor?)
  case chip(text: String, font: NSFont, color: NSColor, minWidth: CGFloat, radius: CGFloat)
}

public struct CornerBadgeSpec: Equatable {
  public var shape: CornerBadgeShape
  public var fill: NSColor
  public var corner: CornerBadgeCorner
  public var size: CGFloat
  public var outset: CGPoint

  public init(shape: CornerBadgeShape, fill: NSColor, corner: CornerBadgeCorner, size: CGFloat, outset: CGPoint) {
    self.shape = shape
    self.fill = fill
    self.corner = corner
    self.size = size
    self.outset = outset
  }

  public static func circle(_ shape: CornerBadgeShape, fill: NSColor, corner: CornerBadgeCorner, diameter: CGFloat, overhang: CGFloat) -> CornerBadgeSpec {
    CornerBadgeSpec(shape: shape, fill: fill, corner: corner, size: diameter, outset: CGPoint(x: diameter * overhang, y: diameter * overhang))
  }

  public static let chipTextLimit = 4
  static let chipTextPadding: CGFloat = 5

  func width(scale: CGFloat) -> CGFloat {
    guard case .chip(let text, let font, _, let minWidth, _) = shape else { return size }
    let textWidth = Self.chipText(text, font: font).size().width
    return max(minWidth, ceil((textWidth + Self.chipTextPadding) * scale) / scale)
  }

  static func chipText(_ text: String, font: NSFont, color: NSColor = .white) -> NSAttributedString {
    NSAttributedString(string: String(text.prefix(chipTextLimit)), attributes: [.font: font, .foregroundColor: color])
  }

  public func frame(in box: CGSize, scale: CGFloat) -> CGRect {
    let w = width(scale: scale)
    let x = box.width - w + outset.x
    let y = corner == .topTrailing ? -outset.y : box.height - size + outset.y
    return CGRect(x: x, y: y, width: w, height: size)
  }
}

public final class CornerBadge: NSView {
  let plate = CALayer()
  private let glyph = SymbolView()
  private let label = NSTextField(labelWithString: "")
  public private(set) var spec: CornerBadgeSpec?
  public private(set) var badgeFrame: CGRect = .zero

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    plate.actions = SurfaceLayer.noActions
    layer?.addSublayer(plate)
    label.isSelectable = false
    glyph.isHidden = true
    label.isHidden = true
    addSubview(glyph)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func show(_ spec: CornerBadgeSpec, in box: CGSize) {
    self.spec = spec
    let scale = window?.backingScaleFactor ?? 2
    let badge = spec.frame(in: box, scale: scale)
    badgeFrame = badge
    let holder = CGRect(x: badge.minX.rounded(.down), y: badge.minY.rounded(.down), width: 0, height: 0)
    let local = badge.offsetBy(dx: -holder.minX, dy: -holder.minY)
    frame = CGRect(origin: holder.origin, size: CGSize(width: local.maxX.rounded(.up), height: local.maxY.rounded(.up)))
    MediaMotion.setInstantly {
      plate.frame = local
      plate.backgroundColor = spec.fill.cgColor
      plate.borderWidth = 0
      switch spec.shape {
      case .glyph, .dot:
        plate.cornerRadius = spec.size / 2
      case .chip(_, _, _, _, let radius):
        plate.cornerRadius = radius
      }
      if case .dot(let ring?) = spec.shape {
        plate.borderWidth = 1
        plate.borderColor = ring.cgColor
      }
    }
    glyph.isHidden = true
    label.isHidden = true
    switch spec.shape {
    case .glyph(let symbol, let glyphScale, let color):
      glyph.isHidden = false
      glyph.frame = local
      glyph.set(symbol, size: spec.size * glyphScale, weight: .bold, color: color)
    case .dot:
      break
    case .chip(let text, let font, let color, _, _):
      label.isHidden = false
      label.attributedStringValue = CornerBadgeSpec.chipText(text, font: font, color: color)
      let textWidth = label.attributedStringValue.size().width
      let h = ceil(label.intrinsicContentSize.height)
      label.frame = CGRect(x: local.minX + (local.width - textWidth) / 2 - 2, y: local.minY + (spec.size - h) / 2, width: ceil(textWidth) + CornerBadgeSpec.chipTextPadding, height: h)
    }
  }
}
