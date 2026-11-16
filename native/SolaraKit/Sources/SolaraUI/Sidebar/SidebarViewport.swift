import AppKit

final class SidebarScrollEdgeView: NSVisualEffectView {
  private let fade = CAGradientLayer()
  private let tint = CALayer()

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    material = .sidebar
    blendingMode = .withinWindow
    state = .followsWindowActiveState
    isHidden = true
    fade.actions = SurfaceLayer.noActions
    fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
    fade.startPoint = CGPoint(x: 0.5, y: 0)
    fade.endPoint = CGPoint(x: 0.5, y: 1)
    layer?.mask = fade
    tint.actions = SurfaceLayer.noActions
    layer?.addSublayer(tint)
  }

  required init?(coder: NSCoder) { fatalError() }

  func update(_ palette: SidebarPalette) {
    appearance = NSAppearance(named: palette.dark ? .darkAqua : .aqua)
    tint.backgroundColor = palette.backdropTint?.ns.withAlphaComponent(palette.dark ? 0.18 : 0.27).cgColor
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    fade.frame = bounds
    tint.frame = bounds
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
struct SidebarRetirementPicture {
  let view: NSImageView
  let item: SidebarItem
}

final class SidebarLogicalElement: NSAccessibilityElement {
  private let readLabel: @MainActor @Sendable () -> String?
  private let readFrame: @MainActor @Sendable () -> CGRect
  private let perform: @MainActor @Sendable (String) -> Bool

  @MainActor
  init(owner: SidebarView, key: String) {
    readLabel = { [weak owner] in owner?.logicalLabel(key) }
    readFrame = { [weak owner] in owner?.logicalAccessibilityFrame(key) ?? .zero }
    perform = { [weak owner] action in owner?.performLogicalAction(key, action: action) ?? false }
    super.init()
    setAccessibilityParent(owner)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  override func accessibilityLabel() -> String? { MainActor.assumeIsolated(readLabel) }
  override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated(readFrame) }
  override func accessibilityPerformPress() -> Bool {
    let action = perform
    return MainActor.assumeIsolated { action("press") }
  }
  override func accessibilityPerformShowMenu() -> Bool {
    let action = perform
    return MainActor.assumeIsolated { action("menu") }
  }
  override func setAccessibilityFocused(_ focused: Bool) {
    let action = perform
    MainActor.assumeIsolated { if focused { _ = action("focus") } }
  }
}
