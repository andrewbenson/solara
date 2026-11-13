import AppKit
import QuartzCore
import SolaraOmnibox

public struct SidebarGroupCardState: Decodable, Equatable, Sendable {
  public struct Row: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var usedAt: Double
    public var favicon: String?
    public var icon: String?
    public var profileId: String
  }

  public var groupId: String
  public var rows: [Row]
  public var anchor: [Double]
  public var windowHeight: Double
  public var dark: Bool
  public var theme: [String: String]

  public var anchorRect: CGRect {
    anchor.count == 4 ? CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]) : .zero
  }
}

public enum SidebarGroupCardMetrics {
  public static let width: CGFloat = 264
  static let searchRow: CGFloat = 44
  static let inset: CGFloat = 16
  static let rowInset: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let rowRadius: CGFloat = 6
  static let row: CGFloat = 44
  static let iconSlot: CGFloat = 20
  static let iconGap: CGFloat = 10
  static let separatorGap: CGFloat = 5
  static let border: CGFloat = 0.5
  static let fieldPadding: CGFloat = 2
  static let baselineNudge: CGFloat = 0.5
  static let maxRows = 7
  static let edge: CGFloat = 8
  static var listPad: CGFloat { inset - (row - iconSlot) / 2 }
  static var separator: CGFloat { hairline + separatorGap * 2 }
  static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }

  static func listHeight(_ count: Int) -> CGFloat { listPad * 2 + CGFloat(max(1, min(maxRows, count))) * row }
  public static func height(_ count: Int) -> CGFloat { searchRow + separator + listHeight(count) }

  public static func origin(anchor: CGRect, height: CGFloat, windowHeight: CGFloat) -> CGPoint {
    let top = max(8, anchor.minY - 6)
    return CGPoint(x: anchor.maxX + 8, y: max(edge, min(top, windowHeight - height - edge)))
  }

  static func matching(_ query: String, _ rows: [SidebarGroupCardState.Row]) -> [SidebarGroupCardState.Row] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return rows }
    return rows.enumerated().compactMap { order, row -> (row: SidebarGroupCardState.Row, order: Int, score: Double)? in
      let score = max(fuzzyScore(q, row.title), fuzzyScore(q, hostOf(row.url)) * 0.9, fuzzyScore(q, row.url) * 0.6)
      let contains = row.title.lowercased().contains(q) || row.url.lowercased().contains(q)
      let final = score > 0 ? score : contains ? 1 : 0
      return final > 0 ? (row, order, final) : nil
    }
    .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
    .map(\.row)
  }

  static func ago(_ at: Double, now: Double) -> String {
    func units(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago" }
    let s = max(0, (now - at) / 1000)
    if s < 60 { return "just now" }
    let m = Int(s / 60)
    if m < 60 { return units(m, "minute") }
    let h = m / 60
    if h < 24 { return units(h, "hour") }
    let d = h / 24
    if d == 1 { return "yesterday" }
    if d < 7 { return "\(d) days ago" }
    if d < 30 { return units(d / 7, "week") }
    if d < 365 { return units(d / 30, "month") }
    return units(d / 365, "year")
  }
}

public enum SidebarGroupCardEvent: Equatable, Sendable {
  case choose(String)
  case close
  case hold(Bool)
  case focusPage
}

public final class SidebarGroupCardView: NSView, NSTextFieldDelegate {
  public var onEvent: ((SidebarGroupCardEvent) -> Void)?
  public var onPointer: ((Bool) -> Void)?
  public var live = true { didSet { if !live { handBack(toPage: false) } } }
  public private(set) var state: SidebarGroupCardState?
  public let favicons: SidebarFavicons

  private let surface = PanelSurfaceView()
  private let glass = SymbolView()
  private let field = NSTextField()
  private let separator = NSView()
  private let scroll = NSScrollView()
  private let list = GroupCardListView()
  private let empty = NSTextField(labelWithString: "")
  private var rowViews: [GroupCardRowView] = []
  private var shown: [SidebarGroupCardState.Row] = []
  private var selected = 0
  private var focused = false
  private weak var origin: NSResponder?
  private var tracking: NSTrackingArea?
  private var inside = false
  private var ticker: Timer?

