import AppKit

public enum SadTabMode: String, Decodable, Sendable {
  case crashed, unresponsive
}

public struct SadTabState: Decodable, Equatable, Sendable {
  public var mode: SadTabMode?
  public var dark: Bool
  public var textPrimary: String
  public var textSecondary: String
  public var panel: String
  public var panelBorder: String
  public var panelShadowOpacity: Double
  public var goButton: String
  public var goButtonText: String

  public static func decode(_ json: String) -> SadTabState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SadTabState.self, from: data)
  }
}

public enum SadTabAction: String, Sendable {
  case reload, exit, wait
}

public enum SadTabMetrics {
  public static let crashedPadding: CGFloat = 24
  public static let iconBox = CGSize(width: 44, height: 40)
  public static let iconSize: CGFloat = 30
  public static let iconGap: CGFloat = 14
  public static let titleGap: CGFloat = 6
  public static let bodyWidth: CGFloat = 340
  public static let bodyGap: CGFloat = 18
  public static let cardWidth: CGFloat = 320
  public static let cardPadding: CGFloat = 18
  public static let cardGap: CGFloat = 6
  public static let cardRadius: CGFloat = 14
  public static let cardBodyGap: CGFloat = 10
  public static let buttonHeight: CGFloat = 28
  public static let buttonPadding: CGFloat = 12
  public static let buttonGap: CGFloat = 8
}

@MainActor
public final class SadTabView: NSView {
  public var onAction: (SadTabAction) -> Void = { _ in }
  public private(set) var state: SadTabState?
  private var content: NSView?
  private var built: SadTabState?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public var showing: SadTabMode? { state?.mode }

  public func update(_ next: SadTabState) {
    state = next
    isHidden = next.mode == nil
    guard next != built else { return }
    built = next
    rebuild()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, state?.mode != nil else { return nil }
    return super.hitTest(point) ?? self
  }

