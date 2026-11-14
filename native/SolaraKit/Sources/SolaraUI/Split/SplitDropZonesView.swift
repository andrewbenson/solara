import AppKit

@MainActor
final class SplitDropZonesView: NSView {
  static let slideDuration: CFTimeInterval = 0.11
  static let glowDuration: CFTimeInterval = 0.12
  static let spring = SpringParams(stiffness: 987, damping: 56.5)

  var theme = SplitChromeTheme.fallback { didSet { if theme != oldValue { zones.values.forEach { $0.theme = theme } } } }
  private var zones: [String: SplitZoneView] = [:]
  private var frameSpec: SplitDragFrame?
  private var link: CADisplayLink?

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var animating: Bool { zones.values.contains { !$0.settled(at: CACurrentMediaTime()) } }

  func apply(_ spec: SplitDragFrame?) {
    guard spec != frameSpec else { return }
    frameSpec = spec
    let now = CACurrentMediaTime()
    let shown = spec?.shown ?? false
    if shown, let spec {
      let live = Set(spec.panes.flatMap { [$0.tabId + "|left", $0.tabId + "|right"] })
      for key in zones.keys where !live.contains(key) {
        zones[key]?.removeFromSuperview()
        zones[key] = nil
      }
      for pane in spec.panes {
        for side in [SplitSide.left, .right] {
          let key = pane.tabId + "|" + side.rawValue
          let stage: SplitZoneStage = spec.target == SplitDropTarget(tabId: pane.tabId, side: side) ? .active : spec.grown ? .grown : .rest
          let zone = zones[key] ?? makeZone(key, side: side)
          zone.aim(pane: pane.rect, stage: stage, pointerX: spec.px, shown: true, at: now)
        }
      }
    } else {
      for zone in zones.values { zone.aim(pane: nil, stage: nil, pointerX: 0, shown: false, at: now) }
    }
    tick()
    run()
  }

  private func makeZone(_ key: String, side: SplitSide) -> SplitZoneView {
    let zone = SplitZoneView(side: side)
    zone.theme = theme
    zones[key] = zone
    addSubview(zone)
    return zone
  }

