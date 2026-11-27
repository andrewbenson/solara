import AppKit
import SolaraModel

public struct DownloadRowState: Equatable, Sendable, Identifiable {
  public var id: String
  public var filename: String
  public var path: String
  public var state: String
  public var received: Double
  public var total: Double
  public var speed: Double
  public var paused: Bool
  public var url: String?
  public var dangerous: Bool?

  public init(_ download: Download) {
    id = download.id
    filename = download.filename
    path = download.path
    state = download.state ?? ""
    received = download.json["received"]?.number ?? 0
    total = download.json["total"]?.number ?? 0
    speed = download.json["speed"]?.number ?? 0
    paused = download.paused
    url = download.url
    dangerous = download.dangerous
  }

  init(id: String, filename: String, path: String, state: String, received: Double, total: Double, speed: Double,
    paused: Bool, url: String? = nil, dangerous: Bool? = nil)
  {
    self.id = id
    self.filename = filename
    self.path = path
    self.state = state
    self.received = received
    self.total = total
    self.speed = speed
    self.paused = paused
    self.url = url
    self.dangerous = dangerous
  }
}

public struct DownloadsListState: Equatable, Sendable {
  public var rows: [DownloadRowState]
  public var clearable: Bool
  public var listMax: Double
  public var dark: Bool
  public var theme: [String: String]

  public init(rows: [DownloadRowState], clearable: Bool, listMax: Double, dark: Bool, theme: [String: String]) {
    self.rows = rows
    self.clearable = clearable
    self.listMax = listMax
    self.dark = dark
    self.theme = theme
  }
}

public enum DownloadsEvent: Sendable, Equatable {
  case open(String)
  case reveal(String)
  case pause(String)
  case resume(String)
  case keep(String)
  case cancel(String)
  case menu(String)
  case remove(String)
  case source(String)
  case clear
  case viewAll
}

public enum DownloadsFormat {
  public static func bytes(_ value: Double) -> String {
    if value < 0 { return "" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var n = value
    var i = 0
    while n >= 1000 && i < units.count - 1 {
      n /= 1000
      i += 1
    }
    let shown = n < 10 && i > 0 ? String(format: "%.1f", n) : "\(Int(n.rounded()))"
    return "\(shown) \(units[i])"
  }

  public static func duration(_ seconds: Double) -> String {
    if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) sec left" }
    if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min left" }
    return "\(Int((seconds / 3600).rounded())) hr left"
  }

  public static func awaitsKeep(_ d: DownloadRowState) -> Bool { d.state == "downloading" && d.dangerous == true }

  public static func dangerWarning(_ d: DownloadRowState, short: Bool = false) -> String {
    if (d.url ?? "").hasPrefix("http:") { return short ? "Blocked: not secure" : "Insecure download blocked" }
    return short ? "Blocked: unsafe file type" : "This type of file can harm your computer"
  }

  public static func status(_ d: DownloadRowState, exists: Bool) -> String {
    switch d.state {
    case "finished": return exists ? bytes(d.total > 0 ? d.total : d.received) : "Deleted"
    case "failed": return "Failed to Download"
    case "cancelled": return "Cancelled"
    default:
      if awaitsKeep(d) { return dangerWarning(d) }
      let progress = d.total > 0 ? "\(bytes(d.received)) of \(bytes(d.total))" : bytes(d.received)
      if d.paused { return "\(progress) — Paused" }
      if d.speed > 0 && d.total > 0 { return "\(progress), \(bytes(d.speed))/s — \(duration((d.total - d.received) / d.speed))" }
      return progress
    }
  }
}

enum DownloadsMetrics {
  static let inset: CGFloat = 16
  static let rowInset: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let rowRadius: CGFloat = 6
  static let rowHeight: CGFloat = 32
  static let header: CGFloat = 24
  static let row: CGFloat = 40
  static let fileIcon: CGFloat = 24
  static let rowButton: CGFloat = 22
  static let iconGap: CGFloat = 10
  static let separatorGap: CGFloat = 5
  static let padTop: CGFloat = 17 - 7.5
  static let padBottom: CGFloat = 17 - 12
  static let textButtonPad: CGFloat = 7
  static let clearNudge: CGFloat = 2.5

  static func danger(_ dark: Bool) -> NSColor {
    dark ? NSColor(srgbRed: 1, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1) : NSColor(srgbRed: 1, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1)
  }
}