  public override func mouseDown(with event: NSEvent) {}

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }

  private func rebuild() {
    content?.removeFromSuperview()
    content = nil
    guard let state, let mode = state.mode, bounds.width > 0 else {
      layer?.backgroundColor = nil
      return
    }
    let view = mode == .crashed ? crashed(state) : unresponsive(state)
    addSubview(view)
    content = view
  }

  private func color(_ css: String, _ fallback: NSColor = .labelColor) -> NSColor { CSSColor(css)?.ns ?? fallback }

  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, centred: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color.withAlphaComponent(1)
    field.alphaValue = color.alphaComponent
    field.alignment = centred ? .center : .natural
    field.isSelectable = false
    field.drawsBackground = false
    field.isBordered = false
    return field
  }

  private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

  private func place(_ view: NSView, left: CGFloat, y: CGFloat) {
    let l = snap(left)
    view.frame = CGRect(x: l, y: y, width: snap(left + view.frame.width) - l, height: view.frame.height)
  }

  private func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
  }

  private func button(_ title: String, primary: Bool, _ state: SadTabState, _ action: SadTabAction) -> PromptPressable {
    let text = label(title, size: 13, weight: .medium, color: primary ? color(state.goButtonText, .white) : color(state.textPrimary))
    text.maximumNumberOfLines = 1
    let textWidth = text.intrinsicContentSize.width
    let b = PromptPressable(frame: CGRect(x: 0, y: 0, width: textWidth + SadTabMetrics.buttonPadding * 2, height: SadTabMetrics.buttonHeight))
    b.acceptsFirstClick = true
    b.wantsLayer = true
    b.layer?.cornerRadius = 8
    let dark = state.dark
    let go = CSSColor(state.goButton)?.cg
    b.fill = { hovered, pressed in
      if primary {
        if dark { return pressed ? CSSColor("#C9B8C5")!.cg : hovered ? CSSColor("#E6D8E2")!.cg : go }
        return pressed ? CSSColor("#26314A")!.cg : hovered ? CSSColor("#1B2640")!.cg : go
      }
      let a: CGFloat = pressed ? (dark ? 0.18 : 0.12) : hovered ? (dark ? 0.14 : 0.09) : (dark ? 0.1 : 0.06)
      return NSColor(white: dark ? 1 : 0, alpha: a).cgColor
    }
    b.refresh()
    let h = text.intrinsicContentSize.height
    text.frame = CGRect(x: SadTabMetrics.buttonPadding - 2, y: (SadTabMetrics.buttonHeight - h) / 2 - 0.5, width: textWidth + 4, height: h)
    b.addSubview(text)
    b.onPress = { [weak self] in self?.onAction(action) }
    b.setAccessibilityRole(.button)
    b.setAccessibilityLabel(title)
    return b
  }

  private func crashed(_ state: SadTabState) -> NSView {
    let M = SadTabMetrics.self
    let box = FlippedContainerView(frame: bounds)
    box.wantsLayer = true
    box.layer?.backgroundColor = color(state.dark ? "#1C1A1B" : "#F6F5F6").cgColor
    let inner = max(0, bounds.width - M.crashedPadding * 2)
    let icon = NSImageView(frame: CGRect(origin: .zero, size: M.iconBox))
    icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: M.iconSize, weight: .light))
    icon.contentTintColor = color(state.textSecondary)
    icon.imageScaling = .scaleNone
    let title = label("This tab needs to reload", size: 17, weight: .semibold, color: color(state.textPrimary), centred: true)
    let titleWidth = min(inner, ceil(title.intrinsicContentSize.width) + 4)
    let titleHeight = height(title, width: titleWidth)
    let body = label("Something went wrong with this tab. Reloading often fixes it.", size: 13, color: color(state.textSecondary), centred: true)
    let bodyWidth = min(inner, M.bodyWidth)
    let bodyHeight = height(body, width: bodyWidth)
    let reload = button("Reload", primary: true, state, .reload)
    let total = M.iconBox.height + M.iconGap + titleHeight + M.titleGap + bodyHeight + M.bodyGap + M.buttonHeight
    var y = snap((bounds.height - total) / 2)
    let mid = bounds.width / 2
    icon.frame.origin = CGPoint(x: snap(mid - M.iconBox.width / 2), y: y)
    y += M.iconBox.height + M.iconGap
    title.frame = CGRect(x: snap(mid - titleWidth / 2), y: y, width: titleWidth, height: titleHeight)
    y += titleHeight + M.titleGap
    body.frame = CGRect(x: snap(mid - bodyWidth / 2), y: y, width: bodyWidth, height: bodyHeight)
    y += bodyHeight + M.bodyGap
    place(reload, left: mid - reload.frame.width / 2, y: y)
    for view in [icon, title, body, reload] as [NSView] { box.addSubview(view) }
    return box
  }

  private func unresponsive(_ state: SadTabState) -> NSView {
    let M = SadTabMetrics.self
    let box = NSView(frame: bounds)
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor(white: 0, alpha: state.dark ? 0.35 : 0.12).cgColor
    let inner = M.cardWidth - M.cardPadding * 2
    let title = label("Page Unresponsive", size: 14, weight: .semibold, color: color(state.textPrimary))
    let titleHeight = height(title, width: inner)
    let body = label("You can wait for it to become responsive or exit the page.", size: 12, color: color(state.textSecondary))
    let bodyHeight = height(body, width: inner)
    let exit = button("Exit Page", primary: false, state, .exit)
    let wait = button("Wait", primary: true, state, .wait)
    let cardHeight = M.cardPadding * 2 + titleHeight + M.cardGap + bodyHeight + M.cardBodyGap + M.cardGap + M.buttonHeight
    let card = NSView(frame: CGRect(x: snap((bounds.width - M.cardWidth) / 2), y: snap((bounds.height - cardHeight) / 2), width: M.cardWidth, height: cardHeight))
    card.wantsLayer = true
    if let layer = card.layer {
      layer.backgroundColor = color(state.panel).cgColor
      layer.cornerRadius = M.cardRadius
      layer.borderColor = color(state.panelBorder).cgColor
      layer.borderWidth = 0.5
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = Float(state.panelShadowOpacity)
      layer.shadowRadius = 20
      layer.shadowOffset = CGSize(width: 0, height: -8)
      layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: card.frame.size), cornerWidth: M.cardRadius, cornerHeight: M.cardRadius, transform: nil)
    }
    let flipped = PrimitiveFlippedView(frame: CGRect(origin: .zero, size: card.frame.size))
    card.addSubview(flipped)
    var y = M.cardPadding
    title.frame = CGRect(x: M.cardPadding - 2, y: y, width: inner + 4, height: titleHeight)
    y += titleHeight + M.cardGap
    body.frame = CGRect(x: M.cardPadding - 2, y: y, width: inner + 4, height: bodyHeight)
    y += bodyHeight + M.cardBodyGap + M.cardGap
    let waitLeft = M.cardWidth - M.cardPadding - wait.frame.width
    place(exit, left: waitLeft - M.buttonGap - exit.frame.width, y: y)
    place(wait, left: waitLeft, y: y)
    for view in [title, body, exit, wait] as [NSView] { flipped.addSubview(view) }
    box.addSubview(card)
    return box
  }

  public var controlFrames: [String: CGRect] {
    var out: [String: CGRect] = [:]
    func walk(_ view: NSView) {
      if let b = view as? PromptPressable, let name = b.accessibilityLabel() { out[name] = b.convert(b.bounds, to: self) }
      view.subviews.forEach(walk)
    }
    if let content { walk(content) }
    return out
  }
}