  public override var isFlipped: Bool { true }

  public init(favicons: SidebarFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    addSubview(surface)
    addSubview(glass)
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Search Tabs"
    field.delegate = self
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    addSubview(field)
    separator.wantsLayer = true
    addSubview(separator)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = list
    addSubview(scroll)
    empty.lineBreakMode = .byTruncatingTail
    empty.font = .systemFont(ofSize: 13)
    list.addSubview(empty)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarGroupCardState) {
    let fresh = state?.groupId != next.groupId
    state = next
    if fresh {
      field.stringValue = ""
      selected = 0
      scroll.contentView.scroll(to: .zero)
    }
    let tokens = next.theme
    func color(_ key: String, _ fallback: String) -> NSColor { CSSColor(tokens[key] ?? fallback)?.ns ?? .labelColor }
    let dark = next.dark
    surface.dark = dark
    glass.set("magnifyingglass", size: 13, weight: .medium, color: color("textSecondary", dark ? "#FFFFFF80" : "#00000080"))
    field.textColor = color("textPrimary", dark ? "#FFFFFF" : "#000000")
    field.placeholderAttributedString = NSAttributedString(
      string: "Search Tabs", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color("placeholder", dark ? "#FFFFFF59" : "#00000059")])
    (field.currentEditor() as? NSTextView)?.insertionPointColor = color("textPrimary", dark ? "#FFFFFF" : "#000000")
    empty.textColor = color("textTertiary", dark ? "#FFFFFF59" : "#00000059")
    PrimitiveMotion.setInstantly {
      separator.layer?.backgroundColor = CSSColor(dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.1)")?.cg
    }
    if ticker == nil {
      let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRows() } }
      timer.tolerance = 3
      RunLoop.main.add(timer, forMode: .common)
      ticker = timer
    }
    refreshRows()
    setFrameSize(NSSize(width: SidebarGroupCardMetrics.width, height: SidebarGroupCardMetrics.height(next.rows.count)))
    needsLayout = true
  }

  private var query: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func refreshRows() {
    guard let state else { return }
    shown = SidebarGroupCardMetrics.matching(query, state.rows)
    selected = max(0, min(selected, shown.count - 1))
    let tokens = state.theme
    let dark = state.dark
    var host = SidebarHostState(profileId: "", dark: dark)
    host.theme = tokens
    let palette = SidebarPalette(host)
    while rowViews.count < shown.count {
      let row = GroupCardRowView()
      row.onHover = { [weak self, weak row] in
        guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }) else { return }
        self.select(index, reveal: false)
      }
      row.onPress = { [weak self, weak row] in
        guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }) else { return }
        self.choose(index)
      }
      list.addSubview(row)
      rowViews.append(row)
    }
    while rowViews.count > shown.count { rowViews.removeLast().removeFromSuperview() }
    let now = Date().timeIntervalSince1970 * 1000
    for (index, (view, row)) in zip(rowViews, shown).enumerated() {
      view.icon.favicons = favicons
      view.set(row, ago: SidebarGroupCardMetrics.ago(row.usedAt, now: now), palette: palette, selected: index == selected, dark: dark)
    }
    empty.isHidden = !shown.isEmpty
    empty.stringValue = query.isEmpty ? "No tabs" : "No tabs match \u{201C}\(query)\u{201D}"
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    let m = SidebarGroupCardMetrics.self
    surface.frame = bounds
    let inner = bounds.insetBy(dx: m.border, dy: m.border)
    let (x0, y0, width) = (inner.minX, inner.minY, inner.width)
    glass.frame = NSRect(x: x0 + m.inset, y: y0 + (m.searchRow - m.iconSlot) / 2, width: m.iconSlot, height: m.iconSlot)
    let fieldX = m.inset + m.iconSlot + m.iconGap
    let fieldHeight = ceil(NSFont.systemFont(ofSize: 13).boundingRectForFont.height)
    field.frame = NSRect(x: x0 + fieldX, y: y0 + (m.searchRow - fieldHeight) / 2 + m.baselineNudge, width: width - fieldX - m.inset, height: fieldHeight)
    separator.frame = NSRect(x: x0 + m.inset, y: y0 + m.searchRow + m.separatorGap, width: width - 2 * m.inset, height: m.hairline)
    let listTop = y0 + m.searchRow + m.separator
    let listHeight = m.listHeight(state?.rows.count ?? 0)
    scroll.frame = NSRect(x: x0, y: listTop, width: width, height: listHeight)
    let content = m.listPad * 2 + CGFloat(shown.count) * m.row
    list.frame = NSRect(x: 0, y: 0, width: width, height: max(listHeight, content))
    for (index, view) in rowViews.enumerated() {
      view.frame = NSRect(x: m.rowInset, y: m.listPad + CGFloat(index) * m.row, width: width - 2 * m.rowInset, height: m.row)
    }
    empty.frame = NSRect(x: m.inset, y: m.listPad + (m.row - 16) / 2, width: width - 2 * m.inset, height: 16)
  }

  private func select(_ index: Int, reveal: Bool) {
    guard !shown.isEmpty else { return }
    let next = max(0, min(shown.count - 1, index))
    if next != selected {
      selected = next
      for (i, view) in rowViews.enumerated() { view.selected = i == next }
    }
    if reveal { self.reveal(next) }
  }

  private func reveal(_ index: Int) {
    let m = SidebarGroupCardMetrics.self
    let rowTop = m.listPad + CGFloat(index) * m.row
    let offset = scroll.contentView.bounds.minY
    let height = scroll.frame.height
    var y: CGFloat?
    if rowTop - m.listPad < offset { y = rowTop - m.listPad }
    else if rowTop + m.row + m.listPad > offset + height { y = rowTop + m.row + m.listPad - height }
    guard let y else { return }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func choose(_ index: Int) {
    guard shown.indices.contains(index) else { return }
    onEvent?(.choose(shown[index].id))
    handBack(toPage: true)
  }

  private func takeFocus() {
    guard !focused, let window else { return }
    focused = true
    origin = window.firstResponder
    window.makeFirstResponder(field)
  }

  private func handBack(toPage: Bool) {
    guard focused else { return }
    focused = false
    onEvent?(.hold(false))
    let from = origin
    origin = nil
    if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
    if toPage { return onEvent?(.focusPage) ?? () }
    if let from, let window, (from as? NSView)?.window === window || from === window, window.makeFirstResponder(from) { return }
    onEvent?(.focusPage)
  }

  public func controlTextDidChange(_ note: Notification) {
    onEvent?(.hold(focused && !query.isEmpty))
    selected = 0
    scroll.contentView.scroll(to: .zero)
    refreshRows()
  }

  public func controlTextDidEndEditing(_ note: Notification) {
    guard focused else { return }
    focused = false
    origin = nil
    onEvent?(.hold(false))
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      choose(selected)
    case #selector(NSResponder.cancelOperation(_:)):
      onEvent?(.close)
      handBack(toPage: false)
    case #selector(NSResponder.moveDown(_:)):
      select(selected + 1, reveal: true)
    case #selector(NSResponder.moveUp(_:)):
      select(selected - 1, reveal: true)
    default:
      return false
    }
    return true
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) {
    pointer(true)
    if live { takeFocus() }
  }

  public override func mouseExited(with event: NSEvent) { pointer(false) }

  @objc private func devPointer(_ note: Notification) {
    guard DevPointer.inside(self, note) else { return pointer(false) }
    guard !inside else { return }
    pointer(true)
    if live { takeFocus() }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      pointer(false)
      ticker?.invalidate()
      ticker = nil
    }
  }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func mouseDown(with event: NSEvent) {}
}