  private func run() {
    guard link == nil, animating else { return }
    let made = displayLink(target: self, selector: #selector(step(_:)))
    #if SOLARA_PROBES
    NativeWorkCounters.link(made)
    #endif
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func step(_ link: CADisplayLink) { tick() }

  private func tick() {
    let now = CACurrentMediaTime()
    for (key, zone) in zones {
      zone.render(at: now)
      if zone.gone(at: now) {
        zone.removeFromSuperview()
        zones[key] = nil
      }
    }
    if !animating {
      #if SOLARA_PROBES
      NativeWorkCounters.unlink(link)
      #endif
      link?.invalidate()
      link = nil
    }
  }

  func sample() -> [[String: Any]] {
    zones.map { key, zone in
      ["key": key, "x": zone.frame.minX, "y": zone.frame.minY, "width": zone.frame.width, "height": zone.frame.height, "glow": zone.glowValue, "slide": zone.slideValue]
    }
  }
}

@MainActor
final class SplitZoneView: NSView {
  let side: SplitSide
  var theme = SplitChromeTheme.fallback { didSet { paint() } }
  private var pane: CGRect = .zero
  private var x = SpringTrack.resting(0)
  private var y = SpringTrack.resting(0)
  private var w = SpringTrack.resting(0)
  private var h = SpringTrack.resting(0)
  private var glow = RNTween.resting(0)
  private var slide = RNTween.resting(0)
  private var active = false
  private var shown = false
  private var placed = false
  private let surface = CALayer()
  private let dashes = CAShapeLayer()
  private let glyph = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private(set) var glowValue: Double = 0
  private(set) var slideValue: Double = 0

  override var isFlipped: Bool { true }

  init(side: SplitSide) {
    self.side = side
    super.init(frame: .zero)
    wantsLayer = true
    let off: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "transform": NSNull()]
    surface.actions = off
    surface.cornerRadius = 20
    surface.cornerCurve = .continuous
    surface.borderWidth = 0.5
    dashes.actions = off
    dashes.fillColor = nil
    layer?.addSublayer(surface)
    layer?.addSublayer(dashes)
    glyph.imageScaling = .scaleProportionallyDown
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.stringValue = side == .left ? "Add left split" : "Add right split"
    label.alignment = .center
    let symbol = side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled"
    glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
    addSubview(glyph)
    addSubview(label)
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  func aim(pane next: CGRect?, stage: SplitZoneStage?, pointerX: CGFloat, shown nextShown: Bool, at now: CFTimeInterval) {
    if let next, let stage {
      pane = next
      let r = SplitDrop.zoneRect(next, side, stage, pointerX: pointerX)
      if !placed {
        x = .resting(r.minX)
        y = .resting(r.minY)
        w = .resting(r.width)
        h = .resting(r.height)
        placed = true
      } else {
        x = retarget(x, r.minX, now)
        y = retarget(y, r.minY, now)
        w = retarget(w, r.width, now)
        h = retarget(h, r.height, now)
      }
      let nowActive = stage == .active
      if nowActive != active {
        active = nowActive
        paint()
        glow = RNTween(from: glow.value(at: now), to: nowActive ? 1 : 0, start: now, duration: SplitDropZonesView.glowDuration, easing: .outQuad)
      }
    }
    if nextShown != shown {
      shown = nextShown
      slide = RNTween(from: slide.value(at: now), to: nextShown ? 1 : 0, start: now, duration: SplitDropZonesView.slideDuration, easing: nextShown ? .outCubic : .inQuad)
    }
  }

  private func retarget(_ track: SpringTrack, _ to: CGFloat, _ now: CFTimeInterval) -> SpringTrack {
    guard abs(track.to - Double(to)) > 0.001 else { return track }
    return SpringTrack(SplitDropZonesView.spring, from: track.value(at: now), to: Double(to), velocity: track.velocity(at: now), start: now)
  }

  func settled(at now: CFTimeInterval) -> Bool {
    [x, y, w, h].allSatisfy { now - $0.start >= $0.duration } && glow.finished(at: now) && slide.finished(at: now)
  }

  func gone(at now: CFTimeInterval) -> Bool { !shown && slide.finished(at: now) }

  func render(at now: CFTimeInterval) {
    let rect = CGRect(x: x.value(at: now), y: y.value(at: now), width: max(0, w.value(at: now)), height: max(0, h.value(at: now)))
    slideValue = slide.value(at: now)
    glowValue = glow.value(at: now)
    let away = side == .left ? -(rect.minX - pane.minX + rect.width) : pane.maxX - rect.minX
    let shift = away * (1 - slideValue)
    frame = rect.offsetBy(dx: shift, dy: 0)
    paintGlow()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    let inner = bounds.insetBy(dx: 9.5, dy: 9.5)
    dashes.frame = bounds
    dashes.path = inner.width > 0 && inner.height > 0 ? CGPath(roundedRect: inner, cornerWidth: 11, cornerHeight: 11, transform: nil) : nil
    CATransaction.commit()
    label.sizeToFit()
    let glyphSize = CGSize(width: 24, height: 20)
    let column = glyphSize.height + 11 + label.frame.height
    let top = (bounds.height - column) / 2
    glyph.frame = CGRect(x: (bounds.width - glyphSize.width) / 2, y: top, width: glyphSize.width, height: glyphSize.height)
    label.frame = CGRect(x: 0, y: top + glyphSize.height + 11, width: bounds.width, height: label.frame.height)
  }

  private func paintGlow() {
    let dark = theme.dark
    let restFill = dark ? NSColor(srgbRed: 1, green: 236 / 255, blue: 214 / 255, alpha: 0.04) : NSColor(white: 1, alpha: 0.45)
    let glowFill = theme.accent.withAlphaComponent(dark ? 0.16 : 0.12)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.backgroundColor = SplitColor.mix(restFill, glowFill, glowValue).cgColor
    CATransaction.commit()
  }

  private func paint() {
    let dark = theme.dark
    let rest = dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.55)
    let tint = active ? theme.accent : rest
    paintGlow()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.borderColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor
    let width: CGFloat = active ? 2.33 : 2
    dashes.lineWidth = width
    dashes.lineDashPattern = [NSNumber(value: Double(width * 3)), NSNumber(value: Double(width * 3))]
    dashes.strokeColor = (active ? theme.accent : dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
    CATransaction.commit()
    glyph.contentTintColor = tint
    label.textColor = tint
  }
}

enum SplitColor {
  static func mix(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return t < 0.5 ? a : b }
    let f = CGFloat(min(1, max(0, t)))
    return NSColor(
      srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f, green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
      blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f, alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
  }
}