class HoverFillView: NSView {
  var hovered = false
  var pressed = false
  var onPress: (() -> Void)?
  var onMenu: (() -> Void)?
  var onHover: (Bool) -> Void = { _ in }
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    let inside = DevPointer.inside(self, note)
    guard inside != hovered else { return }
    hovered = inside
    onHover(inside)
    refresh()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; onHover(true); refresh() }
  override func mouseExited(with event: NSEvent) { hovered = false; onHover(false); refresh() }

  override func mouseDown(with event: NSEvent) {
    pressed = true
    refresh()
  }

  override func mouseUp(with event: NSEvent) {
    let was = pressed
    pressed = false
    refresh()
    if was, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }

  override func rightMouseDown(with event: NSEvent) {
    if let onMenu { onMenu() } else { super.rightMouseDown(with: event) }
  }

  func refresh() {}
}

func rowFill(dark: Bool, hovered: Bool, pressed: Bool) -> CGColor? {
  if !hovered && !pressed { return nil }
  return dark ? NSColor(white: 1, alpha: pressed ? 0.12 : 0.07).cgColor : NSColor(white: 0, alpha: pressed ? 0.1 : 0.06).cgColor
}

@MainActor
public enum DownloadsDrags {
  public internal(set) static var lastPaths: [String] = []
}


class DownloadsPressableView: HoverFillView {
  override var acceptsFirstResponder: Bool { onPress != nil && !isHiddenOrHasHiddenAncestor }
  override var canBecomeKeyView: Bool { acceptsFirstResponder }
  override var focusRingMaskBounds: NSRect { bounds }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit is PostcardControl || hit is DownloadsTextButton ? hit : self
  }
  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; noteFocusRingMaskChanged(); return acceptsFirstResponder }
  override func resignFirstResponder() -> Bool { pressed = false; refresh(); needsDisplay = true; noteFocusRingMaskChanged(); return true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    if event.keyCode == 53 { nextResponder?.keyDown(with: event); return }
    guard acceptsFirstResponder, [36, 49, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
    if !event.isARepeat { onPress?() }
  }
  override func accessibilityPerformPress() -> Bool {
    guard acceptsFirstResponder, let onPress else { return false }
    onPress()
    return true
  }
}

final class DownloadRowView: DownloadsPressableView, NSDraggingSource {
  var row: DownloadRowState
  var theme: NewTabTheme
  var dark: Bool
  var onEvent: (DownloadsEvent) -> Void = { _ in }
  private let icon = NSImageView()
  private let name = NSTextField(labelWithString: "")
  private let status = NSTextField(labelWithString: "")
  private let track = CALayer()
  private let fill = CALayer()
  private var buttons: [PostcardControl] = []
  private var textButtons: [DownloadsTextButton] = []
  private var dragStart: NSPoint?

  init(row: DownloadRowState, theme: NewTabTheme, dark: Bool) {
    self.row = row
    self.theme = theme
    self.dark = dark
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = DownloadsMetrics.rowRadius
    icon.imageScaling = .scaleProportionallyUpOrDown
    for v: NSView in [icon, name, status] { addSubview(v) }
    for l in [track, fill] {
      l.cornerRadius = 1.5
      layer?.addSublayer(l)
    }
    name.lineBreakMode = .byTruncatingTail
    status.lineBreakMode = .byTruncatingTail
    name.isSelectable = false
    status.isSelectable = false
    onPress = { [weak self] in
      guard let self, self.done else { return }
      self.onEvent(.open(self.row.id))
    }
    onMenu = { [weak self] in
      guard let self else { return }
      self.onEvent(.menu(self.row.id))
    }
    onHover = { [weak self] _ in self?.syncButtons() }
    setAccessibilityRole(.button)
    update(row, theme: theme, dark: dark)
  }

  required init?(coder: NSCoder) { fatalError() }

  var exists: Bool { row.state != "finished" || FileManager.default.fileExists(atPath: row.path) }
  var done: Bool { row.state == "finished" && exists }

