import AppKit
import QuartzCore

public struct CastSinkState: Equatable, Sendable {
  public var id: String
  public var name: String
  public var icon: String
  public var detail: String?
  public var issue: Bool
  public var active: Bool
  public var busy: Bool

  public init(id: String, name: String, icon: String, detail: String?, issue: Bool, active: Bool, busy: Bool) {
    self.id = id
    self.name = name
    self.icon = icon
    self.detail = detail
    self.issue = issue
    self.active = active
    self.busy = busy
  }
}

public struct CastPickerState: Equatable, Sendable {
  public var title: String
  public var canScreen: Bool
  public var rejected: Bool
  public var rejectedText: String
  public var sinks: [CastSinkState]
  public var theme: MediaThemeState

  public init(title: String, canScreen: Bool, rejected: Bool, rejectedText: String, sinks: [CastSinkState], theme: MediaThemeState) {
    self.title = title
    self.canScreen = canScreen
    self.rejected = rejected
    self.rejectedText = rejectedText
    self.sinks = sinks
    self.theme = theme
  }
}

public enum CastPickerAction: Equatable, Sendable {
  case cast(String)
  case stop(String)
  case source
  case link
  case done
  case height(Double)
}

public enum CastPickerMetrics {
  public static let rowHeight: CGFloat = 42
  public static let rowGap: CGFloat = 2
  public static let listMax: CGFloat = 280
  public static let footerGap: CGFloat = 10
  public static let searchingText = "Looking for devices… Cast devices need to be on the same Wi\u{2011}Fi network as this Mac."
  public static let linkText = "Open Local Network Settings"
}

final class CastSinkRowView: PickerRowView {
  private let box = CALayer()
  private let glyph = SymbolView()
  private let name = pickerLabel(13)
  private let detail = pickerLabel(11.5)
  private let spinner = PickerSpinner()
  let stop = PromptButtonView(title: "Stop")
  private(set) var sink: CastSinkState?

  override init(frame: NSRect) {
    super.init(frame: frame)
    box.cornerRadius = 7
    box.cornerCurve = .continuous
    box.actions = SurfaceLayer.noActions
    layer?.addSublayer(box)
    for v in [glyph, name, detail, spinner, stop] as [NSView] { addSubview(v) }
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ sink: CastSinkState, palette: MediaPalette, theme: MediaThemeState) {
    self.sink = sink
    hoverColor = palette.rowHover
    hoverEnabled = !sink.active
    MediaMotion.setInstantly {
      box.backgroundColor = sink.active ? palette.accent.cgColor : NSColor(white: palette.dark ? 1 : 0, alpha: palette.dark ? 0.08 : 0.05).cgColor
    }
    glyph.set(sink.icon, size: 13, color: sink.active ? .white : palette.icon)
    name.stringValue = sink.name
    name.textColor = palette.textPrimary
    detail.stringValue = sink.detail ?? ""
    detail.textColor = sink.issue ? MediaTokens.captureRed : palette.textSecondary
    detail.isHidden = (sink.detail ?? "").isEmpty
    spinner.isHidden = !sink.busy
    stop.isHidden = !sink.active
    stop.theme = theme
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    let pad = PickerMetrics.rowPadding
    MediaMotion.setInstantly { box.frame = CGRect(x: pad, y: (h - 28) / 2, width: 28, height: 28) }
    glyph.frame = CGRect(x: pad + 4, y: (h - 20) / 2, width: 20, height: 20)
    var right = bounds.width - pad
    if !stop.isHidden {
      let w = stop.fittingSize.width
      stop.frame = CGRect(x: right - w, y: (h - PickerMetrics.buttonHeight) / 2, width: w, height: PickerMetrics.buttonHeight)
      right -= w + PickerMetrics.iconGap
    }
    if !spinner.isHidden {
      spinner.frame = CGRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
      right -= 16 + PickerMetrics.iconGap
    }
    let x = pad + 28 + PickerMetrics.iconGap
    let nameH = PickerMetrics.lineHeight(name.font!)
    let detailH = detail.isHidden ? 0 : PickerMetrics.lineHeight(detail.font!)
    let top = (h - nameH - detailH) / 2
    name.frame = CGRect(x: x - 2, y: top, width: max(0, right - x + 4), height: nameH)
    detail.frame = CGRect(x: x - 2, y: top + nameH, width: max(0, right - x + 4), height: detailH)
  }
}

