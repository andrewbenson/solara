import AppKit
import QuartzCore
import SolaraOmnibox

public struct TabSearchState: Decodable, Equatable, Sendable {
  public struct Row: Decodable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var title: String
    public var url: String
    public var display: String
    public var host: String
    public var favicon: String?
    public var icon: String?
    public var profileId: String
    public var detail: String?

    public init(kind: String, id: String, title: String, url: String, display: String = "", host: String = "", favicon: String? = nil, icon: String? = nil, profileId: String = "", detail: String? = nil) {
      self.kind = kind
      self.id = id
      self.title = title
      self.url = url
      self.display = display
      self.host = host
      self.favicon = favicon
      self.icon = icon
      self.profileId = profileId
      self.detail = detail
    }
  }

  public var open: [Row]
  public var closed: [Row]
  public var dark: Bool
  public var theme: [String: String]
  public var openId: Int? = nil
}

public struct TabSearchSection: Equatable {
  public var title: String
  public var rows: [TabSearchState.Row]
}

public enum TabSearchMetrics {
  public static let width: CGFloat = 560
  public static let top: CGFloat = 56
  public static let margin: CGFloat = 12
  public static let header: CGFloat = 50
  public static let headerPadding: CGFloat = 16
  public static let gap: CGFloat = 10
  public static let glassBox: CGFloat = 18
  public static let glassSize: CGFloat = 15
  public static let fieldFont: CGFloat = 16
  public static let divider: CGFloat = 1
  public static let row: CGFloat = 36
  public static let rowRadius: CGFloat = 10
  public static let rowPadding: CGFloat = 10
  public static let icon: CGFloat = 16
  public static let textFont: CGFloat = 14
  public static let textHeight: CGFloat = 19
  public static let urlGap: CGFloat = 5
  public static let detailFont: CGFloat = 12
  public static let clockBox: CGFloat = 16
  public static let clockSize: CGFloat = 12
  public static let sectionInset: CGFloat = 6
  public static let sectionTop: CGFloat = 6
  public static let sectionTitleInset: CGFloat = 10
  public static let sectionTitleVertical: CGFloat = 4
  public static let sectionFont: CGFloat = 11
  public static let emptyHorizontal: CGFloat = 16
  public static let emptyVertical: CGFloat = 14
  public static let emptyFont: CGFloat = 13
  public static let bottom: CGFloat = 6
  public static let maxRows = 10
  public static let closedLimit = 8
  public static let radius: CGFloat = 16
  public static let border: CGFloat = 0.5
  public static let shadowRadius: CGFloat = 24
  public static let shadowOffset: CGFloat = 10
  public static var maxList: CGFloat { row * CGFloat(maxRows) + 60 }

  public static func lineHeight(_ font: NSFont) -> CGFloat { (ceil(NSLayoutManager().defaultLineHeight(for: font) * 2) + 1) / 2 }
  static var sectionTitleHeight: CGFloat { sectionTitleVertical * 2 + lineHeight(.systemFont(ofSize: sectionFont, weight: .semibold)) }
  static var emptyHeight: CGFloat { emptyVertical * 2 + lineHeight(.systemFont(ofSize: emptyFont)) }

