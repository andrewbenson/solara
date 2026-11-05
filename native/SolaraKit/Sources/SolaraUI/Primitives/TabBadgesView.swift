import AppKit

public enum TabCapture: String, Decodable, Equatable, Sendable {
  case screen
  case camera
}

public final class TabBadgesView: NSView {
  private let pip = CornerBadge()
  private let capture = CornerBadge()
  private var shown: (pip: Bool, capture: TabCapture?, size: CGFloat, badge: NSColor, glyph: NSColor)?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    pip.isHidden = true
    capture.isHidden = true
    addSubview(pip)
    addSubview(capture)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public var isEmpty: Bool { shown.map { !$0.pip && $0.capture == nil } ?? true }

  static func pipSpec(iconSize size: CGFloat, badge: NSColor, glyph: NSColor) -> CornerBadgeSpec {
    .circle(.glyph(symbol: "pip.fill", scale: 0.55, color: glyph), fill: badge, corner: .topTrailing, diameter: (size * 0.72).rounded(), overhang: 1.0 / 3)
  }

  static func captureSpec(_ kind: TabCapture, iconSize size: CGFloat) -> CornerBadgeSpec {
    switch kind {
    case .screen:
      .circle(.glyph(symbol: "rectangle.inset.filled", scale: 0.5, color: .white), fill: MediaTokens.captureRed, corner: .bottomTrailing, diameter: (size * 0.72).rounded(), overhang: 1.0 / 3)
    case .camera:
      .circle(.dot(ring: NSColor(white: 0, alpha: 0.25)), fill: MediaTokens.captureRed, corner: .bottomTrailing, diameter: max(6, (size * 0.44).rounded()), overhang: 1.0 / 4)
    }
  }

  public func set(pip showsPip: Bool, capture kind: TabCapture?, iconSize size: CGFloat, badge: NSColor, badgeGlyph: NSColor) {
    shown = (showsPip, kind, size, badge, badgeGlyph)
    pip.isHidden = !showsPip
    if showsPip { pip.show(Self.pipSpec(iconSize: size, badge: badge, glyph: badgeGlyph), in: bounds.size) }
    capture.isHidden = kind == nil
    if let kind { capture.show(Self.captureSpec(kind, iconSize: size), in: bounds.size) }
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if let shown { set(pip: shown.pip, capture: shown.capture, iconSize: shown.size, badge: shown.badge, badgeGlyph: shown.glyph) }
  }
}

extension TabBadgesView {
  @MainActor
  static func attach(_ view: inout TabBadgesView?, to parent: NSView, flags: SidebarFlags, tabId: String?, host: SidebarHostState, palette: SidebarPalette) {
    let pip = tabId.map { flags.pip.contains($0) } ?? false
    let capture = tabId.flatMap { flags.capture[$0] }
    guard pip || capture != nil else {
      view?.isHidden = true
      return
    }
    let badges = view ?? {
      let made = TabBadgesView()
      parent.addSubview(made)
      parent.needsLayout = true
      return made
    }()
    view = badges
    badges.isHidden = false
    let fill = host.badge?.first.flatMap { CSSColor($0)?.ns } ?? palette.textSecondary
    let glyph = host.badge.flatMap { $0.count > 1 ? CSSColor($0[1])?.ns : nil } ?? .white
    badges.set(pip: pip, capture: capture, iconSize: 16, badge: fill, badgeGlyph: glyph)
  }
}
