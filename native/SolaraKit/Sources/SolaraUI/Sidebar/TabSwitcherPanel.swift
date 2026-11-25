import AppKit
import QuartzCore

public struct TabSwitcherState: Decodable, Equatable, Sendable {
  public struct Row: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var display: String
    public var favicon: String?
    public var icon: String?
    public var profileId: String

    public init(id: String, title: String, url: String, display: String = "", favicon: String? = nil, icon: String? = nil, profileId: String = "") {
      self.id = id
      self.title = title
      self.url = url
      self.display = display
      self.favicon = favicon
      self.icon = icon
      self.profileId = profileId
    }
  }

  public var ids: [String]
  public var index: Int
  public var rows: [String: Row]
  public var dark: Bool
  public var theme: [String: String]

  public init(ids: [String], index: Int, rows: [String: Row], dark: Bool, theme: [String: String]) { self.ids = ids; self.index = index; self.rows = rows; self.dark = dark; self.theme = theme }
}

public enum TabSwitcherMetrics {
  public static let width: CGFloat = 400
  public static let row: CGFloat = 40
  public static let maxRows = 9
  public static let padding: CGFloat = 8
  public static let estimatedChrome: CGFloat = 16 + 26
  public static let minTop: CGFloat = 40
  public static let lift: CGFloat = 40
  public static let titleInset: CGFloat = 8
  public static let titleTop: CGFloat = 2
  public static let titleBottom: CGFloat = 6
  public static let titleFont: CGFloat = 11
  public static let rowRadius: CGFloat = 10
  public static let rowPadding: CGFloat = 10
  public static let gap: CGFloat = 10
  public static let icon: CGFloat = 18
  public static let titleSize: CGFloat = 13
  public static let titleHeight: CGFloat = 17
  public static let urlSize: CGFloat = 11
  public static let urlHeight: CGFloat = 14
  public static let outline: CGFloat = 0.5
  public static let radius: CGFloat = 16
  public static let border: CGFloat = 0.5
  public static let shadowRadius: CGFloat = 28
  public static let shadowOffset: CGFloat = 12

  static var headerHeight: CGFloat { titleTop + TabSearchMetrics.lineHeight(.systemFont(ofSize: titleFont, weight: .semibold)) + titleBottom }

  public static func start(index: Int, count: Int) -> Int {
    max(0, min(index - maxRows / 2, count - maxRows))
  }

  public static func shown(index: Int, count: Int) -> Range<Int> {
    let first = start(index: index, count: count)
    return first..<min(count, first + maxRows)
  }

  public static func frame(windowWidth: CGFloat, windowHeight: CGFloat, rows: Int) -> CGRect {
    let estimate = CGFloat(rows) * row + estimatedChrome
    let height = padding * 2 + headerHeight + CGFloat(rows) * row
    return CGRect(x: (windowWidth - width) / 2, y: max(minTop, (windowHeight - estimate) / 2 - lift), width: width, height: height)
  }
}

public enum TabSwitcherEvent: Equatable, Sendable {
  case hover(Int)
  case leave(Int)
  case commit(Int)
}

public final class TabSwitcherPanelView: NSView {
  public var onEvent: ((TabSwitcherEvent) -> Void)?
  public private(set) var state: TabSwitcherState?
  public let favicons: SidebarFavicons

  private let surface = TabSearchSurfaceView()
  private let title = NSTextField(labelWithString: "Recent Tabs")
  private var rowViews: [TabSwitcherRowView] = []

  public override var isFlipped: Bool { true }