final class GroupCardListView: NSView {
  override var isFlipped: Bool { true }
}

final class GroupCardRowView: NSView {
  var onHover: (() -> Void)?
  var onPress: (() -> Void)?
  let icon = TabIconView()
  private let plate = CALayer()
  private let title = FadeLabel(fontSize: 13)
  private let subtitle = NSTextField(labelWithString: "")
  private var tracking: NSTrackingArea?
  private var pressed = false { didSet { paint() } }
  private var dark = true
  var selected = false { didSet { if selected != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarGroupCardMetrics.rowRadius
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.lineBreakMode = .byTruncatingTail
    for view in [icon, title, subtitle] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ row: SidebarGroupCardState.Row, ago: String, palette: SidebarPalette, selected: Bool, dark: Bool) {
    self.dark = dark
    icon.set(TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId), palette: palette)
    title.text = row.title
    title.color = palette.textPrimary
    subtitle.stringValue = ago
    subtitle.textColor = palette.textSecondary
    setAccessibilityLabel(row.title)
    self.selected = selected
    paint()
  }

  override func layout() {
    super.layout()
    let m = SidebarGroupCardMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    let slot = NSRect(x: m.rowPadding, y: (bounds.height - m.iconSlot) / 2, width: m.iconSlot, height: m.iconSlot)
    icon.frame = slot.insetBy(dx: 2, dy: 2)
    let x = slot.maxX + m.iconGap
    let width = max(0, bounds.width - x - m.rowPadding)
    let top = (bounds.height - 30) / 2
    title.frame = NSRect(x: x, y: top, width: width, height: 16)
    subtitle.frame = NSRect(x: x - m.fieldPadding, y: top + 16 + m.baselineNudge, width: width + 2 * m.fieldPadding, height: 14)
  }

