import AppKit
import QuartzCore

public struct SidebarFolderPeekState: Decodable, Equatable, Sendable {
  public struct Row: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var favicon: String?
    public var icon: String?
    public var profileId: String
  }

  public var folderId: String
  public var title: String
  public var rows: [Row]
  public var more: String?
  public var anchor: [Double]
  public var dark: Bool
  public var shadowOpacity: Double
  public var theme: [String: String]

  public var anchorRect: CGRect {
    anchor.count == 4 ? CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]) : .zero
  }
}

public enum SidebarFolderPeekMetrics {
  public static let width: CGFloat = 264
  static let padding: CGFloat = 10
  static let border: CGFloat = 0.5
  static let radius: CGFloat = 12
  static let textIndent: CGFloat = 4
  static let titleGap: CGFloat = 4
  static let moreGap: CGFloat = 4
  static let row: CGFloat = 28
  static let rowRadius: CGFloat = 7
  static let rowPadding: CGFloat = 5
  static let icon: CGFloat = 14
  static let iconGap: CGFloat = 7
  static let label: CGFloat = 17
  static var inset: CGFloat { padding + border }
  static var inner: CGFloat { width - 2 * inset }
}

public final class SidebarFolderPeekView: NSView {
  public var onChoose: ((String) -> Void)?
  public var onPointer: ((Bool) -> Void)?
  public private(set) var state: SidebarFolderPeekState?
  public let favicons: SidebarFavicons
  private let surface = SurfaceLayer()
  private let title = OnboardingTextNSView()
  private let more = OnboardingTextNSView()
  private var rowViews: [FolderPeekRowView] = []
  private var titleHeight: CGFloat = 0
  private var moreHeight: CGFloat = 0
  private var tracking: NSTrackingArea?
  private var inside = false

  public override var isFlipped: Bool { true }

  public init(favicons: SidebarFavicons) {
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    surface.radius = SidebarFolderPeekMetrics.radius
    surface.border = SidebarFolderPeekMetrics.border
    surface.glowColor = .black
    surface.glowRadius = 16
    surface.glowOffset = CGSize(width: 0, height: 6)
    layer?.addSublayer(surface)
    for text in [title, more] {
      text.manager.usesFontLeading = false
      addSubview(text)
    }
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarFolderPeekState) {
    state = next
    var host = SidebarHostState(profileId: "", dark: next.dark)
    host.theme = next.theme
    let palette = SidebarPalette(host)
    func color(_ key: String) -> NSColor? { next.theme[key].flatMap { CSSColor($0)?.ns } }
    surface.fill = color("panel")
    surface.borderTint = color("panelBorder")
    surface.glowOpacity = next.shadowOpacity * 0.8
    let m = SidebarFolderPeekMetrics.self
    title.storage.setAttributedString(Self.text(next.title, size: 12, weight: .semibold, color: palette.textSecondary))
    titleHeight = title.measure(width: m.inner - m.textIndent).height
    title.needsDisplay = true
    more.isHidden = next.more == nil
    more.storage.setAttributedString(Self.text(next.more ?? "", size: 11.5, weight: .regular, color: palette.textTertiary))
    moreHeight = next.more == nil ? 0 : more.measure(width: m.inner - m.textIndent).height
    more.needsDisplay = true
    while rowViews.count < next.rows.count {
      let row = FolderPeekRowView()
      row.icon.favicons = favicons
      row.onPress = { [weak self, weak row] in
        guard let self, let id = row?.tabId else { return }
        self.onChoose?(id)
      }
      addSubview(row)
      rowViews.append(row)
    }
    while rowViews.count > next.rows.count { rowViews.removeLast().removeFromSuperview() }
    for (view, row) in zip(rowViews, next.rows) { view.set(row, palette: palette) }
    setFrameSize(NSSize(width: m.width, height: height))
    needsLayout = true
  }

  public var height: CGFloat {
    guard let state else { return 0 }
    let m = SidebarFolderPeekMetrics.self
    var h = m.inset * 2 + titleHeight + m.titleGap + CGFloat(state.rows.count) * m.row
    if state.more != nil { h += m.moreGap + moreHeight }
    return h
  }

  public override func layout() {
    super.layout()
    let m = SidebarFolderPeekMetrics.self
    PrimitiveMotion.setInstantly { surface.frame = bounds }
    var y = m.inset
    title.frame = NSRect(x: m.inset + m.textIndent, y: y, width: m.inner - m.textIndent, height: titleHeight)
    y += titleHeight + m.titleGap
    for row in rowViews {
      row.frame = NSRect(x: m.inset, y: y, width: m.inner, height: m.row)
      y += m.row
    }
    more.frame = NSRect(x: m.inset + m.textIndent, y: y + m.moreGap, width: m.inner - m.textIndent, height: moreHeight)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(isHitBy(event)) }
  public override func mouseExited(with event: NSEvent) { pointer(false) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { pointer(false) }
  }

  @objc private func devPointer(_ note: Notification) {
    pointer(DevPointer.inside(self, note))
    for row in rowViews { row.hovered = DevPointer.inside(row, note) }
  }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func mouseDown(with event: NSEvent) {}

  private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakStrategy = []
    return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
  }
}

final class FolderPeekRowView: NSView {
  var onPress: (() -> Void)?
  let icon = TabIconView()
  private(set) var tabId: String?
  private let plate = CALayer()
  private let label = FadeLabel(fontSize: 12.5)
  private var tracking: NSTrackingArea?
  private var hoverFill: CGColor?
  var hovered = false { didSet { if hovered != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarFolderPeekMetrics.rowRadius
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    addSubview(icon)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ row: SidebarFolderPeekState.Row, palette: SidebarPalette) {
    tabId = row.id
    var spec = TabIconSpec(url: row.url, favicon: row.favicon, customIcon: row.icon, profileId: row.profileId)
    spec.size = SidebarFolderPeekMetrics.icon
    icon.set(spec, palette: palette)
    label.text = row.title
    label.color = palette.textTab
    hoverFill = palette.rowHover.cgColor
    setAccessibilityLabel(row.title)
    paint()
  }

  override func layout() {
    super.layout()
    let m = SidebarFolderPeekMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    icon.frame = NSRect(x: m.rowPadding, y: (bounds.height - m.icon) / 2, width: m.icon, height: m.icon)
    let x = m.rowPadding + m.icon + m.iconGap
    label.frame = NSRect(x: x, y: (bounds.height - m.label) / 2, width: max(0, bounds.width - x - m.rowPadding), height: m.label)
  }

  private func paint() {
    PrimitiveMotion.setInstantly { plate.backgroundColor = hovered ? hoverFill : nil }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = isHitBy(event) }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}
