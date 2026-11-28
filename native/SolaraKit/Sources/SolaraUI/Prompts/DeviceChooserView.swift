import AppKit

public struct DeviceChooserOption: Decodable, Equatable, Sendable {
  public var optionId: Int?
  public var name: String
  public var detail: String?
  public var signal: Int
}

public struct DeviceChooserState: Decodable, Equatable, Sendable {
  public var id: Int
  public var title: String
  public var icon: String
  public var options: [DeviceChooserOption]
  public var selected: Int?
  public var scanning: Bool
  public var refreshing: Bool
  public var canRefresh: Bool
  public var scanningText: String
  public var noOptionsText: String
  public var unauthorized: Bool
  public var adapterOff: Bool
  public var notice: String?
  public var noticeIcon: String?
  public var noticeLink: String?
  public var cancelLabel: String
  public var okLabel: String
  public var valid: Bool
  public var dark: Bool
  public var theme: [String: String]
  public var goButton: String
  public var goButtonText: String

  public static func decode(_ json: String) -> DeviceChooserState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(DeviceChooserState.self, from: data)
  }
}

public enum DeviceChooserEvent: Equatable, Sendable {
  case select(Int)
  case choose(Int?)
  case cancel
  case refresh
  case openSettings
}

enum DeviceChooserMetrics {
  static let inset: CGFloat = 16
  static let gap: CGFloat = 10
  static let rowHeight: CGFloat = 32
  static let rowRadius: CGFloat = 6
  static let rowPadding: CGFloat = 10
  static let rowGap: CGFloat = 2
  static let iconGap: CGFloat = 10
  static let listMaxHeight: CGFloat = 200
  static let listOutset: CGFloat = 10
  static let statusHeight: CGFloat = 22
}

@MainActor
public final class DeviceChooserView: NSView, PromptInputProtectionOwner {
  let inputProtection = PromptInputProtection()
  public var onEvent: (DeviceChooserEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  private var state: DeviceChooserState?
  private var reported: CGFloat = 0
  private let list = NSScrollView()
  private let rows = FlippedView()

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    inputProtection.enabled = true
    list.drawsBackground = false
    list.hasVerticalScroller = true
    list.autohidesScrollers = true
    list.scrollerStyle = .overlay
    list.documentView = rows
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    inputProtection.attach(to: self)
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    inputProtection.shown()
  }

  public func update(_ next: DeviceChooserState) {
    guard next != state else { return }
    if next.id != state?.id { inputProtection.shown() }
    state = next
    rebuild()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }

  public override func keyDown(with event: NSEvent) {
    guard let s = state else { return super.keyDown(with: event) }
    guard inputProtection.allows(event) else { return }
    switch event.keyCode {
    case 53: onEvent(.cancel)
    case 36, 76: if s.valid { onEvent(.choose(s.selected)) }
    default: super.keyDown(with: event)
    }
  }

