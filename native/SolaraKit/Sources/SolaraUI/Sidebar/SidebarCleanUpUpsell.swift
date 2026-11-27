import AppKit
import SolaraModel
import SolaraStore

public enum SidebarCleanupPresentation {
  public static func candidateCount(state: BrowserState, windowId: String, now: Double) -> Int {
    WorkspaceCleanup.candidateCount(state: state, windowId: windowId, now: now)
  }

  public static func admitted(state: BrowserState, dismissed: Bool) -> Bool {
    !dismissed && state.settings["suggestTabCleanUp"]?.bool != false
      && state.settings.number("cleanUpInactiveTabsAfterHours") == nil
  }

  public static func suggestion(state: BrowserState, windowId: String, now: Double, dismissed: Bool) -> Int? {
    guard admitted(state: state, dismissed: dismissed), let window = state.windows[windowId], window.tabIds.count >= 10 else { return nil }
    let count = candidateCount(state: state, windowId: windowId, now: now)
    return count >= 10 ? count : nil
  }
}

public enum SidebarCleanUpChoice: String, Sendable {
  case once
  case daily
  case dismiss
  case dontAskAgain
}

final class CleanUpUpsellView: SidebarRowView {
  static let padding: CGFloat = 10
  static let gap: CGFloat = 8
  static let buttonHeight: CGFloat = 24
  static let buttonGap: CGFloat = 6
  static let quietButtonHeight: CGFloat = 20
  static let titleHeight: CGFloat = 16
  static let bodyFont = NSFont.systemFont(ofSize: 12)

  static func bodyText(product: String) -> String {
    "\(product) can tidy up for you. You can always reopen closed tabs from the ⌄ menu."
  }

