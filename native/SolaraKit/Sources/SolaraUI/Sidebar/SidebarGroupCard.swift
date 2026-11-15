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
    public var dimmed: Bool?
    public var engineSymbol: String?
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
  #if SOLARA_PROBES
  public var probeRowBinding: ((NSView, String) -> Void)?
  #endif
  public var virtualizesRows = false { didSet { if oldValue != virtualizesRows { refreshRows(); needsLayout = true } } }
  public var live = true { didSet { if !live { handBack(toPage: false) } } }
  public private(set) var state: SidebarGroupCardState?
  public let favicons: SidebarFavicons

  private let surface = PanelSurfaceView()
  private let glass = SymbolView()
  private let field = GroupCardSearchField()
  private let separator = NSView()
  private let scroll = NSScrollView()
  private let list = GroupCardListView()
  private let empty = NSTextField(labelWithString: "")
  private let rowPool = SidebarAuxiliaryRowPool()
  private let viewportWatch = SidebarAuxiliaryViewportWatch()
  private var shown: [SidebarGroupCardState.Row] = []
  private var selected = 0
  private var focused = false
  private weak var origin: NSResponder?
  private var originSelection: NSRange?
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
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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
    if let selection = tokens["selection"].flatMap({ CSSColor($0)?.ns }), let editor = field.currentEditor() as? NSTextView {
      editor.selectedTextAttributes = [.backgroundColor: selection]
    }
    empty.textColor = color("textTertiary", dark ? "#FFFFFF59" : "#00000059")
    PrimitiveMotion.setInstantly {
      separator.layer?.backgroundColor = CSSColor(dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.1)")?.cg
    }
    syncTicker()
    refreshRows()
    setFrameSize(NSSize(width: SidebarGroupCardMetrics.width, height: SidebarGroupCardMetrics.height(next.rows.count)))
    needsLayout = true
  }

  private func syncTicker() {
    if virtualizesRows, window == nil || isHiddenOrHasHiddenAncestor {
      ticker?.invalidate()
      ticker = nil
      return
    }
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRows() } }
    timer.tolerance = 3
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private var query: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func refreshRows() {
    guard let state else { return }
    shown = SidebarGroupCardMetrics.matching(query, state.rows)
    selected = max(0, min(selected, shown.count - 1))
    syncRows()
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
    syncRows()
    watchViewport()
    empty.frame = NSRect(x: m.inset, y: m.listPad + (m.row - 16) / 2, width: width - 2 * m.inset, height: 16)
  }

  private func rowFrame(_ index: Int) -> CGRect {
    let m = SidebarGroupCardMetrics.self
    return CGRect(x: m.rowInset, y: m.listPad + CGFloat(index) * m.row, width: max(0, list.bounds.width - 2 * m.rowInset), height: m.row)
  }

  private func syncRows() {
    guard let state else { return }
    var host = SidebarHostState(profileId: "", dark: state.dark)
    host.theme = state.theme
    let palette = SidebarPalette(host)
    let now = Date().timeIntervalSince1970 * 1000
    rowPool.reconcile(keys: shown.map(\.id), frames: shown.indices.map(rowFrame), container: list, virtualized: virtualizesRows, make: { _ in GroupCardRowView() }, clear: { [weak self] view in
      if view === self?.window?.firstResponder { self?.window?.makeFirstResponder(self?.field) }
      (view as? GroupCardRowView)?.clearBinding()
    }) { [weak self] view, index in
      guard let self, let view = view as? GroupCardRowView else { return }
      let row = shown[index]
      view.icon.favicons = favicons
      view.set(row, ago: SidebarGroupCardMetrics.ago(row.usedAt, now: now), palette: palette, selected: index == selected, dark: state.dark)
      view.setAccessibilityElement(!virtualizesRows)
      #if SOLARA_PROBES
      probeRowBinding?(view, row.profileId)
      #endif
      view.onHover = { [weak self] in
        guard let self, let index = shown.firstIndex(where: { $0.id == row.id }) else { return }
        select(index, reveal: false)
      }
      view.onPress = { [weak self] in
        guard let self, let index = shown.firstIndex(where: { $0.id == row.id }) else { return }
        choose(index)
      }
      view.onCommand = { [weak self] event in
        guard let self, let index = shown.firstIndex(where: { $0.id == row.id }) else { return false }
        switch event.keyCode {
        case 48:
          focusRow(index + (event.modifierFlags.contains(.shift) ? -1 : 1))
        case 53:
          onEvent?(.close)
          handBack(toPage: false)
        case 125, 126:
          focusRow(max(0, min(shown.count - 1, index + (event.keyCode == 125 ? 1 : -1))))
        default:
          return false
        }
        return true
      }
      view.onFocusExit = { [weak self] in self?.releaseFocusOutsideCard() }
    }
    rowPool.updateElements(keys: shown.map(\.id), parent: self, label: { [weak self] key in
      self?.shown.first { $0.id == key }?.title
    }, frame: { [weak self] key in
      guard let self, let index = shown.firstIndex(where: { $0.id == key }) else { return .zero }
      return SidebarAuxiliaryViewport.screen(rowFrame(index), in: list)
    }, action: { [weak self] key, action in
      guard let self, virtualizesRows, !SidebarAuxiliaryViewport.clip(self).isEmpty, let index = shown.firstIndex(where: { $0.id == key }), action != "menu" else { return false }
      select(index, reveal: true)
      if action == "press" { choose(index) }
      return true
    })
  }

  private func watchViewport() {
    viewportWatch.watch(list) { [weak self] in self?.syncRows() }
  }

  @objc private func scrolled() { syncRows() }

  public override func accessibilityChildren() -> [Any]? {
    guard virtualizesRows else { return super.accessibilityChildren() }
    return [field] as [Any] + rowPool.orderedElements
  }

  public override func viewDidHide() {
    super.viewDidHide()
    if virtualizesRows {
      handBack(toPage: false)
      rowPool.clear { ($0 as? GroupCardRowView)?.clearBinding() }
      viewportWatch.stop()
      syncTicker()
    }
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    syncTicker()
    syncRows()
    watchViewport()
  }

  private func focusRow(_ index: Int) {
    guard shown.indices.contains(index) else { window?.makeFirstResponder(field); return }
    let id = shown[index].id
    select(index, reveal: true)
    window?.makeFirstResponder(rowPool.views[id] ?? field)
  }

  private func select(_ index: Int, reveal: Bool) {
    guard !shown.isEmpty else { return }
    let next = max(0, min(shown.count - 1, index))
    if next != selected {
      selected = next
      for (key, view) in rowPool.views { (view as? GroupCardRowView)?.selected = key == shown[next].id }
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
    guard let y else { syncRows(); return }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    syncRows()
  }

  private func choose(_ index: Int) {
    guard shown.indices.contains(index) else { return }
    onEvent?(.choose(shown[index].id))
    handBack(toPage: true)
  }

  private func takeFocus() {
    guard !focused, let window else { return }
    focused = true
    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
      origin = field
      originSelection = editor.selectedRange()
    } else {
      origin = window.firstResponder
      originSelection = nil
    }
    window.makeFirstResponder(field)
  }

  private func handBack(toPage: Bool) {
    guard focused else { return }
    focused = false
    onEvent?(.hold(false))
    let from = origin
    let selection = originSelection
    origin = nil
    originSelection = nil
    guard let window, ownsFocus else { return }
    window.makeFirstResponder(nil)
    if toPage { return onEvent?(.focusPage) ?? () }
    if let from, let view = from as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder, window.makeFirstResponder(from) {
      if let selection, let editor = (from as? NSTextField)?.currentEditor() as? NSTextView {
        let length = (editor.string as NSString).length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
      }
      return
    }
    if from === window, window.makeFirstResponder(window) { return }
    onEvent?(.focusPage)
  }

  public func controlTextDidChange(_ note: Notification) {
    onEvent?(.hold(focused && !query.isEmpty))
    selected = 0
    scroll.contentView.scroll(to: .zero)
    refreshRows()
  }

  public func controlTextDidEndEditing(_ note: Notification) {
    releaseFocusOutsideCard()
  }

  private func releaseFocusOutsideCard() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.focused, !self.ownsFocus else { return }
      self.focused = false
      self.origin = nil
      self.originSelection = nil
      self.onEvent?(.hold(false))
    }
  }

  private var ownsFocus: Bool {
    guard let current = window?.firstResponder as? NSView else { return false }
    if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
      return field === self || field.isDescendant(of: self)
    }
    return current === self || current.isDescendant(of: self)
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
    case #selector(NSResponder.insertTab(_:)):
      focusRow(0)
    case #selector(NSResponder.insertBacktab(_:)):
      focusRow(shown.count - 1)
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
      if virtualizesRows { rowPool.clear { ($0 as? GroupCardRowView)?.clearBinding() }; viewportWatch.stop() }
    } else { syncTicker(); syncRows(); watchViewport() }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { handBack(toPage: false) }
    super.viewWillMove(toWindow: newWindow)
  }

  public override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil { handBack(toPage: false) }
    super.viewWillMove(toSuperview: newSuperview)
  }

  public override func removeFromSuperview() {
    handBack(toPage: false)
    super.removeFromSuperview()
  }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func mouseDown(with event: NSEvent) {}
}

