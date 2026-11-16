import AppKit

struct ProfileIconCatalog {
  let emoji: IconCatalog
  let symbols: [ProfileSymbol]

  init(emoji: IconCatalog = .shared, hasSymbol: (String) -> Bool = IconCatalog.systemHasSymbol) {
    self.emoji = emoji
    symbols = ProfileIcons.symbols.filter { hasSymbol($0.name) }
  }

  var categories: [IconCatalogSection] { emoji.emoji }

  func entries(tab: SidebarIconPickerTab, query: String, category: String?) -> [IconCatalogEntry] {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    if tab == .symbols {
      return symbols.compactMap { symbol in
        let words = "\(symbol.title) \(symbol.name.replacingOccurrences(of: ".", with: " "))".lowercased()
        guard terms.allSatisfy({ words.contains($0) }) else { return nil }
        return IconCatalogEntry(icon: ProfileIcons.symbolPrefix + symbol.name, words: symbol.title)
      }
    }
    if terms.isEmpty { return (categories.first { $0.name == category } ?? categories.first)?.entries ?? [] }
    let names = Dictionary(emoji.emoji.flatMap(\.entries).map { ($0.icon, $0.words) }, uniquingKeysWith: { first, _ in first })
    return emoji.search(.emoji, query).map { IconCatalogEntry(icon: $0, words: names[$0] ?? $0) }
  }

  static func label(_ entry: IconCatalogEntry) -> String {
    entry.words.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? entry.icon
  }
}

enum ProfileIconPickerMetrics {
  static let width: CGFloat = 342
  static let height: CGFloat = 340
  static let padding: CGFloat = 12
  static let columns = 8
  static let cellHeight: CGFloat = 34
  static let gap: CGFloat = 2
  static let inner = width - 2 * padding
  static let cellWidth = (inner - CGFloat(columns - 1) * gap) / CGFloat(columns)
}

@MainActor
final class ProfileIconPopover: NSObject, NSPopoverDelegate {
  private let popover = NSPopover()
  private let picker = ProfileIconPickerView()
  var isShown: Bool { popover.isShown }

  override init() {
    super.init()
    popover.behavior = .transient
    popover.animates = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"
    popover.delegate = self
    let controller = NSViewController()
    controller.view = picker
    popover.contentViewController = controller
    popover.contentSize = picker.intrinsicContentSize
  }

  func show(profileId: String, current: String?, dark: Bool, tint: NSColor, relativeTo rect: NSRect, of view: NSView, onPick: @escaping (String?) -> Void) {
    guard view.window != nil else { return }
    close()
    picker.configure(profileId: profileId, current: current, dark: dark, tint: tint, reset: true)
    picker.onEvent = { [weak self] event in
      switch event {
      case .choose(let icon): onPick(icon)
      case .close: self?.close()
      }
    }
    popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
    picker.focus()
  }

  func close() { popover.close() }

  func popoverDidClose(_ notification: Notification) { picker.onEvent = nil }
}

