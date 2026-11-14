import AppKit
import QuartzCore

public struct SelectionBarState: Decodable, Equatable, Sendable {
  public var key: String
  public var top: Double
  public var bottom: Double
  public var center: Double
  public var dark: Bool
  public var icon: String
  public var textPrimary: String
  public var tooltip: String
  public var label: String

  public init(key: String, top: Double, bottom: Double, center: Double, dark: Bool, icon: String, textPrimary: String, tooltip: String, label: String) {
    self.key = key
    self.top = top
    self.bottom = bottom
    self.center = center
    self.dark = dark
    self.icon = icon
    self.textPrimary = textPrimary
    self.tooltip = tooltip
    self.label = label
  }
}

public struct SelectionBarClick: Equatable, Sendable {
  public var meta = false
  public var shift = false
  public var alt = false
}

public enum SelectionBarMetrics {
  public static let height: CGFloat = 32
  public static let gap: CGFloat = 6
  public static let edge: CGFloat = 4
  public static let margin: CGFloat = 8
  public static let padding: CGFloat = 3
  public static let border: CGFloat = 0.5
  public static let radius: CGFloat = 10
  public static let buttonRadius: CGFloat = 7
  public static let buttonLeft: CGFloat = 7
  public static let buttonRight: CGFloat = 9
  public static let glyph: CGFloat = 16
  public static let glyphGap: CGFloat = 5
  public static let appear = (duration: 0.15, easing: RNEasing.outCubic)
  public static let fromScale = 0.94
  public static let fromShift = 3.0
}

