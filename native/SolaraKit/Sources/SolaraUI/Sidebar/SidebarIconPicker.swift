import AppKit
import QuartzCore

public struct SidebarIconPickerState: Decodable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var current: String?
  public var anchor: [Double]?
  public var sidebarWidth: Double
  public var dark: Bool
  public var shadowOpacity: Double
  public var theme: [String: String]

  public init(id: String, kind: String, current: String?, anchor: [Double]?, sidebarWidth: Double, dark: Bool, shadowOpacity: Double, theme: [String: String]) {
    self.id = id
    self.kind = kind
    self.current = current
    self.anchor = anchor
    self.sidebarWidth = sidebarWidth
    self.dark = dark
    self.shadowOpacity = shadowOpacity
    self.theme = theme
  }

  public var anchorRect: CGRect? {
    guard let anchor, anchor.count == 4 else { return nil }
    return CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])
  }
}

public enum SidebarIconPickerTab: String, Sendable {
  case emoji
  case symbols
}

public enum SidebarIconPickerMetrics {
  public static let symbolPrefix = "symbol:"
  public static let noGroupIcon = "symbol:square.stack.fill"
  public static let recentSection = "Recent"
  public static let recentLimit = 21
  public static let width: CGFloat = 256
  static let border: CGFloat = 0.5
  static let padding: CGFloat = 8
  static let gap: CGFloat = 8
  static let radius: CGFloat = 14
  static let shadowRadius: CGFloat = 20
  static let shadowOffsetY: CGFloat = 8
  static let edge: CGFloat = 8
  static let anchorGap: CGFloat = 6
  static let fallbackAnchorY: CGFloat = 60
  static let search: CGFloat = 26
  static let searchRadius: CGFloat = 8
  static let searchPadding: CGFloat = 7
  static let glass: CGFloat = 14
  static let glassSymbol: CGFloat = 11
  static let fieldGap: CGFloat = 5
  static let fieldFont: CGFloat = 12
  static let tabWidth: CGFloat = 28
  static let tabGap: CGFloat = 6
  static let tabBox: CGFloat = 16
  static let tabSymbol: CGFloat = 13
  public static let sectionBar: CGFloat = 24
  static let sectionSymbol: CGFloat = 12
  public static let cell: CGFloat = 30
  static let cellRadius: CGFloat = 8
  static let gridRows: CGFloat = 6
  static let emojiFont: CGFloat = 18
  static let cellSymbol: CGFloat = 15
  static let footer: CGFloat = 26
  static let footerGap: CGFloat = 6
  static let footerInnerGap: CGFloat = 5
  static let footerBox: CGFloat = 14
  static let footerSymbol: CGFloat = 11
  static let label: CGFloat = 12
  static let emptyPadding: CGFloat = 8
  static var inset: CGFloat { border + padding }
  public static var inner: CGFloat { width - 2 * inset }
  public static var columns: Int { max(1, Int((inner / cell).rounded(.down))) }

  static func textOffset(box: CGFloat, text: CGFloat, scale: CGFloat) -> CGFloat {
    ((box - text - 0.001) / 2 * scale).rounded(.down) / scale
  }

  public static func origin(anchor: CGRect?, sidebarWidth: CGFloat) -> CGPoint {
    let top = max(edge, (anchor?.minY ?? fallbackAnchorY) - edge)
    let left = anchor.map { max(edge, min(sidebarWidth + anchorGap, $0.maxX + anchorGap)) } ?? sidebarWidth + anchorGap
    return CGPoint(x: left, y: top)
  }

  public static func showsFooter(_ state: SidebarIconPickerState) -> Bool {
    state.kind == "group" || state.current != nil
  }

  public static func isSymbol(_ icon: String) -> Bool { icon.hasPrefix(symbolPrefix) }
}