@MainActor
final class ProfileIconPickerView: NSView, NSSearchFieldDelegate {
  var onEvent: ((SidebarIconPickerView.Event) -> Void)?
  var catalog = ProfileIconCatalog()
  private(set) var tab: SidebarIconPickerTab = .symbols
  private(set) var category: String?
  private(set) var current: String?
  private(set) var items: [IconCatalogEntry] = []
  private(set) var profileId: String?
  private let tabs = NSSegmentedControl(labels: ["Icon", "Emoji"], trackingMode: .selectOne, target: nil, action: nil)
  private let clear = ProfilePickerButton()
  private let search = NSSearchField()
  private let scroll = NSScrollView()
  private let grid = ProfilePickerGrid()
  private let empty = NSTextField(labelWithString: "No matches")
  private var cells: [ProfilePickerButton] = []
  private var categories: [ProfilePickerButton] = []
  private var tint = NSColor.controlAccentColor

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: ProfileIconPickerMetrics.width, height: ProfileIconPickerMetrics.height) }
  var query: String { search.stringValue }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    setAccessibilityElement(false)
    setAccessibilityLabel("Profile icon picker")
    tabs.target = self
    tabs.action = #selector(tabChanged)
    tabs.selectedSegment = 0
    tabs.setAccessibilityLabel("Icon kind")
    addSubview(tabs)
    clear.set(symbol: "trash", title: "", label: "Use the dot", color: .secondaryLabelColor, selected: false)
    clear.onPick = { [weak self] in self?.choose(nil) }
    addSubview(clear)
    search.placeholderString = "Search icons"
    search.setAccessibilityLabel("Search icons")
    search.delegate = self
    search.sendsSearchStringImmediately = true
    addSubview(search)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = grid
    addSubview(scroll)
    empty.alignment = .center
    empty.textColor = .secondaryLabelColor
    empty.font = .systemFont(ofSize: 13)
    grid.addSubview(empty)
    self.frame.size = intrinsicContentSize
  }

  required init?(coder: NSCoder) { fatalError() }

  func configure(profileId: String, current: String?, dark: Bool, tint: NSColor, reset: Bool = false) {
    let fresh = self.profileId != profileId
    self.profileId = profileId
    self.current = current
    self.tint = tint
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    if fresh || reset {
      tab = current != nil && ProfileIcons.symbol(current) == nil ? .emoji : .symbols
      search.stringValue = ""
      category = catalog.categories.first { section in section.entries.contains { $0.icon == current } }?.name ?? catalog.categories.first?.name
    }
    rebuildCategories()
    refresh()
  }

  func focus() { window?.makeFirstResponder(search) }

  func select(_ tab: SidebarIconPickerTab) {
    self.tab = tab
    refresh()
  }

  func show(category: String) {
    guard catalog.categories.contains(where: { $0.name == category }) else { return }
    self.category = category
    search.stringValue = ""
    refresh()
  }

  func setQuery(_ query: String) {
    search.stringValue = query
    refresh()
  }

  func choose(_ icon: String?) {
    current = icon
    updateSelection()
    onEvent?(.choose(icon))
  }

  override func cancelOperation(_ sender: Any?) { onEvent?(.close) }

  func controlTextDidChange(_ obj: Notification) { refresh() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onEvent?(.close)
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)), let first = items.first {
      choose(first.icon)
      return true
    }
    return false
  }

  @objc private func tabChanged() { select(tabs.selectedSegment == 0 ? .symbols : .emoji) }

  private func rebuildCategories() {
    for button in categories { button.removeFromSuperview() }
    categories = catalog.categories.map { section in
      let button = ProfilePickerButton()
      button.set(symbol: section.symbol.isEmpty ? "circle" : section.symbol, title: "", label: section.name, color: .secondaryLabelColor, selected: false)
      button.onPick = { [weak self] in self?.show(category: section.name) }
      addSubview(button)
      return button
    }
  }

  private func refresh() {
    tabs.selectedSegment = tab == .symbols ? 0 : 1
    search.placeholderString = tab == .symbols ? "Search icons" : "Search emoji"
    search.setAccessibilityLabel(search.placeholderString)
    items = catalog.entries(tab: tab, query: search.stringValue, category: category)
    for button in cells { button.removeFromSuperview() }
    cells = items.map { entry in
      let button = ProfilePickerButton()
      let symbol = ProfileIcons.symbol(entry.icon)
      button.set(symbol: symbol, title: symbol == nil ? entry.icon : "", label: ProfileIconCatalog.label(entry), color: tint, selected: entry.icon == current)
      button.onPick = { [weak self] in self?.choose(entry.icon) }
      grid.addSubview(button)
      return button
    }
    empty.isHidden = !items.isEmpty
    updateSelection()
    needsLayout = true
    layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func updateSelection() {
    for (index, button) in cells.enumerated() { button.selected = items[index].icon == current }
    let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    for (index, button) in categories.enumerated() {
      button.selected = !searching && catalog.categories[index].name == category
      button.isHidden = tab != .emoji
    }
    clear.selected = current == nil
  }

  override func layout() {
    super.layout()
    let m = ProfileIconPickerMetrics.self
    tabs.frame = NSRect(x: (bounds.width - 180) / 2 - 16, y: m.padding, width: 180, height: 32)
    clear.frame = NSRect(x: tabs.frame.maxX + 8, y: m.padding + 1, width: 30, height: 30)
    search.frame = NSRect(x: m.padding, y: 54, width: m.inner, height: 30)
    let categoryHeight: CGFloat = tab == .emoji ? 34 : 0
    scroll.frame = NSRect(x: m.padding, y: 94, width: m.inner, height: max(0, bounds.height - 94 - m.padding - categoryHeight))
    let rows = (items.count + m.columns - 1) / m.columns
    grid.frame = NSRect(x: 0, y: 0, width: m.inner, height: max(scroll.contentSize.height, CGFloat(rows) * (m.cellHeight + m.gap)))
    for (index, button) in cells.enumerated() {
      button.frame = NSRect(x: CGFloat(index % m.columns) * (m.cellWidth + m.gap), y: CGFloat(index / m.columns) * (m.cellHeight + m.gap), width: m.cellWidth, height: m.cellHeight)
    }
    empty.frame = NSRect(x: 0, y: 12, width: m.inner, height: 24)
    let categoryWidth = m.inner / CGFloat(max(1, categories.count))
    for (index, button) in categories.enumerated() {
      button.frame = NSRect(x: m.padding + CGFloat(index) * categoryWidth, y: bounds.height - m.padding - 28, width: categoryWidth - 2, height: 28)
    }
  }
}

private final class ProfilePickerGrid: NSView {
  override var isFlipped: Bool { true }
}

private final class ProfilePickerButton: NSButton {
  var onPick: (() -> Void)?
  var selected = false { didSet { repaint() } }
  private var hovered = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    isBordered = false
    setButtonType(.momentaryChange)
    imagePosition = .imageOnly
    font = .systemFont(ofSize: 20)
    layer?.cornerRadius = 7
    target = self
    action = #selector(pick)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(symbol: String?, title: String, label: String, color: NSColor, selected: Bool) {
    self.title = title
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [color])))
      imagePosition = .imageOnly
    } else {
      image = nil
      imagePosition = .noImage
    }
    contentTintColor = color
    setAccessibilityLabel(label)
    toolTip = label
    self.selected = selected
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; repaint() }
  override func mouseExited(with event: NSEvent) { hovered = false; repaint() }

  private func repaint() {
    state = selected ? .on : .off
    setAccessibilitySelected(selected)
    layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : hovered ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
  }

  @objc private func pick() { onPick?() }
}
