import AppKit
import QuartzCore

public struct ShareTabSource: Decodable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var url: String
  public var favicon: String?
  public var profileId: String
  public var current: Bool

  public init(id: String, title: String, url: String, favicon: String?, profileId: String, current: Bool) {
    self.id = id
    self.title = title
    self.url = url
    self.favicon = favicon
    self.profileId = profileId
    self.current = current
  }
}

public struct ShareScreenSource: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var size: String?
  public var aspect: Double

  public init(id: String, name: String, size: String?, aspect: Double) {
    self.id = id
    self.name = name
    self.size = size
    self.aspect = aspect
  }
}

public struct ShareWindowSource: Decodable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var app: String?
  public var icon: String?

  public init(id: String, title: String, app: String?, icon: String?) {
    self.id = id
    self.title = title
    self.app = app
    self.icon = icon
  }
}

public struct ShareAudioState: Decodable, Equatable, Sendable {
  public var label: String
  public var value: Bool

  public init(label: String, value: Bool) {
    self.label = label
    self.value = value
  }
}

public struct SharePickerState: Decodable, Equatable, Sendable {
  public var requestId: String
  public var tabId: String
  public var title: String
  public var subtitle: String
  public var tabs: [ShareTabSource]
  public var screens: [ShareScreenSource]
  public var windows: [ShareWindowSource]
  public var selected: String?
  public var valid: Bool
  public var audio: ShareAudioState?
  public var tileWidth: Double
  public var theme: MediaThemeState

  public init(requestId: String, tabId: String, title: String, subtitle: String, tabs: [ShareTabSource], screens: [ShareScreenSource], windows: [ShareWindowSource], selected: String?, valid: Bool, audio: ShareAudioState?, tileWidth: Double, theme: MediaThemeState) {
    self.requestId = requestId
    self.tabId = tabId
    self.title = title
    self.subtitle = subtitle
    self.tabs = tabs
    self.screens = screens
    self.windows = windows
    self.selected = selected
    self.valid = valid
    self.audio = audio
    self.tileWidth = tileWidth
    self.theme = theme
  }

  public static func decode(_ json: String) -> SharePickerState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SharePickerState.self, from: data)
  }
}

public enum SharePickerAction: Equatable, Sendable {
  case select(String)
  case share(String?)
  case cancel
  case audio(Bool)
  case height(Double)
}

public enum SharePickerMetrics {
  public static let rowHeight: CGFloat = 34
  public static let listMax: CGFloat = 340
  public static let listTop: CGFloat = 4
  public static let tileGap: CGFloat = 8
  public static let tilePadding: CGFloat = 8
  public static let previewMax: CGFloat = 80
  public static let footerGap: CGFloat = 12
  public static let emptyText = "Nothing can be shared right now."

  static func selectedFill(_ dark: Bool) -> NSColor { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08) }

  public static func previewHeight(tileWidth: CGFloat, aspect: Double) -> CGFloat {
    min((tileWidth - 2 * tilePadding) * CGFloat(aspect), previewMax)
  }
}

final class ShareSectionTitle: NSView {
  let label = pickerLabel(11, weight: .semibold)

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  static var height: CGFloat { 6 + PickerMetrics.lineHeight(.systemFont(ofSize: 11, weight: .semibold)) + 6 }

  override func layout() {
    super.layout()
    let h = PickerMetrics.lineHeight(label.font!)
    label.frame = CGRect(x: PickerMetrics.rowPadding - 2, y: 6, width: bounds.width - 2 * PickerMetrics.rowPadding + 4, height: h)
  }
}