  public static func frame(windowWidth: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: max(margin, (windowWidth - width) / 2), y: top, width: min(width, windowWidth - 2 * margin), height: height)
  }

  public static func sections(_ query: String, _ state: TabSearchState) -> [TabSearchSection] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else {
      return [TabSearchSection(title: "Open Tabs", rows: state.open), TabSearchSection(title: "Recently Closed", rows: Array(state.closed.prefix(closedLimit)))]
    }
    return [TabSearchSection(title: "Open Tabs", rows: rank(q, state.open)), TabSearchSection(title: "Recently Closed", rows: Array(rank(q, state.closed).prefix(closedLimit)))]
  }

  public static func rank(_ query: String, _ rows: [TabSearchState.Row]) -> [TabSearchState.Row] {
    var scored: [(row: TabSearchState.Row, order: Int, score: Double)] = []
    for (order, row) in rows.enumerated() {
      let score = max(fuzzyScore(query, row.title), fuzzyScore(query, row.host) * 0.9, fuzzyScore(query, row.url) * 0.6)
      if score > 0 { scored.append((row, order, score)) }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
    return scored.map(\.row)
  }

  public static func contentHeight(_ sections: [TabSearchSection]) -> CGFloat {
    let rows = sections.reduce(0) { $0 + $1.rows.count }
    var height: CGFloat = rows == 0 ? emptyHeight : 0
    for section in sections where !section.rows.isEmpty {
      height += sectionTop + sectionTitleHeight + CGFloat(section.rows.count) * row
    }
    return height
  }

  public static func panelHeight(_ sections: [TabSearchSection]) -> CGFloat {
    header + divider + min(maxList, contentHeight(sections)) + bottom
  }

  public static func scrollOffset(selecting index: Int) -> CGFloat {
    max(0, CGFloat(index - maxRows + 2) * row)
  }
}

public enum TabSearchEvent: Equatable, Sendable {
  case choose(kind: String, id: String)
  case close
}

public final class TabSearchPanelView: NSView, NSTextFieldDelegate {
  public var onEvent: ((TabSearchEvent) -> Void)?
  public private(set) var state: TabSearchState?
  public var favicons: SidebarFavicons

  private let panel = TabSearchSurfaceView()
  private let glass = SymbolView()
  private let field = NSTextField()
  private let divider = NSView()
  private let scroll = NSScrollView()
  private let list = GroupCardListView()
  private let empty = NSTextField(labelWithString: "")
  private var titleViews: [NSTextField] = []
  private var rowViews: [TabSearchRowView] = []
  private var sections: [TabSearchSection] = []
  private var rows: [TabSearchState.Row] = []
  private var selected = 0
  private var closing = false
  private var preparedDark: Bool?
  private weak var savedResponder: NSResponder?

  public override var isFlipped: Bool { true }