  private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, lines: Int = 1) -> NSTextField {
    let f = lines == 1 ? NSTextField(labelWithString: string) : NSTextField(wrappingLabelWithString: string)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.maximumNumberOfLines = lines
    f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    f.isSelectable = false
    return f
  }

  private func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
    field.preferredMaxLayoutWidth = width
    return ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + 4, height: 10_000)).height ?? field.intrinsicContentSize.height)
  }

  private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, box: CGFloat) -> NSImageView {
    let v = NSImageView(frame: CGRect(x: 0, y: 0, width: box, height: box))
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    v.imageScaling = .scaleNone
    v.contentTintColor = color
    return v
  }

  private func link(_ title: String, color: NSColor, action: @escaping () -> Void) -> PromptPressable {
    let f = text(title, size: 12, weight: .medium, color: color)
    let size = f.intrinsicContentSize
    let p = PromptPressable(frame: CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height)))
    f.frame = p.bounds.insetBy(dx: -2, dy: 0)
    p.addSubview(f)
    p.onHover = { hovered in
      var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
      if hovered { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      f.attributedStringValue = NSAttributedString(string: title, attributes: attrs)
    }
    p.onPress = action
    p.setAccessibilityRole(.link)
    p.setAccessibilityLabel(title)
    return p
  }

  private func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    rows.subviews.forEach { $0.removeFromSuperview() }
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let m = DeviceChooserMetrics.self
    let inner = bounds.width - 2 * m.inset
    var y = m.inset

    let tile = NSView(frame: CGRect(x: m.inset, y: y, width: 30, height: 30))
    tile.wantsLayer = true
    tile.layer?.cornerRadius = 8
    tile.layer?.backgroundColor = (s.dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)).cgColor
    let glyph = symbol(s.icon, size: 14, color: theme.icon.ns, box: 20)
    glyph.frame.origin = CGPoint(x: 5, y: 5)
    tile.addSubview(glyph)
    addSubview(tile)
    let title = text(s.title, size: 13, weight: .semibold, color: theme.textPrimary.ns, lines: 0)
    let titleWidth = inner - 30 - 9
    let th = height(title, width: titleWidth)
    title.frame = CGRect(x: m.inset + 30 + 9 - 2, y: y + max(0, (30 - th) / 2), width: titleWidth + 4, height: th)
    addSubview(title)
    y += max(30, th)

    if let notice = s.notice {
      y += m.gap
      let icon = symbol(s.noticeIcon ?? "info.circle", size: 13, color: theme.textSecondary.ns, box: 18)
      icon.frame.origin = CGPoint(x: m.inset, y: y + 6)
      addSubview(icon)
      let column = inner - 18 - 9
      let body = text(notice, size: 12.5, color: theme.textSecondary.ns, lines: 0)
      let bh = height(body, width: column)
      body.frame = CGRect(x: m.inset + 18 + 9 - 2, y: y + 6, width: column + 4, height: bh)
      addSubview(body)
      var h = bh
      if let label = s.noticeLink {
        let l = link(label, color: theme.accent.ns) { [weak self] in self?.onEvent(.openSettings) }
        l.frame.origin = CGPoint(x: m.inset + 18 + 9, y: y + 6 + bh + 4)
        addSubview(l)
        h += 4 + l.frame.height
      }
      y += 6 + max(18, h) + 6
    } else if !s.scanning {
      y += m.gap
      let listWidth = inner + 2 * m.listOutset
      var ry: CGFloat = 0
      for (i, option) in s.options.enumerated() {
        if i > 0 { ry += m.rowGap }
        let row = PromptPressable(frame: CGRect(x: 0, y: ry, width: listWidth, height: m.rowHeight))
        row.wantsLayer = true
        row.layer?.cornerRadius = m.rowRadius
        let optionId = option.optionId ?? i
        let selected = s.selected == optionId
        let selectedFill = (s.dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)).cgColor
        row.fill = { hovered, _ in selected ? selectedFill : hovered ? theme.rowHover.cg : nil }
        row.refresh()
        var x = m.rowPadding
        if option.signal >= 0 {
          for bar in 0..<4 {
            let b = CALayer()
            let bh = 3 + CGFloat(bar) * 2.5
            b.frame = CGRect(x: x + CGFloat(bar) * 4, y: (m.rowHeight - 11) / 2 + 11 - bh, width: 2.5, height: bh)
            b.cornerRadius = 1
            b.backgroundColor = theme.icon.ns.withAlphaComponent(theme.icon.ns.alphaComponent * (bar < option.signal ? 1 : 0.25)).cgColor
            row.layer?.addSublayer(b)
          }
          x += 4 * 2.5 + 3 * 1.5 + m.iconGap
        }
        let check: CGFloat = selected ? 16 + m.iconGap : 0
        let detail = option.detail.map { text($0, size: 11.5, color: theme.textSecondary.ns) }
        let detailWidth = detail.map { ceil($0.intrinsicContentSize.width) } ?? 0
        let name = text(option.name, size: 13, color: theme.textPrimary.ns)
        let room = listWidth - m.rowPadding - x - check - (detail == nil ? 0 : detailWidth + m.iconGap)
        let nameWidth = min(ceil(name.intrinsicContentSize.width), max(0, room))
        let nh = name.intrinsicContentSize.height
        name.frame = CGRect(x: x - 2, y: (m.rowHeight - nh) / 2, width: nameWidth + 4, height: nh)
        row.addSubview(name)
        x += nameWidth
        if let detail {
          x += m.iconGap
          let dh = detail.intrinsicContentSize.height
          detail.frame = CGRect(x: x - 2, y: (m.rowHeight - dh) / 2, width: detailWidth + 4, height: dh)
          row.addSubview(detail)
        }
        if selected {
          let mark = symbol("checkmark", size: 11, weight: .semibold, color: theme.accent.ns, box: 16)
          mark.frame.origin = CGPoint(x: listWidth - m.rowPadding - 16, y: (m.rowHeight - 16) / 2)
          row.addSubview(mark)
        }
        row.onPress = { [weak self] in self?.onEvent(.select(optionId)) }
        row.onDoublePress = { [weak self] in self?.onEvent(.choose(optionId)) }
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel(option.name)
        rows.addSubview(row)
        ry += m.rowHeight
      }
      let listHeight = min(ry, m.listMaxHeight)
      rows.frame = CGRect(x: 0, y: 0, width: listWidth, height: ry)
      list.frame = CGRect(x: m.inset - m.listOutset, y: y, width: listWidth, height: listHeight)
      if ry > 0 { addSubview(list) }
      y += listHeight
      y += m.gap
      var sx = m.inset
      if s.refreshing {
        let spinner = NSProgressIndicator(frame: CGRect(x: sx, y: y + (m.statusHeight - 14) / 2, width: 14, height: 14))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        addSubview(spinner)
        sx += 14 + 7
        let t = text(s.scanningText, size: 12, color: theme.textSecondary.ns)
        let h = t.intrinsicContentSize.height
        t.frame = CGRect(x: sx - 2, y: y + (m.statusHeight - h) / 2, width: inner - sx + m.inset + 4, height: h)
        addSubview(t)
      } else {
        if s.options.isEmpty {
          let t = text(s.noOptionsText, size: 12, color: theme.textSecondary.ns)
          let w = ceil(t.intrinsicContentSize.width), h = t.intrinsicContentSize.height
          t.frame = CGRect(x: sx - 2, y: y + (m.statusHeight - h) / 2, width: w + 4, height: h)
          addSubview(t)
          sx += w + 7
        }
        if s.canRefresh {
          let l = link("Scan Again", color: theme.accent.ns) { [weak self] in self?.onEvent(.refresh) }
          l.frame.origin = CGPoint(x: sx, y: y + (m.statusHeight - l.frame.height) / 2)
          addSubview(l)
        }
      }
      y += m.statusHeight
    }

    y += m.gap
    let primaryOn = s.valid && !s.unauthorized && !s.adapterOff
    var right = bounds.width - m.inset
    for (label, primary) in [(s.okLabel, true), (s.cancelLabel, false)] {
      let f = text(label, size: 13, weight: .medium, color: primary ? (CSSColor(s.goButtonText)?.ns ?? .white) : theme.textPrimary.ns)
      let tw = ceil(f.intrinsicContentSize.width)
      let b = PromptPressable(frame: CGRect(x: right - tw - 24, y: y, width: tw + 24, height: 28))
      b.wantsLayer = true
      b.layer?.cornerRadius = 8
      let dark = s.dark, go = CSSColor(s.goButton)?.cg
      b.fill = { hovered, pressed in
        if primary {
          if dark { return pressed ? CSSColor("#C9B8C5")!.cg : hovered ? CSSColor("#E6D8E2")!.cg : go }
          return pressed ? CSSColor("#26314A")!.cg : hovered ? CSSColor("#1B2640")!.cg : go
        }
        let a: CGFloat = pressed ? (dark ? 0.18 : 0.12) : hovered ? (dark ? 0.14 : 0.09) : (dark ? 0.1 : 0.06)
        return NSColor(white: dark ? 1 : 0, alpha: a).cgColor
      }
      b.refresh()
      let h = f.intrinsicContentSize.height
      f.frame = CGRect(x: 12 - 2, y: (28 - h) / 2 - 0.5, width: tw + 4, height: h)
      b.addSubview(f)
      if primary {
        b.alphaValue = primaryOn ? 1 : 0.4
        b.onPress = { [weak self] in if primaryOn { self?.onEvent(.choose(s.selected)) } }
      } else {
        b.onPress = { [weak self] in self?.onEvent(.cancel) }
      }
      b.setAccessibilityRole(.button)
      b.setAccessibilityLabel(label)
      b.setAccessibilityEnabled(primary ? primaryOn : true)
      addSubview(b)
      right -= tw + 24 + 8
    }
    y += 28 + m.inset
    if y != reported {
      reported = y
      onHeight(y)
    }
  }
}