@MainActor
public final class IconPickerRecents {
  public static let shared = IconPickerRecents(defaults: .standard)
  static let key = "SolaraIconPickerRecents"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func list(_ tab: SidebarIconPickerTab) -> [String] {
    (defaults.stringArray(forKey: Self.key) ?? []).filter { SidebarIconPickerMetrics.isSymbol($0) == (tab == .symbols) }
  }

  public func note(_ icon: String) {
    let kept = (defaults.stringArray(forKey: Self.key) ?? []).filter { $0 != icon }
    let mine = kept.filter { SidebarIconPickerMetrics.isSymbol($0) == SidebarIconPickerMetrics.isSymbol(icon) }
    let others = kept.filter { SidebarIconPickerMetrics.isSymbol($0) != SidebarIconPickerMetrics.isSymbol(icon) }
    defaults.set(Array(([icon] + mine).prefix(SidebarIconPickerMetrics.recentLimit)) + others, forKey: Self.key)
  }
}

public final class SidebarIconPickerView: NSView, NSTextFieldDelegate {
  public enum Event: Equatable {
    case choose(String?)
    case close
  }

  public var onEvent: ((Event) -> Void)?
  public var catalog: IconCatalog = .shared
  public var recents: IconPickerRecents = .shared
  public var embedded = false { didSet { if embedded != oldValue { panel.frame.origin = .zero; needsLayout = true } } }
  public private(set) var state: SidebarIconPickerState?
  public private(set) var tab: SidebarIconPickerTab = .emoji
  public private(set) var section: String?
  public private(set) var items: [String] = []
  public let panel = IconPickerPanelView()
  let field = IconPickerField()
  private let surface = SurfaceLayer()
  private let pill = CALayer()
  private let glass = SymbolView()
  private let tabButtons = [IconPickerTabButton(.emoji), IconPickerTabButton(.symbols)]
  private let sectionBar = IconPickerSectionBar()
  private let scroll = NSScrollView()
  private let grid = IconPickerGridView()
  private let empty = OnboardingTextNSView()
  private let footerButtons = [IconPickerFooterButton(), IconPickerFooterButton()]
  private var emptyHeight: CGFloat = 0
  private var pressedOutside = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    panel.wantsLayer = true
    panel.layer?.masksToBounds = false
    let m = SidebarIconPickerMetrics.self
    surface.radius = m.radius
    surface.border = m.border
    surface.glowColor = .black
    surface.glowRadius = m.shadowRadius
    surface.glowOffset = CGSize(width: 0, height: m.shadowOffsetY)
    panel.layer?.addSublayer(surface)
    pill.actions = SurfaceLayer.noActions
    pill.cornerRadius = m.searchRadius
    pill.cornerCurve = .circular
    panel.layer?.addSublayer(pill)
    panel.addSubview(glass)
    field.delegate = self
    panel.addSubview(field)
    for button in tabButtons {
      button.onPress = { [weak self] tab in self?.select(tab) }
      panel.addSubview(button)
    }
    sectionBar.onPress = { [weak self] name in self?.show(section: name) }
    panel.addSubview(sectionBar)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = grid
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    grid.onChoose = { [weak self] icon in self?.choose(icon) }
    panel.addSubview(scroll)
    empty.manager.usesFontLeading = false
    grid.addSubview(empty)
    for button in footerButtons {
      button.onPress = { [weak self, weak button] in
        guard let button else { return }
        self?.onEvent?(.choose(button.value))
      }
      panel.addSubview(button)
    }
    addSubview(panel)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarIconPickerState) {
    let fresh = state?.id != next.id || state?.kind != next.kind
    state = next
    if fresh {
      tab = next.current.map(SidebarIconPickerMetrics.isSymbol) == true ? .symbols : .emoji
      section = openingSection(current: next.current)
      field.stringValue = ""
      grid.hovered = nil
    }
    paint()
    refilter(scrollToTop: fresh)
    if fresh, let current = next.current, let index = items.firstIndex(of: current) { grid.reveal(index) }
  }

  public var query: String { field.stringValue }
  public var isEditing: Bool { (window?.firstResponder as? NSTextView)?.delegate === field }
  public var sectionNames: [String] { sections().map(\.name) }

  public func devInput(_ action: String) {
    if action.hasPrefix("type:") {
      focus()
      let text = String(action.dropFirst(5))
      if let editor = field.currentEditor() { editor.insertText(text) } else { field.stringValue += text }
      controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    } else if action.hasPrefix("section:") {
      show(section: String(action.dropFirst(8)))
    } else if let selector = Self.keySelectors[action] {
      focus()
      guard let editor = field.currentEditor() as? NSTextView else { return }
      _ = control(field, textView: editor, doCommandBy: selector)
    } else if let next = SidebarIconPickerTab(rawValue: action) {
      select(next)
    }
  }

  static let keySelectors: [String: Selector] = [
    "escape": #selector(NSResponder.cancelOperation(_:)), "return": #selector(NSResponder.insertNewline(_:)),
    "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)),
    "left": #selector(NSResponder.moveLeft(_:)), "right": #selector(NSResponder.moveRight(_:)),
  ]

  public func focus() {
    window?.makeFirstResponder(field)
  }

  func select(_ next: SidebarIconPickerTab) {
    guard next != tab else { return }
    tab = next
    section = openingSection(current: nil)
    grid.hovered = nil
    paint()
    refilter(scrollToTop: true)
  }

  func show(section name: String) {
    guard sections().contains(where: { $0.name == name }) else { return }
    section = name
    if !field.stringValue.isEmpty { field.stringValue = "" }
    grid.hovered = nil
    paint()
    refilter(scrollToTop: true)
  }

  private func choose(_ icon: String) {
    recents.note(icon)
    onEvent?(.choose(icon))
  }

  private func sections() -> [IconCatalogSection] {
    let recent = recents.list(tab)
    let all = catalog.sections(tab)
    let known = Set(all.flatMap { $0.entries.map(\.icon) })
    let kept = recent.filter(known.contains)
    guard !kept.isEmpty else { return all }
    let words = Dictionary(all.flatMap(\.entries).map { ($0.icon, $0.words) }, uniquingKeysWith: { first, _ in first })
    let section = IconCatalogSection(name: SidebarIconPickerMetrics.recentSection, symbol: "clock",
      entries: kept.map { IconCatalogEntry(icon: $0, words: words[$0] ?? "") })
    return [section] + all
  }

  private func openingSection(current: String?) -> String? {
    let all = sections()
    if let current, let holder = all.first(where: { $0.name != SidebarIconPickerMetrics.recentSection && $0.entries.contains { $0.icon == current } }) {
      return holder.name
    }
    return all.first?.name
  }

  private func color(_ key: String) -> NSColor? { state?.theme[key].flatMap { CSSColor($0)?.ns } }

  private func paint() {
    guard let state else { return }
    let m = SidebarIconPickerMetrics.self
    surface.fill = color("panel") ?? (embedded ? nil : .windowBackgroundColor)
    surface.borderTint = embedded ? nil : color("panelBorder")
    surface.glowOpacity = embedded ? 0 : state.shadowOpacity
    let hover = color("pickerCellHover") ?? NSColor.labelColor.withAlphaComponent(0.1)
    PrimitiveMotion.setInstantly { pill.backgroundColor = (color("urlPill") ?? NSColor.labelColor.withAlphaComponent(0.06)).cgColor }
    glass.set("magnifyingglass", size: m.glassSymbol, color: color("textSecondary") ?? .secondaryLabelColor)
    field.apply(text: color("textPrimary") ?? .labelColor, placeholder: tab == .emoji ? "Search emoji" : "Search icons", placeholderColor: color("placeholder") ?? .placeholderTextColor)
    field.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
    for button in tabButtons {
      button.set(selected: button.tab == tab, hover: hover, icon: color("icon") ?? .labelColor)
    }
    let searching = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    sectionBar.set(sections().map { ($0.name, $0.symbol) }, selected: searching ? nil : section, hover: hover, icon: color("icon") ?? .labelColor,
      dim: color("textTertiary") ?? .tertiaryLabelColor)
    grid.palette = IconPickerGridView.Palette(hover: hover.cgColor, icon: color("icon") ?? .labelColor)
    grid.current = state.current
    let ink = color("noGroupIconInk") ?? .tertiaryLabelColor
    var footer: [(label: String, icon: String?, symbol: String?, selected: Bool)] = []
    if state.kind == "group" { footer.append(("No Icon", m.noGroupIcon, "square.stack.fill", state.current == m.noGroupIcon)) }
    if state.current != nil { footer.append((state.kind == "profile" ? "Use Initial" : "Reset Icon", nil, nil, false)) }
    for (index, button) in footerButtons.enumerated() {
      guard index < footer.count else {
        button.isHidden = true
        continue
      }
      let item = footer[index]
      button.isHidden = false
      button.value = item.icon
      button.set(label: item.label, symbol: item.symbol, ink: ink, text: color("textPrimary") ?? .labelColor, fill: color("urlPill"), active: hover, selected: item.selected)
    }
  }

  private func refilter(scrollToTop: Bool) {
    guard state != nil else { return }
    let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      let all = sections()
      items = (all.first { $0.name == section } ?? all.first)?.entries.map(\.icon) ?? []
    } else {
      items = catalog.search(tab, query)
    }
    grid.items = items
    empty.isHidden = !items.isEmpty
    if items.isEmpty {
      let m = SidebarIconPickerMetrics.self
      empty.storage.setAttributedString(NSAttributedString(string: "No matches", attributes: [.font: NSFont.systemFont(ofSize: m.label), .foregroundColor: color("textTertiary") ?? .tertiaryLabelColor]))
      emptyHeight = empty.measure(width: m.inner - 2 * m.emptyPadding).height
      empty.needsDisplay = true
    }
    layoutPanel()
    if scrollToTop { scroll.contentView.scroll(to: .zero) }
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  var gridContentHeight: CGFloat {
    let m = SidebarIconPickerMetrics.self
    if items.isEmpty { return emptyHeight + 2 * m.emptyPadding }
    let rows = (items.count + m.columns - 1) / m.columns
    return CGFloat(rows) * m.cell
  }

  var gridHeight: CGFloat {
    let m = SidebarIconPickerMetrics.self
    return m.gridRows * m.cell
  }

  public var panelHeight: CGFloat {
    guard let state else { return 0 }
    let m = SidebarIconPickerMetrics.self
    var height = 2 * m.inset + m.search + m.gap + m.sectionBar + m.gap + gridHeight
    if m.showsFooter(state) { height += m.gap + m.footer }
    return height
  }

  public override var intrinsicContentSize: NSSize {
    embedded ? NSSize(width: SidebarIconPickerMetrics.width, height: panelHeight) : NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  public override func layout() {
    super.layout()
    layoutPanel()
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview == nil else { return }
    state = nil
    field.stringValue = ""
    grid.hovered = nil
  }

  private func layoutPanel() {
    guard let state else { return }
    let m = SidebarIconPickerMetrics.self
    let origin = embedded ? .zero : m.origin(anchor: state.anchorRect, sidebarWidth: CGFloat(state.sidebarWidth))
    let height = panelHeight
    panel.frame = NSRect(x: origin.x, y: origin.y, width: m.width, height: height)
    if embedded, frame.size != panel.frame.size { invalidateIntrinsicContentSize() }
    PrimitiveMotion.setInstantly { surface.frame = panel.bounds }
    var y = m.inset
    let pillWidth = m.inner - 2 * (m.tabGap + m.tabWidth)
    let pillFrame = NSRect(x: m.inset, y: y, width: pillWidth, height: m.search)
    PrimitiveMotion.setInstantly { pill.frame = pillFrame }
    glass.frame = NSRect(x: pillFrame.minX + m.searchPadding, y: y + (m.search - m.glass) / 2, width: m.glass, height: m.glass)
    let fieldX = glass.frame.maxX + m.fieldGap
    let fieldHeight = field.lineHeight
    field.frame = NSRect(x: fieldX, y: y + (m.search - fieldHeight) / 2, width: max(0, pillFrame.maxX - m.searchPadding - fieldX), height: fieldHeight)
    var x = pillFrame.maxX
    for button in tabButtons {
      x += m.tabGap
      button.frame = NSRect(x: x, y: y, width: m.tabWidth, height: m.search)
      x += m.tabWidth
    }
    y += m.search + m.gap
    sectionBar.frame = NSRect(x: m.inset, y: y, width: m.inner, height: m.sectionBar)
    y += m.sectionBar + m.gap
    scroll.frame = NSRect(x: m.inset, y: y, width: m.inner, height: gridHeight)
    grid.frame = NSRect(x: 0, y: 0, width: m.inner, height: max(gridHeight, gridContentHeight))
    empty.frame = NSRect(x: m.emptyPadding, y: m.emptyPadding, width: m.inner - 2 * m.emptyPadding, height: emptyHeight)
    y += gridHeight + m.gap
    let shown = footerButtons.filter { !$0.isHidden }
    guard !shown.isEmpty else { return }
    let width = (m.inner - CGFloat(shown.count - 1) * m.footerGap) / CGFloat(shown.count)
    for (index, button) in shown.enumerated() {
      button.frame = NSRect(x: m.inset + CGFloat(index) * (width + m.footerGap), y: y, width: width, height: m.footer)
    }
  }

  public func controlTextDidChange(_ obj: Notification) {
    grid.hovered = nil
    paint()
    refilter(scrollToTop: true)
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    let columns = SidebarIconPickerMetrics.columns
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      onEvent?(.close)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      let index = grid.hovered ?? 0
      if items.indices.contains(index) { choose(items[index]) }
      return true
    case #selector(NSResponder.moveDown(_:)):
      return move(grid.hovered.map { $0 + columns } ?? 0)
    case #selector(NSResponder.moveUp(_:)):
      guard let hovered = grid.hovered else { return true }
      return move(hovered - columns)
    case #selector(NSResponder.moveRight(_:)):
      guard let hovered = grid.hovered else { return false }
      return move(hovered + 1)
    case #selector(NSResponder.moveLeft(_:)):
      guard let hovered = grid.hovered else { return false }
      return move(hovered - 1)
    default:
      return false
    }
  }

  private func move(_ index: Int) -> Bool {
    guard !items.isEmpty else { return true }
    let next = min(max(0, index), items.count - 1)
    grid.hovered = next
    grid.reveal(next)
    return true
  }

  @objc private func scrolled() { grid.pointerMoved() }

  @objc private func devPointer(_ note: Notification) {
    guard let window, let screen = (note.object as? NSValue)?.pointValue else { return }
    grid.pointer(at: grid.convert(window.convertPoint(fromScreen: screen), from: nil))
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard state != nil else { return nil }
    let local = convert(point, from: superview)
    if panel.frame.contains(local) { return super.hitTest(point) }
    return !embedded && bounds.contains(local) ? self : nil
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override func mouseDown(with event: NSEvent) { pressedOutside = true }
  public override func rightMouseDown(with event: NSEvent) {}

  public override func mouseUp(with event: NSEvent) {
    guard pressedOutside else { return }
    pressedOutside = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onEvent?(.close) }
  }

  public func describe() -> [String: Any] {
    [
      "tab": tab.rawValue, "section": section ?? NSNull(), "sections": sectionNames, "query": field.stringValue, "items": items.count,
      "first": items.first ?? NSNull(),
      "panel": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
      "focused": isEditing,
      "footer": footerButtons.filter { !$0.isHidden }.map(\.label),
      "hovered": grid.hovered.map { grid.items.indices.contains($0) ? grid.items[$0] : "" } ?? NSNull(),
      "scrollY": scroll.contentView.bounds.minY,
    ]
  }
}