  static func bodyHeight(width: CGFloat, product: String) -> CGFloat {
    let text = NSAttributedString(string: bodyText(product: product), attributes: [.font: bodyFont])
    let rect = text.boundingRect(with: NSSize(width: max(1, width - padding * 2), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(rect.height)
  }

  static let quietFont = NSFont.systemFont(ofSize: 10, weight: .medium)
  static let quietTitles = ["Not Now", "Don't Ask Again"]

  static func quietChoicesShareARow(width: CGFloat) -> Bool {
    let titles = quietTitles.reduce(CGFloat(0)) { total, title in
      total + ceil(NSAttributedString(string: title, attributes: [.font: quietFont]).size().width) + 2
    }
    return titles + buttonGap <= width - padding * 2
  }

  static func quietHeight(width: CGFloat) -> CGFloat {
    quietChoicesShareARow(width: width) ? quietButtonHeight : quietButtonHeight * 2 + buttonGap
  }

  static func height(width: CGFloat, product: String) -> CGFloat {
    padding + titleHeight + gap + bodyHeight(width: width, product: product) + gap + buttonHeight * 2 + quietHeight(width: width) + buttonGap * 2 + padding
  }

  private let surface = SurfaceLayer()
  private let symbol = SymbolView()
  private let title = NSTextField(labelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let buttons: [(SidebarCleanUpChoice, UpsellButton)] = [
    (.once, UpsellButton(title: "Clean Up Once", primary: true)),
    (.daily, UpsellButton(title: "Clean Up Daily", primary: false)),
    (.dismiss, UpsellButton(title: CleanUpUpsellView.quietTitles[0], primary: false, quiet: true)),
    (.dontAskAgain, UpsellButton(title: CleanUpUpsellView.quietTitles[1], primary: false, quiet: true)),
  ]
  private var product = "Solara"

  override var pressScales: Bool { false }
  override var accessibleTitle: String? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    surface.radius = 12
    surface.border = 0.5
    body.layer?.addSublayer(surface)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    message.font = Self.bodyFont
    message.isSelectable = false
    for view in [symbol, title, message] as [NSView] { body.addSubview(view) }
    for (choice, button) in buttons {
      button.onPress = { [weak self] in self?.context?.send(.cleanUp(choice)) }
      body.addSubview(button)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context, let count = context.host.upsell else { return }
    let palette = context.palette
    product = context.host.product ?? product
    surface.fill = palette.groupFill
    surface.borderTint = palette.groupStroke
    symbol.set("wand.and.stars", size: 12, color: palette.icon)
    title.stringValue = "\(count) tabs haven’t been touched in a while"
    title.textColor = palette.textPrimary
    message.stringValue = Self.bodyText(product: product)
    message.textColor = palette.textSecondary
    for (_, button) in buttons { button.palette = palette }
    needsLayout = true
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let p = Self.padding
    let width = bounds.width - p * 2
    func frame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
      NSRect(x: x, y: body.bounds.height - y - height, width: width, height: height)
    }
    symbol.frame = frame(x: p, y: p, width: 16, height: 16)
    let titleSize = title.fittingSize
    title.frame = frame(x: p + 16 + 6, y: p + (Self.titleHeight - titleSize.height) / 2, width: max(0, width - 22), height: titleSize.height)
    var y = p + Self.titleHeight + Self.gap
    let messageHeight = Self.bodyHeight(width: bounds.width, product: product)
    message.frame = frame(x: p, y: y, width: width, height: messageHeight)
    y += messageHeight + Self.gap
    for (_, button) in buttons.prefix(2) {
      button.frame = frame(x: p, y: y, width: width, height: Self.buttonHeight)
      y += Self.buttonHeight + Self.buttonGap
    }
    let quietButtons = buttons.suffix(2).map { $0.1 }
    let titles = quietButtons.reduce(CGFloat(0)) { $0 + $1.titleWidth }
    if titles + Self.buttonGap <= width {
      let spare = (width - Self.buttonGap - titles) / 2
      var x = p
      for button in quietButtons {
        let buttonWidth = button.titleWidth + spare
        button.frame = frame(x: x, y: y, width: buttonWidth, height: Self.quietButtonHeight)
        x += buttonWidth + Self.buttonGap
      }
    } else {
      for button in quietButtons {
        button.frame = frame(x: p, y: y, width: width, height: Self.quietButtonHeight)
        y += Self.quietButtonHeight + Self.buttonGap
      }
    }
  }

  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}
  override func contextMenu() {}
}

final class UpsellButton: NSView {
  private let label = NSTextField(labelWithString: "")
  private let primary: Bool
  private let quiet: Bool
  private var pressed = false { didSet { paint() } }
  private var trackingPress = false
  var palette: SidebarPalette? { didSet { paint() } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }
  var titleWidth: CGFloat { label.fittingSize.width }

  init(title: String, primary: Bool, quiet: Bool = false) {
    self.primary = primary
    self.quiet = quiet
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    label.stringValue = title
    label.font = quiet ? CleanUpUpsellView.quietFont : .systemFont(ofSize: 12, weight: .medium)
    label.alignment = .center
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  func clearBinding() {
    trackingPress = false
    pressed = false
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return onPress != nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    let size = label.fittingSize
    label.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
  }

  override func mouseDown(with event: NSEvent) { trackingPress = true; pressed = true }

  override func mouseDragged(with event: NSEvent) {
    guard trackingPress else { return }
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    let valid = pressed && trackingPress
    pressed = false
    trackingPress = false
    if inside && valid { onPress?() }
  }

  private func paint() {
    guard let palette else { return }
    let dark = palette.dark
    let rest = primary ? palette.textPrimary : NSColor(white: dark ? 1 : 0, alpha: 0.08)
    let down = NSColor(white: dark ? 1 : 0, alpha: 0.11)
    layer?.backgroundColor = (pressed ? down : quiet ? .clear : rest).cgColor
    label.textColor = primary ? (dark ? .black : .white) : quiet ? palette.textSecondary : palette.textPrimary
  }
}
