import AppKit
import QuartzCore

public struct SidebarTabCardState: Decodable, Equatable, Sendable {
  public struct Button: Decodable, Equatable, Sendable {
    public var action: String
    public var icon: String
    public var label: String

    public init(action: String, icon: String, label: String) {
      self.action = action
      self.icon = icon
      self.label = label
    }

    public static let sleepHeavy = Button(action: "sleepHeavy", icon: "moon.zzz", label: "Put to Sleep")
  }

  @MainActor
  public func offeringSleep(heavy: HeavyTabReason?, canSleep: Bool) -> SidebarTabCardState {
    guard heavy != nil, canSleep, !sleeping, !buttons.contains(.sleepHeavy) else { return self }
    var out = self
    out.buttons.append(.sleepHeavy)
    return out
  }

  public struct Look: Decodable, Equatable, Sendable {
    public var fill: String
    public var border: String
    public var primary: String
    public var secondary: String
    public var tertiary: String
    public var hover: String
    public var pressed: String
    public var shadowOpacity: Double
  }

  public var tabId: String
  public var title: String
  public var host: String?
  public var sleeping: Bool
  public var buttons: [Button]
  public var anchor: [Double]
  public var sidebarWidth: Double
  public var windowHeight: Double
  public var look: Look

  public var anchorRect: CGRect {
    anchor.count == 4 ? CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]) : .zero
  }

  public static func decode(_ value: Any?) -> SidebarTabCardState? {
    guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

public enum SidebarTabCardMetrics {
  public static let width: CGFloat = 200
  static let maxPitch: CGFloat = 49
  static let inset: CGFloat = 14
  static let fieldPadding: CGFloat = 1.5
  static let border: CGFloat = 0.5
  static var titleWidth: CGFloat { width - 2 * (inset + border) }
  static let top: CGFloat = 16.5
  static let bottom: CGFloat = 6
  static let line: CGFloat = 16
  static let actionsGap: CGFloat = 10
  static let button: CGFloat = 28
  static let radius: CGFloat = 11

  public static func origin(anchor: CGRect, sidebarWidth: CGFloat, cardHeight: CGFloat, windowHeight: CGFloat) -> CGPoint {
    let left = anchor.maxX <= sidebarWidth + 1 ? sidebarWidth + 0.5 : anchor.maxX + 8
    let centred = anchor.midY - cardHeight / 2
    return CGPoint(x: left, y: pixel(max(8, min(centred, windowHeight - cardHeight - 8))))
  }

  static func pixel(_ value: CGFloat, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> CGFloat {
    (value * scale).rounded(.toNearestOrAwayFromZero) / scale
  }

  static func pitch(_ count: Int) -> CGFloat { min(maxPitch, (width - 4) / CGFloat(max(1, count))) }
}

public final class SidebarTabCardView: NSView {
  public var onAction: ((String) -> Void)?
  public var onPointer: ((Bool) -> Void)?
  public private(set) var state: SidebarTabCardState?
  private let surface = SurfaceLayer()
  private let title = OnboardingTextNSView()
  private let host = OnboardingTextNSView()
  private let note = NSTextField(labelWithString: "This tab needs to reload")
  private let memory = NSTextField(labelWithString: "")
  private var memoryRow = SidebarTabMemoryRow.absent
  private var buttons: [SidebarIconButton] = []
  private var titleLines = 1
  private var tracking: NSTrackingArea?
  private var inside = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    surface.radius = SidebarTabCardMetrics.radius
    surface.border = SidebarTabCardMetrics.border
    surface.glowColor = .black
    surface.glowRadius = 16
    surface.glowOffset = CGSize(width: 0, height: 6)
    layer?.addSublayer(surface)
    title.container.maximumNumberOfLines = 2
    title.container.lineBreakMode = .byTruncatingTail
    title.manager.usesFontLeading = false
    host.container.maximumNumberOfLines = 1
    host.container.lineBreakMode = .byTruncatingTail
    host.manager.usesFontLeading = false
    note.lineBreakMode = .byTruncatingTail
    note.font = .systemFont(ofSize: 11.5)
    note.setAccessibilityLabel("Web content has been discarded")
    memory.lineBreakMode = .byTruncatingTail
    memory.maximumNumberOfLines = 1
    memory.isHidden = true
    addSubview(title)
    addSubview(host)
    addSubview(memory)
    addSubview(note)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarTabCardState) {
    if next.tabId != state?.tabId { memoryRow = .absent }
    state = next
    let look = next.look
    func color(_ text: String) -> NSColor { CSSColor(text)?.ns ?? .clear }
    let secondary = color(look.secondary)
    surface.fill = color(look.fill)
    surface.borderTint = color(look.border)
    surface.glowOpacity = look.shadowOpacity * 0.8
    title.storage.setAttributedString(Self.text(next.title, size: 13, weight: .semibold, color: color(look.primary)))
    title.needsDisplay = true
    host.isHidden = next.host == nil
    host.storage.setAttributedString(Self.text(next.host ?? "", size: 13, weight: .regular, color: secondary))
    host.needsDisplay = true
    note.isHidden = !next.sleeping
    note.textColor = color(look.tertiary)
    styleMemory()
    while buttons.count < next.buttons.count {
      let button = SidebarIconButton()
      button.radius = 7
      button.setAccessibilityElement(true)
      button.setAccessibilityRole(.button)
      addSubview(button)
      buttons.append(button)
    }
    while buttons.count > next.buttons.count { buttons.removeLast().removeFromSuperview() }
    for (button, spec) in zip(buttons, next.buttons) {
      button.set(spec.icon, size: 14, weight: .regular, color: secondary, tooltip: spec.label)
      button.setAccessibilityLabel(spec.label)
      button.hoverFill = color(look.hover)
      button.pressedFill = color(look.pressed)
      let action = spec.action
      button.onPress = { [weak self] in self?.onAction?(action) }
    }
    titleLines = title.lineCount(width: SidebarTabCardMetrics.titleWidth)
    setFrameSize(NSSize(width: SidebarTabCardMetrics.width, height: height))
    needsLayout = true
  }

  public var height: CGFloat {
    guard let state else { return 0 }
    let m = SidebarTabCardMetrics.self
    var h = m.border + m.top + CGFloat(titleLines) * m.line
    if state.host != nil { h += m.line }
    if !memory.isHidden { h += 2 + Self.lineHeight(memory.font ?? .systemFont(ofSize: 11.5)) }
    if state.sleeping { h += 2 + Self.lineHeight(note.font ?? .systemFont(ofSize: 11.5)) }
    return h + m.actionsGap + m.button + m.bottom + m.border
  }

  public override func layout() {
    super.layout()
    let m = SidebarTabCardMetrics.self
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let textX = m.inset - m.fieldPadding
    let textWidth = bounds.width - 2 * textX
    var y = m.border + m.top
    title.frame = NSRect(x: m.inset + m.border, y: y, width: m.titleWidth, height: CGFloat(titleLines) * m.line)
    y += title.frame.height
    if !host.isHidden {
      host.frame = NSRect(x: m.inset + m.border, y: y, width: m.titleWidth, height: m.line)
      y += m.line
    }
    if !memory.isHidden {
      let line = Self.lineHeight(memory.font ?? .systemFont(ofSize: 11.5))
      memory.frame = NSRect(x: textX, y: y + 2, width: textWidth, height: line)
      y += 2 + line
    }
    if !note.isHidden {
      let line = Self.lineHeight(note.font ?? .systemFont(ofSize: 11.5))
      note.frame = NSRect(x: textX, y: y + 2, width: textWidth, height: line)
      y += 2 + line
    }
    y += m.actionsGap
    let pitch = m.pitch(buttons.count)
    var x = (bounds.width - pitch * CGFloat(buttons.count)) / 2
    for button in buttons {
      button.frame = NSRect(x: x + (pitch - m.button) / 2, y: y, width: m.button, height: m.button)
      x += pitch
    }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(true) }
  public override func mouseExited(with event: NSEvent) { pointer(false) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { pointer(false) }
  }

  @objc private func devPointer(_ note: Notification) { pointer(DevPointer.inside(self, note)) }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === title || hit === host || hit === memory || hit === note ? self : hit
  }

  public override func mouseDown(with event: NSEvent) {}

  public func setMemory(_ row: SidebarTabMemoryRow) {
    memoryRow = row
    styleMemory()
    if state != nil { setFrameSize(NSSize(width: SidebarTabCardMetrics.width, height: height)) }
    needsLayout = true
  }

  public var memoryShown: String? { memory.isHidden ? nil : memory.stringValue }

  private func styleMemory() {
    memory.isHidden = memoryRow == .absent || state?.sleeping != false
    guard !memory.isHidden, let look = state?.look else { return }
    let bytes: Double?
    if case .bytes(let value) = memoryRow { bytes = value } else { bytes = nil }
    let high = bytes.map { SidebarTabMemory.isHigh($0) } ?? false
    memory.stringValue = SidebarTabMemory.text(bytes)
    memory.font = .systemFont(ofSize: 11.5, weight: high ? .medium : .regular)
    memory.textColor = CSSColor(high ? look.primary : look.tertiary)?.ns ?? .clear
  }

  public var titleShown: String { title.shownText(width: SidebarTabCardMetrics.titleWidth) }

  private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = SidebarTabCardMetrics.line
    paragraph.maximumLineHeight = SidebarTabCardMetrics.line
    let offset = (SidebarTabCardMetrics.line - lineHeight(font)) / 2
    return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: offset])
  }

  private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

}
