import AppKit
import QuartzCore

public struct ShareBarState: Decodable, Equatable, Sendable {
  public var capturer: String
  public var tabId: String
  public var shared: Bool
  public var canStop: Bool?
  public var sourceLabel: String?
  public var receiptID: String?
  public var host: String
  public var theme: MediaThemeState

  public init(capturer: String, tabId: String, shared: Bool, host: String, theme: MediaThemeState, canStop: Bool? = nil, sourceLabel: String? = nil, receiptID: String? = nil) {
    self.capturer = capturer
    self.tabId = tabId
    self.shared = shared
    self.canStop = canStop
    self.sourceLabel = sourceLabel
    self.receiptID = receiptID
    self.host = host
    self.theme = theme
  }

  public static func decode(_ json: String) -> ShareBarState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ShareBarState.self, from: data)
  }
}

public enum ShareBarAction: String, Sendable {
  case stop
  case shareInstead
  case dismiss
}

final class PromptButtonView: NSView {
  private let label = NSTextField(labelWithString: "")
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }
  var primary = false { didSet { paint() } }
  var theme = MediaThemeState(dark: true) { didSet { if theme != oldValue { paint() } } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  init(title: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.actions = SurfaceLayer.noActions
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = false
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    self.title = title
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  var title: String {
    get { label.stringValue }
    set {
      guard label.stringValue != newValue else { return }
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
      needsLayout = true
    }
  }

  override var fittingSize: NSSize { NSSize(width: label.intrinsicContentSize.width + 24, height: 28) }

  override func layout() {
    super.layout()
    let h = label.intrinsicContentSize.height
    label.frame = CGRect(x: 12 - 2, y: (bounds.height - h) / 2 - 0.5, width: max(0, bounds.width - 20), height: h)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovered = false; pressed = false }
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseDragged(with event: NSEvent) {
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    let was = pressed
    pressed = false
    if was && inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  private func paint() {
    let dark = theme.dark
    let fill: NSColor
    if primary {
      let go = MediaPalette.parse(theme.colors["goButton"]) ?? (dark ? MediaPalette.parse("#DCCBD8")! : MediaPalette.parse("#0F182C")!)
      if dark { fill = pressed ? MediaPalette.parse("#C9B8C5")! : hovered ? MediaPalette.parse("#E6D8E2")! : go }
      else { fill = pressed ? MediaPalette.parse("#26314A")! : hovered ? MediaPalette.parse("#1B2640")! : go }
      label.textColor = MediaPalette.parse(theme.colors["goButtonText"]) ?? (dark ? MediaPalette.parse("#1A1418")! : .white)
    } else {
      let a: CGFloat = pressed ? (dark ? 0.18 : 0.12) : hovered ? (dark ? 0.14 : 0.09) : (dark ? 0.1 : 0.06)
      fill = NSColor(white: dark ? 1 : 0, alpha: a)
      label.textColor = MediaPalette(theme).textPrimary
    }
    MediaMotion.setInstantly { layer?.backgroundColor = fill.cgColor }
  }
}

public final class ShareBarView: NSView {
  public static let height: CGFloat = 38

  public var onAction: ((ShareBarAction) -> Void)?

  private let badge = CALayer()
  private let glyph = SymbolView()
  private let label = NSTextField(labelWithString: "")
  private let primaryButton = PromptButtonView(title: "Stop Sharing")
  private let dismissButton = PromptButtonView(title: "Dismiss")
  private let line = CALayer()
  private var state: ShareBarState?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    for l in [badge, line] {
      l.actions = SurfaceLayer.noActions
      layer?.addSublayer(l)
    }
    badge.cornerRadius = 10
    badge.backgroundColor = MediaTokens.captureRed.cgColor
    addSubview(glyph)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isSelectable = false
    addSubview(label)
    primaryButton.onPress = { [weak self] in
      guard let self, let state = self.state else { return }
      self.onAction?((state.canStop ?? state.shared) ? .stop : .shareInstead)
    }
    dismissButton.onPress = { [weak self] in self?.onAction?(.dismiss) }
    addSubview(primaryButton)
    addSubview(dismissButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: ShareBarState) {
    state = next
    let palette = MediaPalette(next.theme)
    glyph.set("rectangle.inset.filled", size: 9, weight: .bold, color: .white)
    let text = NSMutableAttributedString(string: "Sharing ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: palette.textSecondary])
    text.append(NSAttributedString(string: next.sourceLabel ?? (next.shared ? "this tab" : "another tab"), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: palette.textPrimary]))
    text.append(NSAttributedString(string: " with \(next.host)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: palette.textSecondary]))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    label.attributedStringValue = text
    let canStop = next.canStop ?? next.shared
    primaryButton.title = canStop ? "Stop Sharing" : "Share This Tab Instead"
    primaryButton.primary = !canStop
    for b in [primaryButton, dismissButton] { b.theme = next.theme }
    MediaMotion.setInstantly {
      line.backgroundColor = (next.theme.dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08)).cgColor
    }
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    let h = Self.height
    MediaMotion.setInstantly {
      badge.frame = CGRect(x: 12, y: (h - 20) / 2, width: 20, height: 20)
      line.frame = CGRect(x: 0, y: h - 0.5, width: bounds.width, height: 0.5)
    }
    glyph.frame = CGRect(x: 15, y: (h - 14) / 2, width: 14, height: 14)
    let dismiss = dismissButton.fittingSize
    let primary = primaryButton.fittingSize
    dismissButton.frame = CGRect(x: bounds.width - 8 - dismiss.width, y: (h - 28) / 2, width: dismiss.width, height: 28)
    primaryButton.frame = CGRect(x: dismissButton.frame.minX - 10 - primary.width, y: (h - 28) / 2, width: primary.width, height: 28)
    let textX: CGFloat = 12 + 20 + 10
    let lh = ceil(label.intrinsicContentSize.height)
    label.frame = CGRect(x: textX, y: ((h - lh) / 2).rounded(), width: max(0, primaryButton.frame.minX - 10 - textX), height: lh)
  }

  public var controlFrames: [String: CGRect] { ["primary": primaryButton.frame, "dismiss": dismissButton.frame, "text": label.frame] }
  public var primaryTitle: String { primaryButton.title }

#if SOLARA_PROBES
  public var controlLabels: [String: String] { ["primary": primaryButton.title, "dismiss": dismissButton.title] }
#endif
}