final class ShareListRow: PickerRowView {
  let icon = TabIconView()
  let image = NSImageView()
  let glyph = SymbolView()
  let title = pickerLabel(13)
  let detail = pickerLabel(12)
  let check = SymbolView()
  var id = ""
  var shrinkDetail = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.favicons = MediaImages.favicons
    image.imageScaling = .scaleProportionallyUpOrDown
    for v in [icon, image, glyph, title, detail, check] as [NSView] { addSubview(v) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let h = bounds.height
    let pad = PickerMetrics.rowPadding
    let slot = PickerMetrics.iconSlot
    icon.frame = CGRect(x: pad + 2, y: (h - 16) / 2, width: 16, height: 16)
    image.frame = CGRect(x: pad, y: (h - 20) / 2, width: 20, height: 20)
    glyph.frame = image.frame
    let x = pad + slot + PickerMetrics.iconGap
    var right = bounds.width - pad
    check.frame = CGRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
    if !check.isHidden { right -= 16 + PickerMetrics.iconGap }
    let room = max(0, right - x)
    let tw = title.intrinsicContentSize.width
    let dw = detail.isHidden ? 0 : detail.intrinsicContentSize.width
    let gap = detail.isHidden ? 0 : PickerMetrics.iconGap
    var titleW = tw
    var detailW = dw
    let over = tw + gap + dw - room
    if over > 0 {
      if shrinkDetail {
        let titleShare = min(tw, over / 3)
        titleW = tw - titleShare
        detailW = max(0, dw - (over - titleShare))
        if detailW == 0 { titleW = max(0, room - gap) }
      } else {
        titleW = max(0, tw - over)
      }
    }
    let lh = PickerMetrics.lineHeight(title.font!)
    let dh = PickerMetrics.lineHeight(detail.font!)
    title.frame = CGRect(x: x - 2, y: (h - lh) / 2, width: titleW + 4, height: lh)
    detail.frame = CGRect(x: x + titleW + gap - 2, y: (h - dh) / 2, width: detailW + 4, height: dh)
  }
}

final class ShareScreenTile: PickerRowView {
  let preview = CALayer()
  let glyph = SymbolView()
  let name = pickerLabel(12)
  let size = NSTextField(labelWithString: "")
  var id = ""
  var aspect: Double = 10 / 16

  override init(frame: NSRect) {
    super.init(frame: frame)
    fill.cornerRadius = 10
    preview.cornerRadius = 6
    preview.actions = SurfaceLayer.noActions
    layer?.addSublayer(preview)
    size.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    size.isSelectable = false
    size.lineBreakMode = .byTruncatingTail
    for v in [glyph, name, size] as [NSView] { addSubview(v) }
  }

  required init?(coder: NSCoder) { fatalError() }

  static func height(width: CGFloat, aspect: Double, sized: Bool) -> CGFloat {
    let p = SharePickerMetrics.previewHeight(tileWidth: width, aspect: aspect)
    let nameH = PickerMetrics.lineHeight(.systemFont(ofSize: 12))
    let sizeH = sized ? PickerMetrics.lineHeight(.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)) : 0
    return SharePickerMetrics.tilePadding * 2 + p + 6 + nameH + sizeH
  }

  override func layout() {
    super.layout()
    let pad = SharePickerMetrics.tilePadding
    let pw = bounds.width - 2 * pad
    let ph = SharePickerMetrics.previewHeight(tileWidth: bounds.width, aspect: aspect)
    MediaMotion.setInstantly { preview.frame = CGRect(x: pad, y: pad, width: pw, height: ph) }
    glyph.frame = CGRect(x: pad + (pw - 30) / 2, y: pad + (ph - 30) / 2, width: 30, height: 30)
    let nameH = PickerMetrics.lineHeight(name.font!)
    let nw = min(pw, name.intrinsicContentSize.width)
    name.frame = CGRect(x: (bounds.width - nw) / 2 - 2, y: pad + ph + 6, width: nw + 4, height: nameH)
    let sh = PickerMetrics.lineHeight(size.font!)
    let sw = min(pw, size.intrinsicContentSize.width)
    size.frame = CGRect(x: (bounds.width - sw) / 2 - 2, y: pad + ph + 6 + nameH, width: sw + 4, height: sh)
  }
}

final class ShareCheckbox: HoverFillView {
  private let box = CALayer()
  private let check = SymbolView()
  let label = pickerLabel(13)
  var value = false
  var colors: (accent: NSColor, control: NSColor, border: NSColor) = (.controlAccentColor, .white, .gray)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    box.cornerRadius = 3.5
    box.actions = SurfaceLayer.noActions
    layer?.addSublayer(box)
    addSubview(check)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override var fittingSize: NSSize { NSSize(width: 14 + 7 + label.intrinsicContentSize.width, height: max(14, PickerMetrics.lineHeight(label.font!))) }