  func update(_ next: DownloadRowState, theme nextTheme: NewTabTheme, dark nextDark: Bool) {
    row = next
    theme = nextTheme
    dark = nextDark
    let present = exists
    setAccessibilityLabel(next.filename.isEmpty ? "Preparing…" : next.filename)
    icon.image = NSWorkspace.shared.icon(forFile: next.path.isEmpty ? next.filename : next.path)
    if next.path.isEmpty || !FileManager.default.fileExists(atPath: next.path) {
      icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: (next.filename as NSString).pathExtension) ?? .data)
    }
    icon.alphaValue = present ? 1 : 0.45
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 16
    paragraph.maximumLineHeight = 16
    paragraph.lineBreakMode = .byTruncatingTail
    var attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13), .foregroundColor: present ? nextTheme.textPrimary.ns : nextTheme.textSecondary.ns, .paragraphStyle: paragraph,
    ]
    if !present { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    name.attributedStringValue = NSAttributedString(string: next.filename.isEmpty ? "Preparing…" : next.filename, attributes: attributes)
    let statusParagraph = NSMutableParagraphStyle()
    statusParagraph.minimumLineHeight = 14
    statusParagraph.maximumLineHeight = 14
    statusParagraph.lineBreakMode = .byTruncatingTail
    let blocked = DownloadsFormat.awaitsKeep(next)
    status.attributedStringValue = NSAttributedString(
      string: blocked ? DownloadsFormat.dangerWarning(next, short: true) : DownloadsFormat.status(next, exists: present),
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: blocked ? DownloadsMetrics.danger(nextDark) : nextTheme.textSecondary.ns, .paragraphStyle: statusParagraph])
    let downloading = next.state == "downloading" && !blocked
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.isHidden = !downloading
    fill.isHidden = !downloading
    track.backgroundColor = (nextDark ? CSSColor("#717782")! : CSSColor("#CED7E7")!).cg
    fill.backgroundColor = next.paused ? nextTheme.textTertiary.cg : nextTheme.accent.cg
    CATransaction.commit()
    syncButtons()
    refresh()
    needsLayout = true
  }

  private func syncTextButtons() {
    let titles: [(String, DownloadsEvent)] = DownloadsFormat.awaitsKeep(row) ? [("Keep", .keep(row.id)), ("Discard", .cancel(row.id))] : []
    if textButtons.map(\.label.stringValue) != titles.map(\.0) {
      textButtons.forEach { $0.removeFromSuperview() }
      textButtons = titles.map { title, event in
        let b = DownloadsTextButton(title: title)
        b.onPress = { [weak self] in self?.onEvent(event) }
        addSubview(b)
        return b
      }
      needsLayout = true
    }
    textButtons.forEach { $0.theme = theme }
  }

  private func syncButtons() {
    syncTextButtons()
    var specs: [(String, String, DownloadsEvent)] = []
    if row.state == "downloading" && !DownloadsFormat.awaitsKeep(row) {
      specs = [
        (row.paused ? "play.circle.fill" : "pause.circle.fill", row.paused ? "Resume" : "Pause", row.paused ? .resume(row.id) : .pause(row.id)),
        ("xmark.circle.fill", "Cancel", .cancel(row.id)),
      ]
    } else if done && hovered {
      specs = [("magnifyingglass.circle.fill", "Show in Finder", .reveal(row.id))]
    }
    if buttons.count != specs.count || zip(buttons, specs).contains(where: { $0.glyph != $1.0 }) {
      buttons.forEach { $0.removeFromSuperview() }
      buttons = specs.map { spec in
        let b = PostcardControl(frame: .zero)
        b.glyph = spec.0
        b.glyphSize = 13
        b.glyphWeight = .regular
        b.radius = 6
        b.toolTip = spec.1
        b.setAccessibilityLabel(spec.1)
        b.onHover = { [weak self] _ in self?.refreshButtons() }
        b.onPressed = { [weak self] _ in self?.refreshButtons() }
        let event = spec.2
        b.onPress = { [weak self] in self?.onEvent(event) }
        addSubview(b)
        return b
      }
      needsLayout = true
    }
    refreshButtons()
  }

  private func refreshButtons() {
    for button in buttons {
      button.glyphColor = theme.icon.ns
      button.fill = button.pressed ? theme.toolbarPressed.ns : button.hovered ? theme.toolbarHover.ns : nil
      button.needsDisplay = true
    }
  }

  override func refresh() {
    layer?.backgroundColor = rowFill(dark: dark, hovered: hovered, pressed: pressed && done)
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = convert(event.locationInWindow, from: nil)
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard done, let start = dragStart else { return }
    let at = convert(event.locationInWindow, from: nil)
    guard hypot(at.x - start.x, at.y - start.y) > 3 else { return }
    dragStart = nil
    pressed = false
    refresh()
    DownloadsDrags.lastPaths = [row.path]
    let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: row.path) as NSURL)
    item.setDraggingFrame(icon.frame, contents: icon.image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .generic] : .copy
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    let x = DownloadsMetrics.rowPadding
    icon.frame = CGRect(x: x, y: (h - DownloadsMetrics.fileIcon) / 2, width: DownloadsMetrics.fileIcon, height: DownloadsMetrics.fileIcon)
    let bearing = (DownloadsMetrics.rowButton - 13) / 2
    var right = bounds.width - DownloadsMetrics.rowPadding + (textButtons.isEmpty ? bearing : DownloadsMetrics.textButtonPad)
    for b in buttons.reversed() {
      right -= DownloadsMetrics.rowButton
      b.frame = CGRect(x: right, y: (h - DownloadsMetrics.rowButton) / 2, width: DownloadsMetrics.rowButton, height: DownloadsMetrics.rowButton)
    }
    for b in textButtons.reversed() {
      right -= b.paddedWidth
      b.frame = CGRect(x: right, y: (h - 22) / 2, width: b.paddedWidth, height: 22)
    }
    let textRight = (buttons.isEmpty && textButtons.isEmpty ? bounds.width - DownloadsMetrics.rowPadding : right - DownloadsMetrics.iconGap + 0)
    let textLeft = x + DownloadsMetrics.fileIcon + DownloadsMetrics.iconGap
    let width = max(0, textRight - textLeft)
    let downloading = row.state == "downloading" && !DownloadsFormat.awaitsKeep(row)
    let column: CGFloat = 16 + (downloading ? 3 + 3 + 2 : 0) + 14
    var y = (h - column) / 2
    name.frame = CGRect(x: textLeft - 2, y: y, width: width + 4, height: 16)
    y += 16
    if downloading {
      y += 3
      let progress = row.total > 0 ? row.received / row.total : 0
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      track.frame = CGRect(x: textLeft, y: y, width: width, height: 3)
      fill.frame = CGRect(x: textLeft, y: y, width: width * CGFloat(max(progress, 0.03)), height: 3)
      CATransaction.commit()
      y += 3 + 2
    }
    status.frame = CGRect(x: textLeft - 2, y: y + 0.5, width: width + 4, height: 14)
  }
}