public final class IconPickerPanelView: NSView {
  public override var isFlipped: Bool { true }
  public override func mouseDown(with event: NSEvent) {}
  public override func mouseUp(with event: NSEvent) {}
}

final class IconPickerField: NSTextField {
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    isBezeled = false
    drawsBackground = false
    focusRingType = .none
    isEditable = true
    isSelectable = true
    usesSingleLineMode = true
    cell?.isScrollable = true
    cell?.wraps = false
    lineBreakMode = .byClipping
    font = .systemFont(ofSize: SidebarIconPickerMetrics.fieldFont)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became, let editor = currentEditor() as? NSTextView { editor.insertionPointColor = textColor ?? .labelColor }
    return became
  }

  var lineHeight: CGFloat { cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 1000)).height ?? 16 }

  func apply(text: NSColor, placeholder: String, placeholderColor: NSColor) {
    textColor = text
    (currentEditor() as? NSTextView)?.insertionPointColor = text
    placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: SidebarIconPickerMetrics.fieldFont), .foregroundColor: placeholderColor])
  }
}

final class IconPickerTabButton: NSView {
  var onPress: ((SidebarIconPickerTab) -> Void)?
  let tab: SidebarIconPickerTab
  private let plate = CALayer()
  private let symbol = SymbolView()