final class FlippedDocument: NSView {
  override var isFlipped: Bool { true }
}

public final class CastPickerView: NSView {
  public var onAction: ((CastPickerAction) -> Void)?

  private let header = PickerHeaderView()
  private let headerGlyph = SymbolView()
  private let source = PopoverValueView(title: "Sources", chevron: "chevron.down")
  private let scroll = NSScrollView()
  private let document = FlippedDocument()
  private var rows: [CastSinkRowView] = []
  private let searching = NSView()
  private let searchSpinner = PickerSpinner()
  private let searchText = pickerLabel(12, lines: 0)
  private let message = pickerLabel(12.5, lines: 0)
  private let link = LinkLabelView()
  private let done = PromptButtonView(title: "Done")
  private var state: CastPickerState?
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    header.icon.addSubview(headerGlyph)
    source.onPress = { [weak self] in self?.onAction?(.source) }
    addSubview(header)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = document
    addSubview(scroll)
    searchText.stringValue = CastPickerMetrics.searchingText
    searching.addSubview(searchSpinner)
    searching.addSubview(searchText)
    addSubview(searching)
    addSubview(message)
    link.text = CastPickerMetrics.linkText
    link.onPress = { [weak self] in self?.onAction?(.link) }
    addSubview(link)
    done.onPress = { [weak self] in self?.onAction?(.done) }
    addSubview(done)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(_ next: CastPickerState) {
    state = next
    let palette = MediaPalette(next.theme)
    header.title.stringValue = next.title
    header.title.textColor = palette.textPrimary
    headerGlyph.set("tv.and.mediabox", size: 14, color: palette.icon)
    headerGlyph.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
    source.hoverFill = palette.toolbarHover
    source.set(color: palette.textSecondary)
    header.accessory = next.canScreen ? source : nil
    message.stringValue = next.rejectedText
    message.textColor = palette.textSecondary
    link.color = palette.accent
    searchText.textColor = palette.textSecondary
    done.theme = next.theme
    while rows.count < next.sinks.count {
      let row = CastSinkRowView()
      row.onPress = { [weak self, weak row] in
        guard let sink = row?.sink, !sink.active, !sink.busy else { return }
        self?.onAction?(.cast(sink.id))
      }
      row.stop.onPress = { [weak self, weak row] in
        guard let sink = row?.sink else { return }
        self?.onAction?(.stop(sink.id))
      }
      document.addSubview(row)
      rows.append(row)
    }
    while rows.count > next.sinks.count { rows.removeLast().removeFromSuperview() }
    for (row, sink) in zip(rows, next.sinks) { row.set(sink, palette: palette, theme: next.theme) }
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  public var contentHeight: CGFloat { layoutHeight(for: bounds.width).total }

  private func layoutHeight(for width: CGFloat) -> (header: CGFloat, body: CGFloat, total: CGFloat) {
    guard let state else { return (0, 0, 0) }
    let head = header.height(for: width)
    let inner = width - 2 * PickerMetrics.inset
    let body: CGFloat
    if state.rejected {
      body = 4 + PickerMetrics.textHeight(state.rejectedText, font: message.font!, width: inner) + 5 + PickerMetrics.lineHeight(link.font)
    } else if !state.sinks.isEmpty {
      let n = CGFloat(state.sinks.count)
      body = min(CastPickerMetrics.listMax, n * CastPickerMetrics.rowHeight + (n - 1) * CastPickerMetrics.rowGap)
    } else {
      body = 4 + max(14, PickerMetrics.textHeight(CastPickerMetrics.searchingText, font: searchText.font!, width: inner - 14 - 8)) + 4
    }
    return (head, body, head + body + CastPickerMetrics.footerGap + PickerMetrics.buttonHeight + PickerMetrics.inset)
  }

  public override func layout() {
    super.layout()
    guard let state else { return }
    let width = bounds.width
    let (head, body, total) = layoutHeight(for: width)
    header.frame = CGRect(x: 0, y: 0, width: width, height: head)
    let inner = width - 2 * PickerMetrics.inset
    let showList = !state.rejected && !state.sinks.isEmpty
    scroll.isHidden = !showList
    searching.isHidden = state.rejected || showList
    message.isHidden = !state.rejected
    link.isHidden = !state.rejected
    if state.rejected {
      let mh = PickerMetrics.textHeight(state.rejectedText, font: message.font!, width: inner)
      message.preferredMaxLayoutWidth = inner + 4
      message.frame = CGRect(x: PickerMetrics.inset - 2, y: head + 4, width: inner + 4, height: mh)
      let lw = link.fittingSize.width
      link.frame = CGRect(x: PickerMetrics.inset, y: head + 4 + mh + 5, width: lw, height: PickerMetrics.lineHeight(link.font))
    } else if showList {
      scroll.frame = CGRect(x: 0, y: head, width: width, height: body)
      var y: CGFloat = 0
      for row in rows {
        row.frame = CGRect(x: PickerMetrics.rowInset, y: y, width: width - 2 * PickerMetrics.rowInset, height: CastPickerMetrics.rowHeight)
        y += CastPickerMetrics.rowHeight + CastPickerMetrics.rowGap
      }
      document.frame = CGRect(x: 0, y: 0, width: width, height: max(0, y - CastPickerMetrics.rowGap))
    } else {
      searching.frame = CGRect(x: 0, y: head, width: width, height: body)
      let textW = inner - 14 - 8
      let th = PickerMetrics.textHeight(CastPickerMetrics.searchingText, font: searchText.font!, width: textW)
      let rowH = max(14, th)
      searchSpinner.frame = CGRect(x: PickerMetrics.inset, y: 4 + (rowH - 14) / 2, width: 14, height: 14)
      searchText.preferredMaxLayoutWidth = textW + 4
      searchText.frame = CGRect(x: PickerMetrics.inset + 14 + 8 - 2, y: 4 + (rowH - th) / 2, width: textW + 4, height: th)
    }
    let dw = done.fittingSize.width
    done.frame = CGRect(x: width - PickerMetrics.inset - dw, y: head + body + CastPickerMetrics.footerGap, width: dw, height: PickerMetrics.buttonHeight)
    if abs(total - reported) > 0.25 {
      reported = total
      onAction?(.height(Double(total)))
    }
  }

#if SOLARA_PROBES
  public var controlLabels: [String: String] {
    var labels = ["done": done.title]
    for (i, row) in rows.enumerated() where !scroll.isHidden && !row.stop.isHidden { labels["stop\(i)"] = row.stop.title }
    return labels
  }
#endif

  public var controlFrames: [String: CGRect] {
    var out: [String: CGRect] = ["done": done.frame, "header": header.frame]
    if header.accessory != nil { out["source"] = source.convert(source.bounds, to: self) }
    if !link.isHidden { out["link"] = link.frame }
    for (i, row) in rows.enumerated() where !scroll.isHidden {
      out["sink\(i)"] = row.convert(row.bounds, to: self)
      if !row.stop.isHidden { out["stop\(i)"] = row.stop.convert(row.stop.bounds, to: self) }
    }
    return out
  }
}

final class LinkLabelView: NSView {
  private let label = pickerLabel(12, weight: .medium)
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  var text = "" { didSet { paint() } }
  var color: NSColor = .linkColor { didSet { paint() } }
  var onPress: (() -> Void)?
  var font: NSFont { label.font! }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) { hovered = DevPointer.inside(self, note) }

  override var fittingSize: NSSize { NSSize(width: label.intrinsicContentSize.width, height: label.intrinsicContentSize.height) }

  override func layout() {
    super.layout()
    label.frame = CGRect(x: -2, y: (bounds.height - label.intrinsicContentSize.height) / 2, width: bounds.width + 4, height: label.intrinsicContentSize.height)
  }

  private func paint() {
    var attrs: [NSAttributedString.Key: Any] = [.font: label.font!, .foregroundColor: color]
    if hovered { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    label.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
  }
}