  public init(favicons: SidebarFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    isHidden = true
    layer?.masksToBounds = false
    addSubview(panel)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    panel.addSubview(glass)
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: TabSearchMetrics.fieldFont)
    field.placeholderString = "Search Tabs"
    field.delegate = self
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.setAccessibilityIdentifier("tabSearch.field")
    field.contentType = .solaraPlainText
    panel.addSubview(field)
    divider.wantsLayer = true
    panel.addSubview(divider)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = list
    panel.addSubview(scroll)
    empty.lineBreakMode = .byTruncatingTail
    empty.font = .systemFont(ofSize: TabSearchMetrics.emptyFont)
    list.addSubview(empty)
    panel.paint(fill: .clear, border: .clear, shadowOpacity: 0, glassTheme: NewTabTheme(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, tokens: [:]))
  }

  required init?(coder: NSCoder) { fatalError() }

  public var query: String { field.stringValue }
  public var selectedIndex: Int { selected }
  public var shownRows: [TabSearchState.Row] { rows }
  public var panelFrame: CGRect { panel.frame }
  public var typing: Bool { field.currentEditor() != nil }
  public var openId: Int? { state?.openId }

  public func prepare(dark: Bool) {
    guard isHidden else { return }
    preparedDark = dark
    panel.paint(fill: .clear, border: .clear, shadowOpacity: 0, glassTheme: NewTabTheme(dark: dark, tokens: [:]))
    panel.frame = TabSearchMetrics.frame(windowWidth: bounds.width, height: TabSearchMetrics.header + TabSearchMetrics.divider + TabSearchMetrics.maxList + TabSearchMetrics.bottom)
    panel.layoutSubtreeIfNeeded()
  }

  public func hide() {
    guard !isHidden else { return }
    closing = true
    savedResponder = nil
    if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
    isHidden = true
    if let state { preparedDark = state.dark }
    state = nil
    field.stringValue = ""
  }

  public func open(_ next: TabSearchState) {
    if let owner = Self.owner(of: window?.firstResponder, besides: field) { savedResponder = owner }
    field.stringValue = ""
    selected = 0
    closing = false
    isHidden = false
    set(next)
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    if field.currentEditor() == nil { window?.makeFirstResponder(field) }
  }

  public func set(_ next: TabSearchState) {
    state = next
    let palette = Self.palette(next)
    let tokens = next.theme
    func color(_ key: String, _ fallback: NSColor) -> NSColor { tokens[key].flatMap { CSSColor($0)?.ns } ?? fallback }
    panel.paint(fill: color("panel", palette.dark ? .black : .white), border: color("panelBorder", .clear), shadowOpacity: Double(tokens["panelShadowOpacity"] ?? "") ?? 0, glassTheme: NewTabTheme(dark: next.dark, tokens: tokens))
    glass.set("magnifyingglass", size: TabSearchMetrics.glassSize, weight: .medium, color: palette.textPrimary)
    field.textColor = palette.textPrimary
    field.placeholderAttributedString = NSAttributedString(
      string: "Search Tabs", attributes: [.font: NSFont.systemFont(ofSize: TabSearchMetrics.fieldFont), .foregroundColor: panel.usesGlass ? palette.textSecondary : color("placeholder", palette.textTertiary)])
    if let editor = field.currentEditor() as? NSTextView {
      editor.insertionPointColor = palette.textPrimary
      editor.selectedTextAttributes = [.backgroundColor: color("selection", .selectedTextBackgroundColor)]
    }
    empty.textColor = palette.textTertiary
    let dividerColor = panel.usesGlass ? palette.textPrimary.withAlphaComponent(next.dark ? 0.12 : 0.1) : palette.divider
    PrimitiveMotion.setInstantly { divider.layer?.backgroundColor = dividerColor.cgColor }
    refreshRows()
  }

  @objc private func accessibilityDisplayChanged() {
    if !isHidden, let state { set(state) }
    else if isHidden, let preparedDark { prepare(dark: preparedDark) }
  }

  isolated deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  private static func palette(_ state: TabSearchState) -> SidebarPalette {
    var host = SidebarHostState(profileId: "", dark: state.dark)
    host.theme = state.theme
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      host.theme["textSecondary"] = state.dark ? "#FFFFFFC7" : "#000000B8"
      host.theme["textTertiary"] = state.dark ? "#FFFFFFAD" : "#000000A3"
      host.theme["icon"] = state.dark ? "#FFFFFFE6" : "#000000D9"
    }
    return SidebarPalette(host)
  }

  private func refreshRows() {
    guard let state else { return }
    sections = TabSearchMetrics.sections(field.stringValue, state)
    rows = sections.flatMap(\.rows)
    let palette = Self.palette(state)
    let shownSections = sections.filter { !$0.rows.isEmpty }
    while titleViews.count < shownSections.count {
      let title = NSTextField(labelWithString: "")
      title.font = .systemFont(ofSize: TabSearchMetrics.sectionFont, weight: .semibold)
      list.addSubview(title)
      titleViews.append(title)
    }
    while titleViews.count > shownSections.count { titleViews.removeLast().removeFromSuperview() }
    for (view, section) in zip(titleViews, shownSections) {
      view.stringValue = section.title
      view.textColor = palette.textTertiary
    }
    while rowViews.count < rows.count {
      let row = TabSearchRowView()
      row.onHover = { [weak self, weak row] in
        guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }) else { return }
        self.select(index)
      }
      row.onPress = { [weak self, weak row] in
        guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }) else { return }
        self.choose(index)
      }
      list.addSubview(row)
      rowViews.append(row)
    }
    while rowViews.count > rows.count { rowViews.removeLast().removeFromSuperview() }
    for (index, (view, row)) in zip(rowViews, rows).enumerated() {
      view.icon.favicons = favicons
      view.set(row, palette: palette, selectedFill: panel.usesGlass ? palette.textPrimary.withAlphaComponent(0.12) : state.theme["rowSelected"].flatMap { CSSColor($0)?.ns }, selected: index == selected, glass: panel.usesGlass)
    }
    empty.isHidden = !rows.isEmpty
    empty.stringValue = "No tabs match \u{201C}\(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0, !closing else { return nil }
    return super.hitTest(point) ?? (frame.contains(point) ? self : nil)
  }

  public override func mouseDown(with event: NSEvent) {
    guard !panel.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
    close()
  }

  public override func layout() {
    super.layout()
    let m = TabSearchMetrics.self
    let height = m.panelHeight(sections)
    panel.frame = m.frame(windowWidth: bounds.width, height: height)
    let width = panel.bounds.width
    let fieldX = m.headerPadding + m.glassBox + m.gap
    glass.frame = NSRect(x: m.headerPadding, y: (m.header - m.glassBox) / 2, width: m.glassBox, height: m.glassBox)
    let fieldHeight = ceil(NSFont.systemFont(ofSize: m.fieldFont).boundingRectForFont.height)
    field.frame = NSRect(x: fieldX, y: (m.header - fieldHeight) / 2, width: max(0, width - fieldX - m.headerPadding), height: fieldHeight)
    let hairline = 1 / (window?.backingScaleFactor ?? 2)
    divider.frame = NSRect(x: 0, y: m.header + (m.divider - hairline) / 2, width: width, height: hairline)
    let listTop = m.header + m.divider
    let listHeight = min(m.maxList, m.contentHeight(sections))
    scroll.frame = NSRect(x: 0, y: listTop, width: width, height: listHeight)
    list.frame = NSRect(x: 0, y: 0, width: width, height: m.contentHeight(sections))
    empty.frame = NSRect(x: m.emptyHorizontal, y: m.emptyVertical, width: max(0, width - 2 * m.emptyHorizontal), height: m.emptyHeight - 2 * m.emptyVertical)
    var y: CGFloat = 0
    var titleIndex = 0
    var rowIndex = 0
    let inner = width - 2 * m.sectionInset
    for section in sections where !section.rows.isEmpty {
      y += m.sectionTop
      if titleViews.indices.contains(titleIndex) {
        titleViews[titleIndex].frame = NSRect(x: m.sectionInset + m.sectionTitleInset, y: y + m.sectionTitleVertical, width: inner - 2 * m.sectionTitleInset, height: m.sectionTitleHeight - 2 * m.sectionTitleVertical)
      }
      titleIndex += 1
      y += m.sectionTitleHeight
      for _ in section.rows {
        if rowViews.indices.contains(rowIndex) { rowViews[rowIndex].frame = NSRect(x: m.sectionInset, y: y, width: inner, height: m.row) }
        rowIndex += 1
        y += m.row
      }
    }
  }

  private func select(_ index: Int) {
    guard index != selected else { return }
    selected = index
    for (i, view) in rowViews.enumerated() { view.selected = i == index }
  }

  private func move(_ delta: Int) {
    let next = max(0, min(rows.count - 1, selected + delta))
    select(next)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(TabSearchMetrics.scrollOffset(selecting: next), max(0, list.frame.height - scroll.frame.height))))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func choose(_ index: Int) {
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    close(restoringFocus: false)
    onEvent?(.choose(kind: row.kind, id: row.id))
  }

  private func close(restoringFocus: Bool = true) {
    guard !closing else { return }
    closing = true
    let saved = savedResponder
    savedResponder = nil
    if field.currentEditor() != nil, let window {
      if !restoringFocus || !Self.restorable(saved, in: window) || !window.makeFirstResponder(saved) { window.makeFirstResponder(nil) }
    }
    onEvent?(.close)
  }

  private static func owner(of responder: NSResponder?, besides field: NSTextField) -> NSResponder? {
    if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSResponder {
      return owner === field ? nil : owner
    }
    return responder
  }

  private static func restorable(_ responder: NSResponder?, in window: NSWindow) -> Bool {
    guard let responder else { return false }
    if responder === window { return true }
    guard let view = responder as? NSView else { return false }
    return view.window === window && !view.isHiddenOrHasHiddenAncestor && view.acceptsFirstResponder
  }

  public func controlTextDidChange(_ note: Notification) {
    selected = 0
    refreshRows()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  public func controlTextDidEndEditing(_ note: Notification) {
    close(restoringFocus: false)
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      choose(selected)
    case #selector(NSResponder.cancelOperation(_:)):
      close()
    case #selector(NSResponder.moveDown(_:)):
      move(1)
    case #selector(NSResponder.moveUp(_:)):
      move(-1)
    default:
      return false
    }
    return true
  }
}

