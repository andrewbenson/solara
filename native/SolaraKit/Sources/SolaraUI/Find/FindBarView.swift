import AppKit

public struct FindBarState: Decodable, Equatable, Sendable {
  public var query: String
  public var count: Int?
  public var active: Int
  public var replace: Bool
  public var note: String?
  public var noteError: Bool
  public var focusRequest: Int
  public var previousTooltip: String
  public var nextTooltip: String
  public var dark: Bool
  public var theme: [String: String]

  public static func decode(_ json: String) -> FindBarState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(FindBarState.self, from: data)
  }
}

public enum FindBarEvent: Sendable, Equatable {
  case query(String)
  case step(backwards: Bool)
  case close
  case replacement(String)
  case replace(all: Bool)
  case focused
}

final class FindField: NSTextField {
  var onCommand: (Selector) -> Bool = { _ in false }
  var onChange: (String) -> Void = { _ in }

  override init(frame: NSRect) {
    super.init(frame: frame)
    contentType = .solaraPlainText
  }

  required init?(coder: NSCoder) { fatalError() }
}

@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
  public var onEvent: (FindBarEvent) -> Void = { _ in }
  public private(set) var state: FindBarState?

  private let icon = NSImageView()
  private let field = FindField()
  private let activeLabel = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")
  private let countRule = CALayer()
  private let noneLabel = NSTextField(labelWithString: "No results")
  private var up: ToolbarButtonView!
  private var down: ToolbarButtonView!
  private var done: ToolbarButtonView!
  private let rule = CALayer()
  private let rowRule = CALayer()
  private let swapIcon = NSImageView()
  private let replaceField = FindField()
  private let noteLabel = NSTextField(labelWithString: "")
  private var replaceOne: FindTextButton!
  private var replaceAll: FindTextButton!
  private var handledFocus = 0
  private var focusGeneration = 0
  private var scheduledFocus: Int?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    let palette = FindBarView.palette(NewTabTheme.fallbackLight)
    up = ToolbarButtonView(state: FindBarView.button("previous", "chevron.up", 12), palette: palette)
    down = ToolbarButtonView(state: FindBarView.button("next", "chevron.down", 12), palette: palette)
    done = ToolbarButtonView(state: FindBarView.button("done", "xmark", 11, tooltip: "Done (Esc)"), palette: palette)
    for button in [up!, down!, done!] { button.supportsAccessibilityPress = true }
    replaceOne = FindTextButton(title: "Replace")
    replaceAll = FindTextButton(title: "All")
    for v: NSView in [icon, field, activeLabel, countLabel, noneLabel, up, down, done, swapIcon, replaceField, noteLabel, replaceOne, replaceAll] { addSubview(v) }
    for l in [countRule, rule, rowRule] { layer?.addSublayer(l) }
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    swapIcon.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    icon.imageScaling = .scaleNone
    swapIcon.imageScaling = .scaleNone
    for f in [field, replaceField] {
      f.isBezeled = false
      f.isBordered = false
      f.drawsBackground = false
      f.focusRingType = .none
      f.usesSingleLineMode = true
      f.cell?.wraps = false
      f.cell?.isScrollable = true
      f.font = .systemFont(ofSize: 14)
      f.delegate = self
    }
    field.setAccessibilityLabel("Find on Page")
    replaceField.setAccessibilityLabel("Replace")
    for l in [activeLabel, countLabel, noneLabel, noteLabel] {
      l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      l.isSelectable = false
    }
    up.onClick = { [weak self] _ in self?.onEvent(.step(backwards: true)) }
    down.onClick = { [weak self] _ in self?.onEvent(.step(backwards: false)) }
    done.onClick = { [weak self] _ in self?.onEvent(.close) }
    replaceOne.onPress = { [weak self] in self?.onEvent(.replace(all: false)) }
    replaceAll.onPress = { [weak self] in self?.onEvent(.replace(all: true)) }
  }

  required init?(coder: NSCoder) { fatalError() }

  static func button(_ id: String, _ icon: String, _ size: Double, tooltip: String? = nil, enabled: Bool = true) -> ToolbarButtonState {
    ToolbarButtonState(
      id: id, icon: icon, size: size, box: 26, radius: 6, weight: nil, color: nil, enabled: enabled, active: false, tooltip: tooltip, menu: false,
      longPress: false, middle: false, plain: false)
  }

  static func palette(_ t: NewTabTheme) -> ToolbarPaletteState {
    ToolbarPaletteState(
      background: nil, text: hex(t.textPrimary), secondary: hex(t.textSecondary), icon: hex(t.icon), iconDisabled: hex(t.iconDisabled),
      hover: hex(t.toolbarHover), pressed: hex(t.toolbarPressed), pill: hex(t.rowHover), divider: hex(t.rowHover))
  }

  static func hex(_ c: CSSColor) -> String {
    let v = [c.red, c.green, c.blue, c.alpha].map { String(format: "%02X", Int(($0 * 255).rounded())) }
    return "#" + v.joined()
  }

  static let labelPad: CGFloat = 2
  static let textRise: CGFloat = 0.5

  public var height: CGFloat { state?.replace == true ? 40 + 1 + 38 : 40 }

  public func update(_ next: FindBarState) {
    if state?.focusRequest != next.focusRequest {
      focusGeneration += 1
      scheduledFocus = nil
    }
    state = next
    let theme = NewTabTheme(dark: next.dark, tokens: next.theme)
    let palette = FindBarView.palette(theme)
    up.palette = palette
    down.palette = palette
    done.palette = palette
    let hasCount = (next.count ?? 0) > 0
    up.state = FindBarView.button("previous", "chevron.up", 12, tooltip: next.previousTooltip, enabled: hasCount)
    down.state = FindBarView.button("next", "chevron.down", 12, tooltip: next.nextTooltip, enabled: hasCount)
    icon.contentTintColor = theme.textSecondary.ns
    swapIcon.contentTintColor = theme.textSecondary.ns
    let separator = next.dark ? CSSColor(red: 1, green: 1, blue: 1, alpha: 0.12) : CSSColor(red: 0, green: 0, blue: 0, alpha: 0.1)
    let error = next.dark ? CSSColor("#FF6B63")! : CSSColor("#C93333")!
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for l in [countRule, rule, rowRule] { l.backgroundColor = separator.cg }
    CATransaction.commit()
    for f in [field, replaceField] {
      f.textColor = theme.textPrimary.ns
      (f.currentEditor() as? NSTextView)?.insertionPointColor = theme.textPrimary.ns
    }
    field.placeholderAttributedString = NSAttributedString(string: "Find on Page", attributes: [.foregroundColor: theme.placeholder.ns, .font: NSFont.systemFont(ofSize: 14)])
    replaceField.placeholderAttributedString = NSAttributedString(string: "Replace", attributes: [.foregroundColor: theme.placeholder.ns, .font: NSFont.systemFont(ofSize: 14)])
    if field.currentEditor() == nil, field.stringValue != next.query { field.stringValue = next.query }
    let none = next.count == 0 && !next.query.isEmpty
    noneLabel.isHidden = !none
    noneLabel.textColor = error.ns
    let showsCount = !none && next.count != nil && !next.query.isEmpty
    for v in [activeLabel, countLabel] { v.isHidden = !showsCount }
    countRule.isHidden = !showsCount
    activeLabel.stringValue = "\(next.active)"
    activeLabel.textColor = theme.textPrimary.ns
    countLabel.stringValue = "\(next.count ?? 0)"
    countLabel.textColor = theme.textSecondary.ns
    for v: NSView in [swapIcon, replaceField, replaceOne, replaceAll] { v.isHidden = !next.replace }
    rowRule.isHidden = !next.replace
    noteLabel.isHidden = !next.replace || next.note == nil
    noteLabel.stringValue = next.note ?? ""
    noteLabel.textColor = next.noteError ? error.ns : theme.textSecondary.ns
    for b in [replaceOne!, replaceAll!] {
      b.theme = theme
      b.enabled = !next.query.isEmpty
    }
    needsLayout = true
    scheduleFocusIfNeeded()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      focusGeneration += 1
      scheduledFocus = nil
    } else {
      scheduleFocusIfNeeded()
    }
  }

  private func scheduleFocusIfNeeded() {
    guard let request = state?.focusRequest, request != 0, request != handledFocus,
          scheduledFocus == nil, window != nil, !isHiddenOrHasHiddenAncestor else { return }
    let generation = focusGeneration
    scheduledFocus = generation
    DispatchQueue.main.async { [weak self] in
      guard let self, self.focusGeneration == generation else { return }
      self.scheduledFocus = nil
      guard self.state?.focusRequest == request, !self.isHiddenOrHasHiddenAncestor, let window = self.window,
            window.makeFirstResponder(self.field), let editor = self.field.currentEditor(), window.firstResponder === editor else { return }
      self.handledFocus = request
      editor.selectedRange = NSRange(location: 0, length: (self.field.stringValue as NSString).length)
      self.onEvent(.focused)
    }
  }

  public func focusField() {
    window?.makeFirstResponder(field)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? (bounds.contains(convert(point, from: superview)) ? self : nil) : hit
  }

  public override func layout() {
    super.layout()
    let w = bounds.width
    let row: CGFloat = 40
    icon.frame = CGRect(x: 11, y: (row - 16) / 2, width: 16, height: 16)
    var right = w - 4
    done.frame = CGRect(x: right - 26, y: (row - 26) / 2, width: 26, height: 26)
    right -= 26
    right -= 2 + 3 + 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rule.frame = CGRect(x: right, y: (row - 18) / 2, width: 1, height: 18)
    CATransaction.commit()
    right -= 3 + 2
    down.frame = CGRect(x: right - 26, y: (row - 26) / 2, width: 26, height: 26)
    right -= 26 + 2
    up.frame = CGRect(x: right - 26, y: (row - 26) / 2, width: 26, height: 26)
    right -= 26 + 2
    if !noneLabel.isHidden {
      right -= 6
      right = place(noneLabel, right: right, midY: row / 2 - FindBarView.textRise) - 2
    } else if !countLabel.isHidden {
      right -= 6
      right = place(countLabel, right: right, midY: row / 2) - 6
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      countRule.frame = CGRect(x: right - 1, y: (row - 12) / 2, width: 1, height: 12)
      CATransaction.commit()
      right -= 1 + 6
      right = place(activeLabel, right: right, midY: row / 2) - 2
    }
    let fieldLeft: CGFloat = 11 + 16 + 5 + 2
    let fh = field.intrinsicContentSize.height
    field.frame = CGRect(x: fieldLeft, y: (row - fh) / 2, width: max(0, right - fieldLeft), height: fh)
    guard state?.replace == true else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rowRule.frame = CGRect(x: 0, y: row, width: w, height: 1)
    CATransaction.commit()
    let top = row + 1
    let r2: CGFloat = 38
    swapIcon.frame = CGRect(x: 11, y: top + (r2 - 16) / 2, width: 16, height: 16)
    var x2 = w - 6
    for b in [replaceAll!, replaceOne!] {
      let bw = b.intrinsicWidth
      b.frame = CGRect(x: x2 - bw, y: top + (r2 - 26) / 2, width: bw, height: 26)
      x2 -= bw + 4
    }
    if !noteLabel.isHidden {
      x2 = place(noteLabel, right: x2 - 2, midY: top + r2 / 2 - FindBarView.textRise) - 4
    }
    let rh = replaceField.intrinsicContentSize.height
    let rLeft: CGFloat = 11 + 16 + 3 + 4
    replaceField.frame = CGRect(x: rLeft, y: top + (r2 - rh) / 2, width: max(0, x2 - rLeft), height: rh)
  }

  private func place(_ label: NSTextField, right: CGFloat, midY: CGFloat) -> CGFloat {
    let width = ceil(label.attributedStringValue.size().width)
    let height = label.intrinsicContentSize.height
    let pad = FindBarView.labelPad
    label.frame = CGRect(x: right - width - pad, y: midY - height / 2, width: width + 2 * pad, height: height)
    return right - width
  }

  public func controlTextDidChange(_ obj: Notification) {
    guard let f = obj.object as? NSTextField else { return }
    if f === field { onEvent(.query(f.stringValue)) } else { onEvent(.replacement(f.stringValue)) }
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if textView.hasMarkedText() { return false }
    let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      onEvent(.close)
      return true
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
      if control === replaceField {
        onEvent(.replace(all: false))
        return true
      }
      if flags.contains(.command) || flags.contains(.control) { return false }
      onEvent(.step(backwards: flags.contains(.shift)))
      return true
    default:
      return false
    }
  }
}