final class DownloadsTextButton: DownloadsPressableView {
  let label = NSTextField(labelWithString: "")
  var theme = NewTabTheme.fallbackLight { didSet { label.textColor = theme.textSecondary.ns; refresh() } }

  init(title: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    label.stringValue = title
    label.font = .systemFont(ofSize: 12)
    label.isSelectable = false
    addSubview(label)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  var width: CGFloat { ceil(label.intrinsicContentSize.width) - 4 + 2 * DownloadsMetrics.textButtonPad }
  var paddedWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 2 * DownloadsMetrics.textButtonPad }

  override func refresh() { layer?.backgroundColor = hovered ? theme.toolbarHover.cg : nil }

  override func layout() {
    super.layout()
    let s = label.intrinsicContentSize
    label.frame = CGRect(x: DownloadsMetrics.textButtonPad - 2, y: (bounds.height - s.height) / 2, width: s.width + 4, height: s.height)
  }
}

final class DownloadsFooterButton: DownloadsPressableView {
  let label = NSTextField(labelWithString: "View all downloads")
  let chevron = NSImageView()
  var theme = NewTabTheme.fallbackLight { didSet { refresh() } }
  var dark = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = DownloadsMetrics.rowRadius
    label.font = .systemFont(ofSize: 13)
    label.isSelectable = false
    chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    chevron.imageScaling = .scaleNone
    addSubview(label)
    addSubview(chevron)
    setAccessibilityRole(.button)
    setAccessibilityLabel("View all downloads")
  }

  required init?(coder: NSCoder) { fatalError() }

  override func refresh() {
    layer?.backgroundColor = rowFill(dark: dark, hovered: hovered, pressed: pressed)
    label.textColor = hovered ? theme.textPrimary.ns : theme.textSecondary.ns
    chevron.contentTintColor = theme.textTertiary.ns
  }

  override func layout() {
    super.layout()
    let s = label.intrinsicContentSize
    label.frame = CGRect(x: DownloadsMetrics.rowPadding - 2, y: (bounds.height - s.height) / 2 - 0.5, width: s.width + 4, height: s.height)
    chevron.frame = CGRect(x: bounds.width - DownloadsMetrics.rowPadding - 12 + 3, y: (bounds.height - 12) / 2, width: 12, height: 12)
  }
}