  func paint() {
    MediaMotion.setInstantly {
      box.backgroundColor = value ? colors.accent.cgColor : colors.control.cgColor
      box.borderWidth = value ? 0 : 2 / (window?.backingScaleFactor ?? 2)
      box.borderColor = colors.border.cgColor
    }
    check.set("checkmark", size: 9, weight: .bold, color: .white)
    check.isHidden = !value
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    MediaMotion.setInstantly { box.frame = CGRect(x: 0, y: (h - 14) / 2, width: 14, height: 14) }
    check.frame = CGRect(x: 0, y: (h - 14) / 2, width: 14, height: 14)
    let lh = PickerMetrics.lineHeight(label.font!)
    label.frame = CGRect(x: 14 + 7 - 2, y: (h - lh) / 2, width: max(0, bounds.width - 21 + 4), height: lh)
  }
}

public final class SharePickerView: NSView {
  public var onAction: ((SharePickerAction) -> Void)?

  private let header = PickerHeaderView()
  private let headerBox = CALayer()
  private let headerGlyph = SymbolView()
  private let scroll = NSScrollView()
  private let document = FlippedDocument()
  private var sectionTitles: [ShareSectionTitle] = []
  private var tabRows: [ShareListRow] = []
  private var tiles: [ShareScreenTile] = []
  private var windowRows: [ShareListRow] = []
  private let empty = pickerLabel(12)
  private let checkbox = ShareCheckbox()
  private let cancel = PromptButtonView(title: "Cancel")
  private let share = PromptButtonView(title: "Share")
  private var state: SharePickerState?
  private var reported: CGFloat = 0
  private var listHeight: CGFloat = 0

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    header.iconSize = 32
    header.large = true
    header.subtitleLines = 2
    header.icon.wantsLayer = true
    headerBox.cornerRadius = 8
    headerBox.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    headerBox.actions = SurfaceLayer.noActions
    header.icon.layer?.addSublayer(headerBox)
    headerGlyph.frame = CGRect(x: 5, y: 5, width: 22, height: 22)
    header.icon.addSubview(headerGlyph)
    addSubview(header)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = document
    addSubview(scroll)
    empty.alignment = .center
    empty.stringValue = SharePickerMetrics.emptyText
    document.addSubview(empty)
    checkbox.onPress = { [weak self] in
      guard let self, let audio = self.state?.audio else { return }
      self.onAction?(.audio(!audio.value))
    }
    addSubview(checkbox)
    cancel.onPress = { [weak self] in self?.onAction?(.cancel) }
    share.primary = true
    share.onPress = { [weak self] in
      guard self?.state?.valid == true else { return }
      self?.onAction?(.share(nil))
    }
    addSubview(cancel)
    addSubview(share)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: onAction?(.cancel)
    case 36, 76: onAction?(.share(nil))
    default: super.keyDown(with: event)
    }
  }

  private func row(_ pool: inout [ShareListRow], _ i: Int) -> ShareListRow {
    if i < pool.count { return pool[i] }
    let row = ShareListRow()
    row.onPress = { [weak self, weak row] in if let id = row?.id { self?.onAction?(.select(id)) } }
    row.onDoubleClick = { [weak self, weak row] in if let id = row?.id { self?.onAction?(.share(id)) } }
    document.addSubview(row)
    pool.append(row)
    return row
  }

  private func trim<T: NSView>(_ pool: inout [T], _ count: Int) {
    while pool.count > count { pool.removeLast().removeFromSuperview() }
  }

  public func update(_ next: SharePickerState) {
    state = next
    let palette = MediaPalette(next.theme)
    let dark = palette.dark
    let selectedFill = SharePickerMetrics.selectedFill(dark)
    header.title.stringValue = next.title
    header.title.textColor = palette.textPrimary
    header.subtitle.stringValue = next.subtitle
    header.subtitle.textColor = palette.textSecondary
    MediaMotion.setInstantly { headerBox.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.05).cgColor }
    headerGlyph.set("rectangle.inset.filled.and.person.filled", size: 15, color: palette.icon)

    let titles = [next.tabs.isEmpty ? nil : "Tabs", next.screens.isEmpty ? nil : (next.screens.count == 1 ? "Screen" : "Screens"), next.windows.isEmpty ? nil : "Windows"].compactMap { $0 }
    while sectionTitles.count < titles.count {
      let t = ShareSectionTitle()
      document.addSubview(t)
      sectionTitles.append(t)
    }
    trim(&sectionTitles, titles.count)
    for (view, text) in zip(sectionTitles, titles) {
      view.label.stringValue = text
      view.label.textColor = palette.textSecondary
    }

    for (i, tab) in next.tabs.enumerated() {
      let r = row(&tabRows, i)
      r.id = "tab:" + tab.id
      r.icon.isHidden = false
      r.image.isHidden = true
      r.glyph.isHidden = true
      r.icon.set(TabIconSpec(url: tab.url, favicon: tab.favicon, profileId: tab.profileId, size: 16), palette: MediaImages.sidebarPalette(next.theme))
      r.title.stringValue = tab.title
      r.detail.stringValue = "This Tab"
      r.detail.isHidden = !tab.current
      r.shrinkDetail = false
      paintRow(r, selected: next.selected == r.id, palette: palette, fill: selectedFill)
    }
    trim(&tabRows, next.tabs.count)

    while tiles.count < next.screens.count {
      let tile = ShareScreenTile()
      tile.onPress = { [weak self, weak tile] in if let id = tile?.id { self?.onAction?(.select(id)) } }
      tile.onDoubleClick = { [weak self, weak tile] in if let id = tile?.id { self?.onAction?(.share(id)) } }
      document.addSubview(tile)
      tiles.append(tile)
    }
    trim(&tiles, next.screens.count)
    for (tile, screen) in zip(tiles, next.screens) {
      let on = next.selected == screen.id
      tile.id = screen.id
      tile.aspect = screen.aspect
      tile.hoverColor = palette.rowHover
      tile.selectedColor = selectedFill
      tile.selected = on
      tile.refresh()
      MediaMotion.setInstantly {
        tile.preview.borderWidth = on ? 2 : 1
        tile.preview.borderColor = on ? palette.accent.cgColor : NSColor(white: dark ? 1 : 0, alpha: dark ? 0.15 : 0.12).cgColor
        tile.preview.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.05 : 0.03).cgColor
      }
      tile.glyph.set("display", size: 22, color: palette.textSecondary)
      tile.name.stringValue = screen.name
      tile.name.textColor = palette.textPrimary
      tile.size.stringValue = screen.size ?? ""
      tile.size.textColor = palette.textTertiary
      tile.size.isHidden = screen.size == nil
      tile.needsLayout = true
    }

    for (i, win) in next.windows.enumerated() {
      let r = row(&windowRows, i)
      r.id = win.id
      r.icon.isHidden = true
      let image = win.icon.flatMap { MediaImages.load?($0) }
      r.image.image = image
      r.image.isHidden = image == nil
      r.glyph.isHidden = image != nil
      r.glyph.set("macwindow", size: 14, color: palette.textSecondary)
      r.title.stringValue = win.title
      r.detail.stringValue = win.app ?? ""
      r.detail.isHidden = win.app == nil
      r.shrinkDetail = true
      paintRow(r, selected: next.selected == r.id, palette: palette, fill: selectedFill)
    }
    trim(&windowRows, next.windows.count)

    empty.isHidden = !(next.tabs.isEmpty && next.screens.isEmpty && next.windows.isEmpty)
    empty.textColor = palette.textSecondary

    checkbox.isHidden = next.audio == nil
    checkbox.label.stringValue = next.audio?.label ?? ""
    checkbox.label.textColor = palette.textPrimary
    checkbox.value = next.audio?.value ?? false
    checkbox.colors = dark
      ? (MediaPalette.parse("#0A84FF")!, MediaPalette.parse("rgba(255,255,255,0.1)")!, MediaPalette.parse("rgba(255,255,255,0.08)")!)
      : (MediaPalette.parse("#007AFF")!, MediaPalette.parse("#FFFFFF")!, MediaPalette.parse("rgba(0,0,0,0.14)")!)
    checkbox.paint()
    cancel.theme = next.theme
    share.theme = next.theme
    share.alphaValue = next.valid ? 1 : 0.4
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func paintRow(_ r: ShareListRow, selected: Bool, palette: MediaPalette, fill: NSColor) {
    r.hoverColor = palette.rowHover
    r.selectedColor = fill
    r.selected = selected
    r.refresh()
    r.title.textColor = palette.textPrimary
    r.detail.textColor = palette.textSecondary
    r.check.set("checkmark", size: 11, weight: .semibold, color: palette.accent)
    r.check.isHidden = !selected
    r.needsLayout = true
  }

  private func contentLayout(width: CGFloat) -> CGFloat {
    guard let state else { return 0 }
    let inner = width - 2 * PickerMetrics.rowInset
    var y: CGFloat = 0
    var section = 0
    func title() {
      guard section < sectionTitles.count else { return }
      sectionTitles[section].frame = CGRect(x: PickerMetrics.rowInset, y: y, width: inner, height: ShareSectionTitle.height)
      y += ShareSectionTitle.height
      section += 1
    }
    if !state.tabs.isEmpty {
      title()
      for r in tabRows {
        r.frame = CGRect(x: PickerMetrics.rowInset, y: y, width: inner, height: SharePickerMetrics.rowHeight)
        y += SharePickerMetrics.rowHeight
      }
    }
    if !state.screens.isEmpty {
      title()
      let tw = CGFloat(state.tileWidth)
      var rowHeight: CGFloat = 0
      for (i, tile) in tiles.enumerated() {
        let column = i % 2
        if column == 0, i > 0 {
          y += rowHeight + SharePickerMetrics.tileGap
          rowHeight = 0
        }
        let h = ShareScreenTile.height(width: tw, aspect: state.screens[i].aspect, sized: state.screens[i].size != nil)
        tile.frame = CGRect(x: PickerMetrics.rowInset + CGFloat(column) * (tw + SharePickerMetrics.tileGap), y: y, width: tw, height: h)
        rowHeight = max(rowHeight, h)
      }
      y += rowHeight
    }
    if !state.windows.isEmpty {
      title()
      for r in windowRows {
        r.frame = CGRect(x: PickerMetrics.rowInset, y: y, width: inner, height: SharePickerMetrics.rowHeight)
        y += SharePickerMetrics.rowHeight
      }
    }
    if !empty.isHidden {
      let h = PickerMetrics.lineHeight(empty.font!) + 24
      empty.frame = CGRect(x: PickerMetrics.rowInset + 12, y: y + 12, width: inner - 24, height: h - 24)
      y += h
    }
    return y
  }

  public var contentHeight: CGFloat { reported }

  public override func layout() {
    super.layout()
    guard state != nil else { return }
    let width = bounds.width
    let head = header.height(for: width)
    header.frame = CGRect(x: 0, y: 0, width: width, height: head)
    let content = contentLayout(width: width)
    listHeight = min(SharePickerMetrics.listMax, content)
    document.frame = CGRect(x: 0, y: 0, width: width, height: content)
    scroll.frame = CGRect(x: 0, y: head + SharePickerMetrics.listTop, width: width, height: listHeight)
    let footerY = head + SharePickerMetrics.listTop + listHeight + SharePickerMetrics.footerGap
    var right = width - PickerMetrics.inset
    let sw = share.fittingSize.width
    share.frame = CGRect(x: right - sw, y: footerY, width: sw, height: PickerMetrics.buttonHeight)
    right -= sw + 8
    let cw = cancel.fittingSize.width
    cancel.frame = CGRect(x: right - cw, y: footerY, width: cw, height: PickerMetrics.buttonHeight)
    right -= cw + 8
    let box = checkbox.fittingSize
    checkbox.frame = CGRect(x: PickerMetrics.inset, y: footerY + (PickerMetrics.buttonHeight - box.height) / 2, width: min(box.width, max(0, right - PickerMetrics.inset)), height: box.height)
    let total = footerY + PickerMetrics.buttonHeight + PickerMetrics.inset
    if abs(total - reported) > 0.25 {
      reported = total
      onAction?(.height(Double(total)))
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if share.frame.contains(local), state?.valid != true { return nil }
    return super.hitTest(point)
  }

#if SOLARA_PROBES
  public var controlLabels: [String: String] { ["share": share.title, "cancel": cancel.title] }
#endif

  public var controlFrames: [String: CGRect] {
    var out: [String: CGRect] = ["share": share.frame, "cancel": cancel.frame, "header": header.frame, "list": scroll.frame]
    if !checkbox.isHidden { out["audio"] = checkbox.frame }
    for r in tabRows + windowRows { out[r.id] = r.convert(r.bounds, to: self) }
    for t in tiles { out[t.id] = t.convert(t.bounds, to: self) }
    return out
  }

  public var selectedId: String? { state?.selected }
}