final class FindTextButton: NSView {
  let title: String
  var theme = NewTabTheme.fallbackLight { didSet { apply() } }
  var enabled = true { didSet { apply() } }
  var onPress: () -> Void = {}
  private let label = NSTextField(labelWithString: "")
  private var hovered = false
  private var pressed = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  init(title: String) {
    self.title = title
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.stringValue = title
    label.isSelectable = false
    addSubview(label)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
    apply()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var textWidth: CGFloat {
    let scale = window?.backingScaleFactor ?? 2
    return ceil(label.attributedStringValue.size().width * scale) / scale
  }

  var intrinsicWidth: CGFloat { textWidth + 16 }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; apply() }
  override func mouseExited(with event: NSEvent) { hovered = false; apply() }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    pressed = true
    apply()
  }

  override func mouseUp(with event: NSEvent) {
    let was = pressed
    pressed = false
    apply()
    if was, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
  }

  override func layout() {
    super.layout()
    let s = label.intrinsicContentSize
    label.frame = CGRect(x: 8 - FindBarView.labelPad, y: (bounds.height - s.height) / 2 - FindBarView.textRise, width: textWidth + 2 * FindBarView.labelPad, height: s.height)
  }

  override func accessibilityPerformPress() -> Bool {
    guard enabled, !isHiddenOrHasHiddenAncestor else { return false }
    onPress()
    return true
  }

  func apply() {
    setAccessibilityEnabled(enabled)
    layer?.backgroundColor = !enabled ? nil : pressed ? theme.toolbarPressed.cg : hovered ? theme.toolbarHover.cg : nil
    label.textColor = enabled ? theme.textPrimary.ns : theme.iconDisabled.ns
  }
}
