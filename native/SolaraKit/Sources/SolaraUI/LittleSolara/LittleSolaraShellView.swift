import AppKit

public enum LittleSolaraMetrics {
  public static let lightsCenter = CGPoint(x: 20, y: SmallBarMetrics.height / 2)

  public static func barFrame(in bounds: CGRect) -> CGRect {
    CGRect(x: 0, y: 0, width: bounds.width, height: SmallBarMetrics.height)
  }

  public static func cardFrame(in bounds: CGRect) -> CGRect {
    let inset = SmallBarMetrics.inset
    return CGRect(x: inset, y: SmallBarMetrics.height, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - SmallBarMetrics.height - inset))
  }
}

@MainActor
public final class LittleSolaraShellView: NSView {
  public enum Slot: String, CaseIterable, Sendable {
    case backdrop
    case bar
    case react
    case overlay
  }

  public let windowId: String
  public let bar = SmallBarView()
  public let overlay = LittleSolaraOverlayView()
  public var onWindowChange: (() -> Void)?
  public var onResize: (() -> Void)?
  private let strip = LittleSolaraDragStrip()
  private var mounted: [Slot: NSView] = [:]

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    strip.addSubview(bar)
    mount(.bar, strip)
    mount(.overlay, overlay)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func view(in slot: Slot) -> NSView? { mounted[slot] }

  public var barFrame: CGRect { LittleSolaraMetrics.barFrame(in: bounds) }
  public var cardFrame: CGRect { LittleSolaraMetrics.cardFrame(in: bounds) }

  @objc public var backgroundColor: NSColor? {
    didSet { layer?.backgroundColor = backgroundColor?.cgColor }
  }

  public func mount(_ slot: Slot, _ view: NSView?) {
    if let current = mounted[slot], current === view { return }
    mounted[slot]?.removeFromSuperview()
    mounted[slot] = view
    guard let view else { return }
    view.autoresizingMask = []
    if slot == .react, view.responds(to: Selector(("setBackgroundColor:"))) {
      if backgroundColor == nil, let fill = view.value(forKey: "backgroundColor") as? NSColor { backgroundColor = fill }
      view.setValue(nil, forKey: "backgroundColor")
    }
    let above = Slot.allCases.drop { $0 != slot }.dropFirst().lazy.compactMap { self.mounted[$0] }.first { $0.superview === self }
    if let above { addSubview(view, positioned: .below, relativeTo: above) } else { addSubview(view) }
    place(slot, view)
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    relayout()
    onResize?()
  }

  public override func layout() {
    super.layout()
    relayout()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard frame.contains(point) else { return nil }
    let local = convert(point, from: superview)
    if let hit = overlay.hitTest(local) { return hit }
    let react = mounted[.react]
    if let react, let hit = react.hitTest(local), !Self.passesThrough(hit, react) { return hit }
    if barFrame.contains(local), let hit = strip.hitTest(local) { return hit }
    return react?.hitTest(local)
  }

  public static let passThroughIdentifier = NSUserInterfaceItemIdentifier("solara.passThrough")

  static func passesThrough(_ hit: NSView, _ react: NSView) -> Bool {
    hit === react || NSStringFromClass(type(of: hit)).hasSuffix("RootContentView") || hit.identifier == passThroughIdentifier
  }

  private func relayout() {
    for (slot, view) in mounted { place(slot, view) }
    if bar.frame != strip.bounds { bar.frame = strip.bounds }
  }

  private func place(_ slot: Slot, _ view: NSView) {
    let frame = slot == .bar ? barFrame : bounds
    if view.frame != frame { view.frame = frame }
    if slot == .bar, bar.frame != view.bounds { bar.frame = view.bounds }
  }
}

public final class LittleSolaraOverlayView: NSView {
  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point), hit !== self else { return nil }
    return hit
  }
}

final class LittleSolaraDragStrip: NSView {
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    var key = NSApp.keyWindow
    while let k = key, k !== window { key = k.parent }
    if key == nil, window.canBecomeKey, !event.modifierFlags.contains(.command) { window.makeKeyAndOrderFront(nil) }
    if event.clickCount == 2 { return }
    window.performDrag(with: event)
  }
}