@MainActor
public final class SelectionBarView: NSView {
  public var onSearch: (SelectionBarClick) -> Void = { _ in }
  public private(set) var state: SelectionBarState?
  public private(set) var barFrame: CGRect?
  public private(set) var above = true
  private var shownKey: String?
  private var appearedAt: CFTimeInterval = 0
  private let motion = PrimitiveFlippedView()
  private let bar = PrimitiveFlippedView()
  private let surface = SurfaceLayer()
  private let effect = NSVisualEffectView()
  private let overlay = PrimitiveFlippedView()
  private let rim = SurfaceLayer()
  private let button = PromptPressable(frame: .zero)
  private let glyph = NSImageView()
  private let title = NSTextField(labelWithString: "Search")

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    motion.wantsLayer = true
    addSubview(motion)
    bar.wantsLayer = true
    bar.layer?.masksToBounds = false
    bar.layer?.addSublayer(surface)
    surface.radius = SelectionBarMetrics.radius
    surface.glowColor = .black
    surface.glowRadius = 14
    surface.glowOffset = CGSize(width: 0, height: 6)
    effect.material = .menu
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = SelectionBarMetrics.radius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    bar.addSubview(effect)
    overlay.wantsLayer = true
    overlay.layer?.cornerRadius = SelectionBarMetrics.radius
    overlay.layer?.cornerCurve = .continuous
    bar.addSubview(overlay)
    button.acceptsFirstClick = true
    button.wantsLayer = true
    button.layer?.cornerRadius = SelectionBarMetrics.buttonRadius
    button.setAccessibilityRole(.button)
    button.onPress = { [weak self] in
      let flags = NSApp.currentEvent?.modifierFlags ?? []
      self?.onSearch(SelectionBarClick(meta: flags.contains(.command), shift: flags.contains(.shift), alt: flags.contains(.option)))
    }
    glyph.imageScaling = .scaleNone
    button.addSubview(glyph)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.isSelectable = false
    button.addSubview(title)
    bar.addSubview(button)
    rim.radius = SelectionBarMetrics.radius
    rim.border = SelectionBarMetrics.border
    rim.zPosition = 10
    bar.layer?.addSublayer(rim)
    motion.addSubview(bar)
    motion.layer?.opacity = 0
    motion.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !motion.isHidden, let barFrame else { return nil }
    let local = convert(point, from: superview)
    guard barFrame.contains(local) else { return nil }
    return super.hitTest(point)
  }

  public func update(_ next: SelectionBarState?) {
    state = next
    style()
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public override func layout() {
    super.layout()
    place()
  }

  public var buttonFrame: CGRect? { motion.isHidden ? nil : button.convert(button.bounds, to: self) }
  public var presentedOpacity: Double { Double(motion.layer?.presentation()?.opacity ?? motion.layer?.opacity ?? 0) }

  private func style() {
    guard let state else { return }
    let dark = state.dark
    surface.fill = CSSColor(dark ? "rgba(38,36,37,0.94)" : "rgba(252,251,252,0.96)")?.ns
    surface.glowOpacity = dark ? 0.45 : 0.16
    rim.borderTint = CSSColor(dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")?.ns
    effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    overlay.layer?.backgroundColor = CSSColor(dark ? "rgba(38,36,37,0.72)" : "rgba(252,251,252,0.7)")?.cg
    button.fill = { hovered, pressed in rowFill(dark: dark, hovered: hovered, pressed: pressed) }
    button.refresh()
    button.toolTip = state.tooltip
    button.setAccessibilityLabel(state.label)
    glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    glyph.contentTintColor = CSSColor(state.icon)?.ns
    let ink = CSSColor(state.textPrimary)?.ns ?? .labelColor
    title.textColor = ink.withAlphaComponent(1)
    title.alphaValue = ink.alphaComponent
  }

  private func place() {
    let M = SelectionBarMetrics.self
    guard let state, bounds.width > 0, CGFloat(state.bottom) >= 0, CGFloat(state.top) <= bounds.height else {
      barFrame = nil
      motion.isHidden = true
      shownKey = nil
      return
    }
    let top = CGFloat(state.top)
    let bottom = CGFloat(state.bottom)
    above = top - M.gap - M.height >= M.edge
    let y = above ? top - M.gap - M.height : min(bottom + M.gap, bounds.height - M.height - M.edge)
    let scale = window?.backingScaleFactor ?? 2
    let textWidth = ceil(title.intrinsicContentSize.width * scale) / scale
    let buttonWidth = M.buttonLeft + M.glyph + M.glyphGap + textWidth + M.buttonRight
    let inset = M.padding + M.border
    let width = inset * 2 + buttonWidth
    let x = max(M.margin, min(CGFloat(state.center) - width / 2, bounds.width - width - M.margin))
    let frame = CGRect(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale, width: width, height: M.height)
    barFrame = frame
    PrimitiveMotion.setInstantly {
      motion.frame = bounds
      bar.frame = frame
      let local = CGRect(origin: .zero, size: frame.size)
      surface.frame = local
      rim.frame = local
    }
    effect.frame = bar.bounds
    overlay.frame = bar.bounds
    button.frame = CGRect(x: inset, y: M.padding, width: buttonWidth, height: M.height - 2 * M.padding)
    glyph.frame = CGRect(x: M.buttonLeft, y: (button.frame.height - M.glyph) / 2, width: M.glyph, height: M.glyph)
    let th = title.intrinsicContentSize.height
    title.frame = CGRect(x: M.buttonLeft + M.glyph + M.glyphGap - 2, y: (button.frame.height - th) / 2, width: textWidth + 4, height: th)
    motion.isHidden = false
    if shownKey != state.key {
      shownKey = state.key
      appear()
    }
  }

  private func appear() {
    let M = SelectionBarMetrics.self
    guard let layer = motion.layer, let barFrame else { return }
    let now = CACurrentMediaTime()
    appearedAt = now
    let tween = RNTween(from: 0, to: 1, start: now, duration: M.appear.duration, easing: M.appear.easing)
    let origin = CGPoint(x: barFrame.midX, y: above ? barFrame.maxY : barFrame.minY)
    let shift = above ? M.fromShift : -M.fromShift
    let transform = { (p: Double) in PrimitiveMotion.scale(about: origin, scale: M.fromScale + (1 - M.fromScale) * p, translateY: shift * (1 - p)) }
    PrimitiveMotion.setInstantly {
      layer.opacity = 1
      layer.sublayerTransform = CATransform3DIdentity
    }
    guard window != nil else { return }
    let values = tween.samples()
    layer.add(PrimitiveMotion.keyframes("opacity", values, duration: tween.duration, start: now) { NSNumber(value: $0) }, forKey: "selectionOpacity")
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", values, duration: tween.duration, start: now) { NSValue(caTransform3D: transform($0)) }, forKey: "selectionTransform")
  }
}
