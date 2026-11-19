import AppKit
import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct SplitEmptySuggestion: Equatable, Sendable {
  public var tabId: String
  public var label: String
  public var detail: String
  public var url: String
  public var favicon: String?
  public var customIcon: String?
  public var profileId: String
}

public enum SplitEmptyState {
  public static let limit = 5

  public static func label(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if tab.url.isEmpty { return "New Tab" }
    if let app = appUrlOrigin(tab.url) { return app }
    guard let url = URL(string: tab.url) else { return tab.title.isEmpty ? tab.url : tab.title }
    if url.scheme == "file" {
      return tab.title.isEmpty ? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : tab.title
    }
    let host = displayHost(url.host ?? "").replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    if !host.isEmpty { return host }
    return tab.title.isEmpty ? tab.url : tab.title
  }

  public static func suggestions(_ state: BrowserState, tabId: String) -> [SplitEmptySuggestion] {
    guard let tab = state.tabs[tabId], let window = state.windows[tab.windowId] else { return [] }
    let inSplit = Set(state.splits.values.first { $0.tabIds.contains(tabId) }?.tabIds ?? [tabId])
    return window.tabIds.compactMap { state.tabs[$0] }
      .filter { !$0.url.isEmpty && $0.profileId == tab.profileId && !inSplit.contains($0.id) }
      .enumerated().sorted { $0.element.lastActiveAt != $1.element.lastActiveAt ? $0.element.lastActiveAt > $1.element.lastActiveAt : $0.offset < $1.offset }
      .prefix(limit)
      .map { _, t in
        SplitEmptySuggestion(tabId: t.id, label: label(t), detail: t.title, url: t.url, favicon: t.favicon, customIcon: t.customIcon, profileId: t.profileId)
      }
  }
}

@MainActor
public final class SplitEmptyStateView: NSView {
  static let maxWidth: CGFloat = 420
  static let rowHeight: CGFloat = 36

  public var onNavigate: ((String) -> Void)?
  public var onReplace: ((String) -> Void)?
  public var favicons: SidebarFavicons? {
    didSet { rows.forEach { $0.icon.favicons = favicons } }
  }
  public var theme = SplitChromeTheme.fallback { didSet { if theme != oldValue { paint() } } }
  public private(set) var typing = false
  private var suggestions: [SplitEmptySuggestion] = []
  private let card = NSView()
  private let title = NSTextField(labelWithString: "Add a tab to this Split View")
  private let search = SplitEmptyRow()
  private let field = SplitEmptyField()
  private let fieldBack = NSView()
  private let fieldGlyph = NSImageView()
  private var rows: [SplitEmptyRow] = []

  public override var isFlipped: Bool { true }

  public init(focused: Bool) {
    super.init(frame: .zero)
    typing = focused
    card.wantsLayer = true
    card.layer?.cornerRadius = 16
    card.layer?.cornerCurve = .continuous
    card.layer?.borderWidth = 0.5
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    search.symbol = "magnifyingglass"
    search.label = "Search or Ask a Question"
    search.secondary = true
    search.onPress = { [weak self] in self?.setTyping(true) }
    fieldBack.wantsLayer = true
    fieldBack.layer?.cornerRadius = 9
    fieldBack.layer?.cornerCurve = .continuous
    fieldGlyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    field.font = .systemFont(ofSize: 14)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.cell?.isScrollable = true
    field.target = self
    field.action = #selector(submit)
    field.onEscape = { [weak self] in
      self?.field.stringValue = ""
      self?.setTyping(false)
    }
    for view in [title, search, fieldBack, fieldGlyph, field] { card.addSubview(view) }
    addSubview(card)
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: [SplitEmptySuggestion]) {
    guard next != suggestions else { return }
    suggestions = next
    while rows.count > next.count { rows.removeLast().removeFromSuperview() }
    while rows.count < next.count {
      let row = SplitEmptyRow()
      row.icon.favicons = favicons
      rows.append(row)
      card.addSubview(row)
    }
    for (row, s) in zip(rows, next) {
      row.label = s.label
      row.detail = s.detail
      row.iconSpec = TabIconSpec(url: s.url, favicon: s.favicon, customIcon: s.customIcon, profileId: s.profileId)
      let id = s.tabId
      row.onPress = { [weak self] in self?.onReplace?(id) }
    }
    paint()
    needsLayout = true
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if typing { window?.makeFirstResponder(field) }
  }

  private func setTyping(_ on: Bool) {
    guard on != typing else { return }
    typing = on
    needsLayout = true
    if on { window?.makeFirstResponder(field) }
  }