  private func paint() {
    let fill = pressed || selected ? CSSColor(dark ? "rgba(255,255,255,\(pressed ? 0.12 : 0.07))" : "rgba(0,0,0,\(pressed ? 0.1 : 0.06))")?.cg : nil
    PrimitiveMotion.setInstantly { plate.backgroundColor = fill }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }
  override func mouseDown(with event: NSEvent) { pressed = true }
  override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}

final class PanelSurfaceView: NSView {
  private let surface = SurfaceLayer()
  private let effect = NSVisualEffectView()
  private let overlay = CALayer()
  private let rim = SurfaceLayer()
  var dark = true { didSet { paint() } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.addSublayer(surface)
    surface.radius = PopoverMetrics.radius
    surface.glowColor = .black
    surface.glowRadius = 18
    surface.glowOffset = CGSize(width: 0, height: 8)
    effect.material = .menu
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = PopoverMetrics.radius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    addSubview(effect)
    overlay.cornerRadius = PopoverMetrics.radius
    overlay.cornerCurve = .continuous
    overlay.actions = SurfaceLayer.noActions
    effect.layer?.addSublayer(overlay)
    rim.radius = PopoverMetrics.radius
    rim.border = PopoverMetrics.border
    rim.zPosition = 10
    layer?.addSublayer(rim)
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func paint() {
    surface.fill = CSSColor(dark ? "rgba(38,36,37,0.94)" : "rgba(252,251,252,0.96)")?.ns
    surface.glowOpacity = dark ? 0.45 : 0.16
    rim.borderTint = CSSColor(dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")?.ns
    effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    PrimitiveMotion.setInstantly { overlay.backgroundColor = CSSColor(dark ? "rgba(38,36,37,0.72)" : "rgba(252,251,252,0.7)")?.cg }
  }

  override func layout() {
    super.layout()
    PrimitiveMotion.setInstantly {
      surface.frame = bounds
      rim.frame = bounds
      overlay.frame = bounds
    }
    effect.frame = bounds
  }
}