@MainActor
public final class DownloadsListView: NSView {
  public var onEvent: (DownloadsEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  private var state: DownloadsListState?
  private let title = NSTextField(labelWithString: "")
  private let clear = DownloadsTextButton(title: "Clear")
  private let empty = NSTextField(labelWithString: "No downloads yet")
  private let scroll = NSScrollView()
  private let list = FlippedView()
  private var rows: [DownloadRowView] = []
  private let separator = CALayer()
  private let footer = DownloadsFooterButton()
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    title.isSelectable = false
    empty.isSelectable = false
    empty.font = .systemFont(ofSize: 13)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = list
    for v: NSView in [title, clear, empty, scroll, footer] { addSubview(v) }
    layer?.addSublayer(separator)
    clear.onPress = { [weak self] in self?.onEvent(.clear) }
    footer.onPress = { [weak self] in self?.onEvent(.viewAll) }
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: DownloadsListState) {
    guard state != next else { return }
    let previous = state
    state = next
    let theme = NewTabTheme(dark: next.dark, tokens: next.theme)
    title.attributedStringValue = NSAttributedString(
      string: "RECENT DOWNLOADS", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .kern: 0.4, .foregroundColor: theme.textSecondary.ns])
    clear.theme = theme
    clear.isHidden = !next.clearable
    empty.textColor = theme.textSecondary.ns
    empty.isHidden = !next.rows.isEmpty
    scroll.isHidden = next.rows.isEmpty
    footer.dark = next.dark
    footer.theme = theme
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    separator.backgroundColor = (next.dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).cgColor
    CATransaction.commit()
    var remaining = Dictionary(rows.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })
    var kept: [DownloadRowView] = []
    for r in next.rows {
      if let existing = remaining.removeValue(forKey: r.id) {
        if existing.row != r || previous?.theme != next.theme || previous?.dark != next.dark {
          existing.update(r, theme: theme, dark: next.dark)
        }
        kept.append(existing)
      } else {
        let made = DownloadRowView(row: r, theme: theme, dark: next.dark)
        made.onEvent = { [weak self] e in self?.onEvent(e) }
        list.addSubview(made)
        kept.append(made)
      }
    }
    for view in remaining.values { view.removeFromSuperview() }
    rows = kept
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public override func layout() {
    super.layout()
    guard let state else { return }
    let w = bounds.width
    let scale = window?.backingScaleFactor ?? 2
    var y = DownloadsMetrics.padTop
    let ts = title.intrinsicContentSize
    let cw = clear.width
    clear.frame = CGRect(x: w - (DownloadsMetrics.inset - DownloadsMetrics.textButtonPad) - cw - DownloadsMetrics.clearNudge, y: y + 0.5, width: cw, height: 22)
    title.frame = CGRect(x: DownloadsMetrics.inset - 2, y: y + (DownloadsMetrics.header - ts.height) / 2, width: max(ts.width, clear.frame.minX - DownloadsMetrics.inset + 2), height: ts.height)
    y += DownloadsMetrics.header
    if state.rows.isEmpty {
      let es = empty.intrinsicContentSize
      empty.frame = CGRect(x: DownloadsMetrics.inset - 2, y: y + (DownloadsMetrics.rowHeight - es.height) / 2, width: w, height: es.height)
      y += DownloadsMetrics.rowHeight
    } else {
      let content = CGFloat(state.rows.count) * DownloadsMetrics.row
      let height = min(content, max(DownloadsMetrics.row, CGFloat(state.listMax)))
      scroll.frame = CGRect(x: 0, y: y, width: w, height: height)
      list.frame = CGRect(x: 0, y: 0, width: w, height: content)
      for (i, r) in rows.enumerated() {
        r.frame = CGRect(x: DownloadsMetrics.rowInset, y: CGFloat(i) * DownloadsMetrics.row, width: w - 2 * DownloadsMetrics.rowInset, height: DownloadsMetrics.row)
      }
      y += height
    }
    y += DownloadsMetrics.separatorGap
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    separator.frame = CGRect(x: DownloadsMetrics.inset, y: y, width: w - 2 * DownloadsMetrics.inset, height: 1 / scale)
    CATransaction.commit()
    y += 1 / scale + DownloadsMetrics.separatorGap
    footer.frame = CGRect(x: DownloadsMetrics.rowInset, y: y, width: w - 2 * DownloadsMetrics.rowInset, height: DownloadsMetrics.rowHeight)
    y += DownloadsMetrics.rowHeight + DownloadsMetrics.padBottom
    if bounds.width > 0, y != reported {
      reported = y
      onHeight(y)
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