final class GroupCardSearchField: NSTextField {
  override func accessibilityLabel() -> String? { "Search Tabs" }
}

final class GroupCardListView: NSView {
  override var isFlipped: Bool { true }
}

final class GroupCardRowView: NSView {
  var onHover: (() -> Void)?
  var onPress: (() -> Void)?
  var onCommand: ((NSEvent) -> Bool)?
  var onFocusExit: (() -> Void)?
  let icon = TabIconView()
  private let plate = CALayer()
  private let title = FadeLabel(fontSize: 13)
  private let subtitle = NSTextField(labelWithString: "")
  private var tracking: NSTrackingArea?
  private var pressed = false { didSet { paint() } }
  private var dark = true
  private var down = false
  var selected = false { didSet { if selected != oldValue { paint() } } }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

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

  override func becomeFirstResponder() -> Bool {
    onHover?()
    return true
  }

  override func resignFirstResponder() -> Bool {
    onFocusExit?()
    return true
  }

  override func keyDown(with event: NSEvent) {
    if onCommand?(event) == true { return }
    if [36, 49, 76].contains(event.keyCode), !event.isARepeat { onPress?() }
    else { super.keyDown(with: event) }
  }

  func set(_ row: SidebarGroupCardState.Row, ago: String, palette: SidebarPalette, selected: Bool, dark: Bool) {
    self.dark = dark
    icon.set(TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId, dimmed: row.dimmed ?? false, engineSymbol: row.engineSymbol), palette: palette)
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
  override func mouseDown(with event: NSEvent) { down = true; pressed = true }
  override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