  public init(favicons: SidebarFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    addSubview(surface)
    title.font = .systemFont(ofSize: TabSwitcherMetrics.titleFont, weight: .semibold)
    addSubview(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var shownIds: [String] { rowViews.compactMap(\.tabId) }

  public func set(_ next: TabSwitcherState, windowSize: CGSize) {
    state = next
    var host = SidebarHostState(profileId: "", dark: next.dark)
    host.theme = next.theme
    let palette = SidebarPalette(host)
    func color(_ key: String) -> NSColor? { next.theme[key].flatMap { CSSColor($0)?.ns } }
    surface.paint(
      fill: color("panel") ?? (next.dark ? .black : .white), border: color("panelBorder") ?? .clear, shadowOpacity: Double(next.theme["panelShadowOpacity"] ?? "") ?? 0,
      shadowRadius: TabSwitcherMetrics.shadowRadius, shadowOffset: TabSwitcherMetrics.shadowOffset)
    title.textColor = palette.textTertiary
    let range = TabSwitcherMetrics.shown(index: next.index, count: next.ids.count)
    let shown = range.compactMap { i in next.rows[next.ids[i]].map { (index: i, row: $0) } }
    while rowViews.count < shown.count {
      let row = TabSwitcherRowView()
      row.onEvent = { [weak self] event in self?.onEvent?(event) }
      addSubview(row)
      rowViews.append(row)
    }
    while rowViews.count > shown.count {
      let gone = rowViews.removeLast()
      if let index = gone.index { onEvent?(.leave(index)) }
      gone.removeFromSuperview()
    }
    for (view, item) in zip(rowViews, shown) {
      view.icon.favicons = favicons
      view.set(item.row, index: item.index, focused: item.index == next.index, palette: palette, focusFill: color("switcherFocus") ?? (next.dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.18)), outline: color("switcherOutline") ?? (next.dark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.1)))
    }
    frame = TabSwitcherMetrics.frame(windowWidth: windowSize.width, windowHeight: windowSize.height, rows: range.count)
    needsLayout = true
  }

  public override func layout() {
    super.layout()
    let m = TabSwitcherMetrics.self
    surface.frame = bounds
    let lineHeight = m.headerHeight - m.titleTop - m.titleBottom
    title.frame = NSRect(x: m.padding + m.titleInset, y: m.padding + m.titleTop, width: max(0, bounds.width - 2 * (m.padding + m.titleInset)), height: lineHeight)
    for (i, view) in rowViews.enumerated() {
      view.frame = NSRect(x: m.padding, y: m.padding + m.headerHeight + CGFloat(i) * m.row, width: bounds.width - 2 * m.padding, height: m.row)
    }
  }
}

final class TabSwitcherRowView: NSView {
  var onEvent: ((TabSwitcherEvent) -> Void)?
  let icon = TabIconView()
  private(set) var index: Int?
  private(set) var tabId: String?
  private let plate = CALayer()
  private let title = FadeLabel(fontSize: TabSwitcherMetrics.titleSize)
  private let url = FadeLabel(fontSize: TabSwitcherMetrics.urlSize)
  private var tracking: NSTrackingArea?
  private var inside = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = TabSwitcherMetrics.rowRadius
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    for view in [icon, title, url] as [NSView] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ row: TabSwitcherState.Row, index: Int, focused: Bool, palette: SidebarPalette, focusFill: NSColor?, outline: NSColor?) {
    if let old = self.index, old != index, inside { onEvent?(.leave(old)) }
    self.index = index
    tabId = row.id
    icon.set(TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId, size: TabSwitcherMetrics.icon), palette: palette)
    title.font = .monospacedDigitSystemFont(ofSize: TabSwitcherMetrics.titleSize, weight: focused ? .medium : .regular)
    title.text = row.title
    title.color = palette.textPrimary
    url.isHidden = row.url.isEmpty
    url.text = row.display
    url.color = palette.textSecondary
    setAccessibilityLabel(row.title)
    PrimitiveMotion.setInstantly {
      plate.backgroundColor = focused ? focusFill?.cgColor : nil
      plate.borderWidth = focused ? TabSwitcherMetrics.outline : 0
      plate.borderColor = outline?.cgColor
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let m = TabSwitcherMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    icon.frame = NSRect(x: m.rowPadding, y: (bounds.height - m.icon) / 2, width: m.icon, height: m.icon)
    let x = m.rowPadding + m.icon + m.gap
    let width = max(0, bounds.width - x - m.rowPadding)
    let height = m.titleHeight + (url.isHidden ? 0 : m.urlHeight)
    let top = (bounds.height - height) / 2
    title.frame = NSRect(x: x, y: top, width: width, height: m.titleHeight)
    url.frame = NSRect(x: x, y: top + m.titleHeight, width: width, height: m.urlHeight)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    inside = true
    if let index { onEvent?(.hover(index)) }
  }

  override func mouseMoved(with event: NSEvent) {
    if let index { onEvent?(.hover(index)) }
  }

  override func mouseExited(with event: NSEvent) {
    inside = false
    if let index { onEvent?(.leave(index)) }
  }

  override func mouseDown(with event: NSEvent) {
    if let index { onEvent?(.commit(index)) }
  }

  override func accessibilityPerformPress() -> Bool {
    if let index { onEvent?(.commit(index)) }
    return true
  }
}