final class TabSearchSurfaceView: NSView {
  private let surface = SurfaceLayer()
  private var glassSurface: NewTabGlassSurface?
  private var glassTheme: NewTabTheme?
  private var appliedFrame: CGRect?
  private var appliedTint: NSColor?
  private var appliedDark: Bool?
  private(set) var usesGlass = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.addSublayer(surface)
    surface.radius = TabSearchMetrics.radius
    surface.border = TabSearchMetrics.border
    surface.glowColor = .black
    surface.glowRadius = TabSearchMetrics.shadowRadius
    surface.glowOffset = CGSize(width: 0, height: TabSearchMetrics.shadowOffset)
  }

  required init?(coder: NSCoder) { fatalError() }

  func paint(fill: NSColor, border: NSColor, shadowOpacity: Double, shadowRadius: CGFloat = TabSearchMetrics.shadowRadius, shadowOffset: CGFloat = TabSearchMetrics.shadowOffset, glassTheme: NewTabTheme? = nil) {
    paintSurface(fill: fill, border: border, shadowOpacity: shadowOpacity, shadowRadius: shadowRadius, shadowOffset: shadowOffset, glassTheme: glassTheme, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
  }

  #if DEBUG
  func paint(fill: NSColor, border: NSColor, shadowOpacity: Double, glassTheme: NewTabTheme, reduceTransparency: Bool) {
    paintSurface(fill: fill, border: border, shadowOpacity: shadowOpacity, shadowRadius: TabSearchMetrics.shadowRadius, shadowOffset: TabSearchMetrics.shadowOffset, glassTheme: glassTheme, reduceTransparency: reduceTransparency)
  }
  #endif

  private func paintSurface(fill: NSColor, border: NSColor, shadowOpacity: Double, shadowRadius: CGFloat, shadowOffset: CGFloat, glassTheme: NewTabTheme?, reduceTransparency: Bool) {
    self.glassTheme = glassTheme
    usesGlass = glassTheme != nil && !reduceTransparency
    if usesGlass, glassSurface == nil {
      let glass = NewTabGlassSurface(frame: bounds)
      addSubview(glass, positioned: .below, relativeTo: subviews.first)
      glassSurface = glass
    }
    glassSurface?.isHidden = !usesGlass
    surface.isHidden = usesGlass
    surface.fill = fill
    surface.borderTint = border
    surface.glowOpacity = shadowOpacity
    surface.glowRadius = shadowRadius
    surface.glowOffset = CGSize(width: 0, height: shadowOffset)
    updateGlass()
  }

  private func updateGlass() {
    guard usesGlass, let glassSurface, let glassTheme else { return }
    let tint = glassTheme.ntpBarSolid.ns
    guard appliedFrame != bounds || appliedTint != tint || appliedDark != glassTheme.dark else { return }
    glassSurface.frame = bounds
    glassSurface.apply(frame: bounds, radius: NewTabLayout.barRadius, tint: tint, dark: glassTheme.dark)
    appliedFrame = bounds
    appliedTint = tint
    appliedDark = glassTheme.dark
  }

  override func layout() {
    super.layout()
    PrimitiveMotion.setInstantly { surface.frame = bounds }
    updateGlass()
  }

  override func mouseDown(with event: NSEvent) {}
}