  override func mouseUp(with event: NSEvent) {
    let inside = down && bounds.contains(convert(event.locationInWindow, from: nil))
    down = false
    pressed = false
    if inside { onPress?() }
  }

  func clearBinding() {
    down = false
    pressed = false
    selected = false
    onHover = nil
    onPress = nil
    onCommand = nil
    onFocusExit = nil
    nextKeyView = nil
    setAccessibilityElement(false)
    setAccessibilityLabel(nil)
    SidebarRowReuse.reset(self)
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

@MainActor
enum SidebarAuxiliaryViewport {
  static func clip(_ view: NSView) -> CGRect {
    guard !view.isHiddenOrHasHiddenAncestor, view.window?.isMiniaturized != true else { return .zero }
    var rect = view.bounds
    var ancestor = view.superview
    while let current = ancestor {
      rect = rect.intersection(view.convert(current.bounds, from: current))
      if rect.isNull || rect.isEmpty { return .zero }
      ancestor = current.superview
    }
    return rect
  }

  static func screen(_ rect: CGRect, in view: NSView) -> CGRect {
    guard let window = view.window else { return .zero }
    return window.convertToScreen(view.convert(rect, to: nil))
  }
}

final class SidebarAuxiliaryElement: NSAccessibilityElement {
  @MainActor
  private final class Payload {
    var label: (() -> String?)?
    var frame: (() -> CGRect)?
    var action: ((String) -> Bool)?
  }

  private let payload: Payload

  @MainActor
  init(parent: NSView) {
    payload = Payload()
    super.init()
    setAccessibilityParent(parent)
  }

  @MainActor
  var label: (() -> String?)? {
    get { payload.label }
    set { payload.label = newValue }
  }

  @MainActor
  var frame: (() -> CGRect)? {
    get { payload.frame }
    set { payload.frame = newValue }
  }

  @MainActor
  var action: ((String) -> Bool)? {
    get { payload.action }
    set { payload.action = newValue }
  }

  override func accessibilityLabel() -> String? {
    let value = payload
    return MainActor.assumeIsolated { value.label?() }
  }

  override func accessibilityFrame() -> CGRect {
    let value = payload
    return MainActor.assumeIsolated { value.frame?() ?? .zero }
  }

  override func accessibilityPerformPress() -> Bool {
    let value = payload
    return MainActor.assumeIsolated { value.action?("press") ?? false }
  }

  override func accessibilityPerformShowMenu() -> Bool {
    let value = payload
    return MainActor.assumeIsolated { value.action?("menu") ?? false }
  }

  override func setAccessibilityFocused(_ focused: Bool) {
    let value = payload
    MainActor.assumeIsolated { if focused { _ = value.action?("focus") } }
  }

  @MainActor
  func invalidate() {
    payload.label = nil
    payload.frame = nil
    payload.action = nil
    setAccessibilityParent(nil)
  }
}

@MainActor
final class SidebarAuxiliaryRowPool {
  private(set) var views: [String: NSView] = [:]
  private var recycled: [NSView] = []
  private var elements: [String: SidebarAuxiliaryElement] = [:]
  private(set) var orderedElements: [SidebarAuxiliaryElement] = []
  private var reconciling = false

  func reconcile(keys: [String], frames: [CGRect], container: NSView, virtualized: Bool, make: (Int) -> NSView, clear: (NSView) -> Void, bind: (NSView, Int) -> Void) {
    guard !reconciling else { return }
    reconciling = true
    defer { reconciling = false }
    let clip = SidebarAuxiliaryViewport.clip(container)
    let wanted = keys.indices.filter { !virtualized || (!clip.isEmpty && frames[$0].intersects(clip)) }
    let seen = Set(wanted.map { keys[$0] })
    for (key, view) in views where !seen.contains(key) {
      views[key] = nil
      clear(view)
      view.removeFromSuperview()
      if virtualized, recycled.count < wanted.count { recycled.append(view) }
    }
    recycled = Array(recycled.prefix(virtualized ? wanted.count : 0))
    for index in wanted {
      let key = keys[index]
      let view = views[key] ?? recycled.popLast() ?? make(index)
      if views[key] == nil { views[key] = view }
      if view.superview !== container { container.addSubview(view) }
      view.frame = frames[index]
      bind(view, index)
    }
  }

  func updateElements(keys: [String], parent: NSView, label: @escaping (String) -> String?, frame: @escaping (String) -> CGRect, action: @escaping (String, String) -> Bool) {
    let seen = Set(keys)
    for (key, element) in elements where !seen.contains(key) {
      element.invalidate()
      elements[key] = nil
    }
    orderedElements = keys.map { key in
      let element = elements[key] ?? SidebarAuxiliaryElement(parent: parent)
      element.setAccessibilityParent(parent)
      element.setAccessibilityRole(.button)
      element.setAccessibilityElement(true)
      element.label = { label(key) }
      element.frame = { frame(key) }
      element.action = { action(key, $0) }
      elements[key] = element
      return element
    }
  }

  func clear(_ clear: (NSView) -> Void) {
    for view in views.values { clear(view); view.removeFromSuperview() }
    views.removeAll()
    recycled.removeAll()
    for element in elements.values { element.invalidate() }
    elements.removeAll()
    orderedElements.removeAll()
  }
}

@MainActor
final class SidebarAuxiliaryViewportWatch {
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
  private var ancestors: [ObjectIdentifier] = []

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    ancestors = []
  }

  func watch(_ view: NSView, changed: @escaping @MainActor () -> Void) {
    var chain: [NSView] = []
    var next: NSView? = view
    while let current = next { chain.append(current); next = current.superview }
    let ids = chain.map(ObjectIdentifier.init)
    guard ids != ancestors else { return }
    ancestors = ids
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    for current in chain {
      current.postsFrameChangedNotifications = true
      current.postsBoundsChangedNotifications = true
      for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: current, queue: .main) { _ in
          MainActor.assumeIsolated { changed() }
        })
      }
    }
  }
}