  override var isFlipped: Bool { true }

  init(_ tab: SidebarIconPickerTab) {
    self.tab = tab
    super.init(frame: .zero)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.searchRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(tab == .emoji ? "Emoji" : "Icons")
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(selected: Bool, hover: NSColor?, icon: NSColor) {
    PrimitiveMotion.setInstantly { plate.backgroundColor = selected ? hover?.cgColor : nil }
    symbol.set(tab == .emoji ? "face.smiling" : "star.square.on.square", size: SidebarIconPickerMetrics.tabSymbol, color: icon)
  }

  override func layout() {
    super.layout()
    let box = SidebarIconPickerMetrics.tabBox
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    symbol.frame = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(tab) }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?(tab)
    return true
  }
}

final class IconPickerFooterButton: NSView {
  var onPress: (() -> Void)?
  var value: String?
  private(set) var label = ""
  private let plate = CALayer()
  private let symbol = SymbolView()
  private let text = OnboardingTextNSView()
  private var textSize: CGSize = .zero
  private var fill: CGColor?
  private var active: CGColor?
  private var selected = false
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.searchRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    text.manager.usesFontLeading = false
    addSubview(text)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(label: String, symbol name: String?, ink: NSColor, text color: NSColor, fill: NSColor?, active: NSColor?, selected: Bool) {
    self.label = label
    self.fill = fill?.cgColor
    self.active = active?.cgColor
    self.selected = selected
    symbol.isHidden = name == nil
    if let name { symbol.set(name, size: SidebarIconPickerMetrics.footerSymbol, weight: .medium, color: ink) }
    text.storage.setAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: SidebarIconPickerMetrics.label), .foregroundColor: color]))
    textSize = text.measure(width: .greatestFiniteMagnitude)
    text.needsDisplay = true
    setAccessibilityLabel(label)
    setAccessibilitySelected(selected)
    paint()
    needsLayout = true
  }

  private func paint() {
    PrimitiveMotion.setInstantly { plate.backgroundColor = pressed || selected ? active : fill }
  }

  override func layout() {
    super.layout()
    let m = SidebarIconPickerMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    let scale = window?.backingScaleFactor ?? 2
    let lead = symbol.isHidden ? 0 : m.footerBox + m.footerInnerGap
    let start = (bounds.width - lead - (textSize.width - 1 / scale) - 0.001) / 2
    if !symbol.isHidden {
      symbol.frame = NSRect(x: (start * scale).rounded() / scale, y: (bounds.height - m.footerBox) / 2, width: m.footerBox, height: m.footerBox)
    }
    let x = ((start + lead) * scale).rounded(.down) / scale
    let y = m.textOffset(box: bounds.height, text: textSize.height, scale: scale)
    text.frame = NSRect(x: x, y: y, width: textSize.width, height: textSize.height)
  }

  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseDragged(with event: NSEvent) {
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

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


final class IconPickerSectionBar: NSView {
  var onPress: ((String) -> Void)?
  private(set) var names: [String] = []
  private var buttons: [IconPickerSectionButton] = []

  override var isFlipped: Bool { true }

  func set(_ sections: [(name: String, symbol: String)], selected: String?, hover: NSColor?, icon: NSColor, dim: NSColor) {
    names = sections.map(\.name)
    while buttons.count < sections.count {
      let button = IconPickerSectionButton()
      button.onPress = { [weak self] name in self?.onPress?(name) }
      addSubview(button)
      buttons.append(button)
    }
    for (index, button) in buttons.enumerated() {
      button.isHidden = index >= sections.count
      guard index < sections.count else { continue }
      let section = sections[index]
      button.set(title: section.name, glyph: section.symbol, selected: section.name == selected, hover: hover, color: selected == nil ? dim : icon)
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let shown = buttons.filter { !$0.isHidden }
    guard !shown.isEmpty else { return }
    let width = bounds.width / CGFloat(shown.count)
    let scale = window?.backingScaleFactor ?? 2
    for (index, button) in shown.enumerated() {
      let x = (CGFloat(index) * width * scale).rounded() / scale
      let next = (CGFloat(index + 1) * width * scale).rounded() / scale
      button.frame = NSRect(x: x, y: 0, width: next - x, height: bounds.height)
    }
  }
}

final class IconPickerSectionButton: NSView {
  var onPress: ((String) -> Void)?
  private(set) var name = ""
  private let plate = CALayer()
  private let symbol = SymbolView()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.cellRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(title: String, glyph: String, selected: Bool, hover: NSColor?, color: NSColor) {
    name = title
    PrimitiveMotion.setInstantly { plate.backgroundColor = selected ? hover?.cgColor : nil }
    symbol.set(glyph, size: SidebarIconPickerMetrics.sectionSymbol, color: color)
    setAccessibilityLabel(title)
    setAccessibilitySelected(selected)
    toolTip = title
  }

  override func layout() {
    super.layout()
    let box = SidebarIconPickerMetrics.tabBox
    PrimitiveMotion.setInstantly { plate.frame = bounds.insetBy(dx: 1, dy: 0) }
    symbol.frame = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(name) }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?(name)
    return true
  }
}

final class IconPickerGridView: NSView {
  struct Palette {
    var hover: CGColor?
    var icon: NSColor
  }

  var onChoose: ((String) -> Void)?
  var palette = Palette(hover: nil, icon: .labelColor) { didSet { symbolImages = [:]; needsDisplay = true } }
  var current: String? { didSet { if current != oldValue { needsDisplay = true } } }
  var items: [String] = [] { didSet { if items != oldValue { emojiLines = [:]; needsDisplay = true; elements = nil } } }
  var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var pressed: Int?
  private var tracking: NSTrackingArea?
  private var emojiLines: [String: (line: CTLine, size: CGSize)] = [:]
  private var symbolImages: [String: NSImage] = [:]
  private var elements: [NSAccessibilityElement]?

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  func frame(of index: Int) -> NSRect {
    let m = SidebarIconPickerMetrics.self
    return NSRect(x: CGFloat(index % m.columns) * m.cell, y: CGFloat(index / m.columns) * m.cell, width: m.cell, height: m.cell)
  }

  func reveal(_ index: Int) {
    guard items.indices.contains(index) else { return }
    scrollToVisible(frame(of: index))
  }

  override func draw(_ dirtyRect: NSRect) {
    let m = SidebarIconPickerMetrics.self
    guard !items.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
    let first = max(0, Int(dirtyRect.minY / m.cell)) * m.columns
    let last = min(items.count - 1, (Int(dirtyRect.maxY / m.cell) + 1) * m.columns - 1)
    guard first <= last else { return }
    let scale = window?.backingScaleFactor ?? 2
    for index in first...last {
      let cell = frame(of: index)
      let icon = items[index]
      if let fill = palette.hover, index == hovered || icon == current {
        context.setFillColor(fill)
        context.addPath(CGPath(roundedRect: cell, cornerWidth: m.cellRadius, cornerHeight: m.cellRadius, transform: nil))
        context.fillPath()
      }
      if m.isSymbol(icon) {
        guard let image = symbolImage(icon) else { continue }
        let size = image.size
        let x = (cell.minX + (cell.width - size.width) / 2) * scale
        let y = (cell.minY + (cell.height - size.height) / 2) * scale
        image.draw(in: NSRect(x: x.rounded() / scale, y: y.rounded() / scale, width: size.width, height: size.height), from: .zero, operation: .sourceOver,
          fraction: 1, respectFlipped: true, hints: nil)
      } else {
        let (line, size) = emojiLine(icon)
        let x = cell.minX + m.textOffset(box: cell.width, text: size.width, scale: scale)
        let y = cell.minY + m.textOffset(box: cell.height, text: size.height, scale: scale)
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
      }
    }
  }

  private func emojiLine(_ emoji: String) -> (line: CTLine, size: CGSize) {
    if let known = emojiLines[emoji] { return known }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: SidebarIconPickerMetrics.emojiFont)]))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    let made = (line, CGSize(width: width, height: ascent + descent))
    emojiLines[emoji] = made
    return made
  }

  private func symbolImage(_ icon: String) -> NSImage? {
    if let known = symbolImages[icon] { return known }
    let name = String(icon.dropFirst(SidebarIconPickerMetrics.symbolPrefix.count))
    let config = NSImage.SymbolConfiguration(pointSize: SidebarIconPickerMetrics.cellSymbol, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [palette.icon]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?.withSymbolConfiguration(config)
    symbolImages[icon] = image
    return image
  }

  func index(at point: NSPoint) -> Int? {
    let m = SidebarIconPickerMetrics.self
    guard point.x >= 0, point.y >= 0, point.x < CGFloat(m.columns) * m.cell else { return nil }
    let index = Int(point.y / m.cell) * m.columns + Int(point.x / m.cell)
    return index < items.count ? index : nil
  }

  func pointer(at point: NSPoint?) {
    guard let point, let clip = enclosingScrollView?.contentView, clip.bounds.contains(clip.convert(point, from: self)) else {
      hovered = nil
      return
    }
    hovered = index(at: point)
  }

  func pointerMoved() {
    guard let window, window.isVisible else { return }
    let location = window.mouseLocationOutsideOfEventStream
    pointer(at: convert(location, from: nil))
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
  override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovered = nil }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) { pressed = index(at: convert(event.locationInWindow, from: nil)) }

  override func mouseUp(with event: NSEvent) {
    defer { pressed = nil }
    guard let pressed, pressed == index(at: convert(event.locationInWindow, from: nil)) else { return }
    onChoose?(items[pressed])
  }

  override func isAccessibilityElement() -> Bool { false }

  override func accessibilityChildren() -> [Any]? {
    if let elements { return elements }
    let made = items.enumerated().map { index, icon -> NSAccessibilityElement in
      let label = SidebarIconPickerMetrics.isSymbol(icon) ? String(icon.dropFirst(SidebarIconPickerMetrics.symbolPrefix.count)) : icon
      let element = IconPickerCellElement(icon: icon) { [weak self] in self?.onChoose?(icon) }
      element.setAccessibilityLabel(label)
      element.setAccessibilityRole(.button)
      element.setAccessibilityParent(self)
      element.setAccessibilityFrameInParentSpace(frame(of: index))
      return element
    }
    elements = made
    return made
  }
}

final class IconPickerCellElement: NSAccessibilityElement {
  let icon: String
  private let press: () -> Void

  init(icon: String, press: @escaping () -> Void) {
    self.icon = icon
    self.press = press
    super.init()
  }

  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}