final class TabSearchRowView: NSView {
  var onHover: (() -> Void)?
  var onPress: (() -> Void)?
  let icon = TabIconView()
  private let plate = CALayer()
  private let iconPlate = CALayer()
  private let title = FadeLabel(fontSize: TabSearchMetrics.textFont)
  private let url = FadeLabel(fontSize: TabSearchMetrics.textFont)
  private let detail = NSTextField(labelWithString: "")
  private let clock = SymbolView()
  private var tracking: NSTrackingArea?
  private var fill: NSColor?
  private var hasURL = false
  private var closed = false
  var selected = false { didSet { if selected != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = TabSearchMetrics.rowRadius
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    iconPlate.actions = SurfaceLayer.noActions
    iconPlate.cornerRadius = 4
    iconPlate.cornerCurve = .continuous
    layer?.addSublayer(iconPlate)
    detail.font = .systemFont(ofSize: TabSearchMetrics.detailFont)
    detail.lineBreakMode = .byClipping
    for view in [icon, title, url, detail, clock] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ row: TabSearchState.Row, palette: SidebarPalette, selectedFill: NSColor?, selected: Bool, glass: Bool = false) {
    icon.set(TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId, size: TabSearchMetrics.icon), palette: palette)
    PrimitiveMotion.setInstantly {
      iconPlate.backgroundColor = glass ? NSColor(white: palette.dark ? 1 : 0, alpha: palette.dark ? 0.1 : 0.05).cgColor : nil
    }
    title.text = row.title
    title.color = palette.textPrimary
    hasURL = !row.url.isEmpty
    url.isHidden = !hasURL
    url.text = "\u{2014} \(row.display)"
    url.color = palette.textSecondary
    detail.stringValue = row.detail ?? ""
    detail.isHidden = (row.detail ?? "").isEmpty
    detail.textColor = palette.textTertiary
    closed = row.kind == "closed"
    clock.isHidden = !closed
    if closed { clock.set("clock.arrow.circlepath", size: TabSearchMetrics.clockSize, color: palette.textTertiary) }
    fill = selectedFill
    setAccessibilityLabel(row.title)
    self.selected = selected
    paint()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let m = TabSearchMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    var x = m.rowPadding
    icon.frame = NSRect(x: x, y: (bounds.height - m.icon) / 2, width: m.icon, height: m.icon)
    PrimitiveMotion.setInstantly { iconPlate.frame = icon.frame.insetBy(dx: -2, dy: -2) }
    x += m.icon + m.gap
    var right = bounds.width - m.rowPadding
    if closed {
      clock.frame = NSRect(x: right - m.clockBox, y: (bounds.height - m.clockBox) / 2, width: m.clockBox, height: m.clockBox)
      right -= m.clockBox + m.gap
    }
    if !detail.isHidden {
      let size = detail.fittingSize
      detail.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
      right -= size.width + m.gap
    }
    let text = max(0, right - x)
    let y = (bounds.height - m.textHeight) / 2
    if hasURL {
      let flex = max(0, text - m.urlGap)
      title.frame = NSRect(x: x, y: y, width: flex * 3 / 5, height: m.textHeight)
      url.frame = NSRect(x: x + flex * 3 / 5 + m.urlGap, y: y, width: flex * 2 / 5, height: m.textHeight)
    } else {
      title.frame = NSRect(x: x, y: y, width: text, height: m.textHeight)
    }
  }

  private func paint() {
    PrimitiveMotion.setInstantly { plate.backgroundColor = selected ? fill?.cgColor : nil }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }
  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}