  @objc private func submit() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { onNavigate?(text) }
  }

  public override func layout() {
    super.layout()
    let width = min(Self.maxWidth, max(0, bounds.width - 32))
    title.sizeToFit()
    var y: CGFloat = 10 + 4
    title.frame = CGRect(x: 16, y: y, width: width - 32, height: title.frame.height)
    y = title.frame.maxY + 10
    let inner = CGRect(x: 6, y: y, width: width - 12, height: Self.rowHeight)
    search.isHidden = typing
    fieldBack.isHidden = !typing
    fieldGlyph.isHidden = !typing
    field.isHidden = !typing
    search.frame = inner
    fieldBack.frame = inner
    fieldGlyph.frame = CGRect(x: inner.minX + 10, y: inner.midY - 8, width: 16, height: 16)
    let fieldHeight = ceil(field.intrinsicContentSize.height)
    field.frame = CGRect(x: fieldGlyph.frame.maxX + 9, y: inner.midY - fieldHeight / 2, width: inner.maxX - 10 - fieldGlyph.frame.maxX - 9, height: fieldHeight)
    y = inner.maxY + (rows.isEmpty ? 0 : 6)
    for row in rows {
      row.frame = CGRect(x: 6, y: y, width: width - 12, height: Self.rowHeight)
      y += Self.rowHeight
    }
    let height = y + 10
    card.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
  }

  private func paint() {
    let dark = theme.dark
    card.layer?.backgroundColor = (dark ? NSColor(srgbRed: 34 / 255, green: 32 / 255, blue: 33 / 255, alpha: 0.92) : NSColor(white: 1, alpha: 0.92)).cgColor
    card.layer?.borderColor = theme.color("ntpBarBorder", dark: "rgba(120,125,134,0.32)", light: "rgba(0,0,0,0.07)").cgColor
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.08)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    card.shadow = shadow
    title.textColor = theme.textPrimary
    let hover = theme.color("rowHover", dark: "rgba(255,255,255,0.07)", light: "rgba(15,24,44,0.05)")
    fieldBack.layer?.backgroundColor = hover.cgColor
    fieldGlyph.contentTintColor = theme.textSecondary
    field.textColor = theme.textPrimary
    field.placeholderAttributedString = NSAttributedString(
      string: "Search or Ask a Question",
      attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: theme.color("placeholder", dark: "#FFFFFF87", light: "#00000066")])
    for row in [search] + rows { row.theme = theme }
  }
}

@MainActor
final class SplitEmptyField: NSTextField {
  var onEscape: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    contentType = .URL
  }

  required init?(coder: NSCoder) { fatalError() }

  override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class SplitEmptyRow: NSView {
  let icon = TabIconView()
  private let glyph = NSImageView()
  private let text = NSTextField(labelWithString: "")
  private var hovered = false
  private var pressed = false
  var symbol: String? { didSet { glyph.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) } } }
  var label = "" { didSet { if label != oldValue { paint() } } }
  var detail = "" { didSet { if detail != oldValue { paint() } } }
  var secondary = false
  var iconSpec: TabIconSpec? { didSet { if iconSpec != oldValue { paint() } } }
  var theme = SplitChromeTheme.fallback { didSet { paint() } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    text.lineBreakMode = .byTruncatingTail
    text.maximumNumberOfLines = 1
    for view in [icon, glyph, text] as [NSView] { addSubview(view) }
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let box = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
    icon.frame = box
    glyph.frame = box
    let height = ceil(text.intrinsicContentSize.height)
    text.frame = CGRect(x: box.maxX + 9, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - box.maxX - 9 - 10), height: height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
  override func mouseExited(with event: NSEvent) { hovered = false; paint() }
  override func mouseDown(with event: NSEvent) { pressed = true; paint() }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    paint()
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  override func accessibilityLabel() -> String? { label }

  private func paint() {
    let dark = theme.dark
    let fill: NSColor = pressed
      ? theme.color("rowSelected", dark: "rgba(255,255,255,0.22)", light: "rgba(15,24,44,0.08)")
      : hovered ? theme.color("rowHover", dark: "rgba(255,255,255,0.07)", light: "rgba(15,24,44,0.05)") : .clear
    layer?.backgroundColor = fill.cgColor
    glyph.contentTintColor = theme.textSecondary
    glyph.isHidden = symbol == nil
    icon.isHidden = iconSpec == nil
    if let iconSpec {
      var host = SidebarHostState(profileId: iconSpec.profileId, dark: dark)
      host.theme = theme.tokens
      icon.set(iconSpec, palette: SidebarPalette(host))
    }
    let font = NSFont.systemFont(ofSize: 13)
    let line = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: secondary ? theme.textSecondary : theme.textPrimary])
    if !detail.isEmpty {
      line.append(NSAttributedString(string: "  " + detail, attributes: [.font: font, .foregroundColor: theme.color("textTertiary", dark: "#FFFFFF59", light: "#00000059")]))
    }
    text.attributedStringValue = line
  }
}
