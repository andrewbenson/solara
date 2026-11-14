import AppKit

public struct ExtensionInstallState: Decodable, Equatable, Sendable {
  public var status: String
  public var title: String
  public var error: String?
  public var icon: String?
  public var warnings: [String]
  public var loadedFrom: String?
  public var action: String
  public var dark: Bool
  public var theme: [String: String]
  public var goButton: String
  public var goButtonText: String
}

public struct ExtensionPin: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var icon: String?
  public var pinned: Bool
}

public struct ExtensionPinsState: Decodable, Equatable, Sendable {
  public var extensions: [ExtensionPin]
  public var dark: Bool
  public var theme: [String: String]
  public var control: String
  public var controlBorder: String
  public var goButton: String
  public var goButtonText: String
}

public enum ExtensionDialogEvent: Equatable, Sendable {
  case cancel
  case confirm
  case toggle(String, Bool)
  case done
}

@MainActor
public class ExtensionDialogBody: NSView {
  public var onEvent: (ExtensionDialogEvent) -> Void = { _ in }
  public var onHeight: (CGFloat) -> Void = { _ in }
  private var reported: CGFloat = 0

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { rebuild() }
  }

  func rebuild() {}

  func report(_ height: CGFloat) {
    guard height != reported else { return }
    reported = height
    onHeight(height)
  }

  func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, lines: Int = 0) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: string)
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.maximumNumberOfLines = lines
    f.lineBreakMode = lines == 0 ? .byWordWrapping : .byTruncatingMiddle
    f.cell?.truncatesLastVisibleLine = true
    f.isSelectable = false
    return f
  }

  func place(_ field: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
    field.preferredMaxLayoutWidth = width
    let h = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + 4, height: 10_000)).height ?? field.intrinsicContentSize.height)
    field.frame = CGRect(x: x - 2, y: y, width: width + 4, height: h)
    addSubview(field)
    return h
  }

  func image(_ uri: String?) -> NSImage? {
    guard let uri, !uri.isEmpty else { return nil }
    if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"), let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) {
      return NSImage(data: data)
    }
    if let url = URL(string: uri), url.isFileURL || uri.hasPrefix("/") { return NSImage(contentsOf: url.isFileURL ? url : URL(fileURLWithPath: uri)) }
    if let url = URL(string: uri) { return (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }
    return nil
  }

  func buttons(_ specs: [(String, Bool, ExtensionDialogEvent)], top: CGFloat, dark: Bool, theme: NewTabTheme, goButton: String, goButtonText: String) -> CGFloat {
    var right = bounds.width
    for (label, primary, event) in specs.reversed() {
      let f = NSTextField(labelWithString: label)
      f.font = .systemFont(ofSize: 13, weight: .medium)
      f.textColor = primary ? (CSSColor(goButtonText)?.ns ?? .white) : theme.textPrimary.ns
      let tw = ceil(f.intrinsicContentSize.width)
      let b = PromptPressable(frame: CGRect(x: right - tw - 24, y: top, width: tw + 24, height: 28))
      b.wantsLayer = true
      b.layer?.cornerRadius = 8
      let go = CSSColor(goButton)?.cg
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
      b.onPress = { [weak self] in self?.onEvent(event) }
      b.setAccessibilityRole(.button)
      b.setAccessibilityLabel(label)
      addSubview(b)
      right -= tw + 24 + 8
    }
    return 28
  }
}

@MainActor
public final class ExtensionInstallView: ExtensionDialogBody, PromptInputProtectionOwner {
  let inputProtection = PromptInputProtection()
  private var state: ExtensionInstallState?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    inputProtection.enabled = true
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

  public func update(_ next: ExtensionInstallState) {
    guard next != state else { return }
    state = next
    rebuild()
  }

  override func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let width = bounds.width
    var y: CGFloat = 0
    if s.status == "error" {
      y += place(text("Couldn't add the extension", size: 15, weight: .semibold, color: theme.textPrimary.ns), x: 0, y: y, width: width)
      y += 6
      y += place(text(s.error ?? "", size: 13, color: theme.textSecondary.ns), x: 0, y: y, width: width)
    } else {
      var titleX: CGFloat = 0
      let icon = image(s.icon)
      if let icon {
        let v = NSImageView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        v.image = icon
        v.imageScaling = .scaleProportionallyUpOrDown
        addSubview(v)
        titleX = 36 + 12
      }
      let title = text(s.title, size: 15, weight: .semibold, color: theme.textPrimary.ns)
      let th = place(title, x: titleX, y: 0, width: width - titleX)
      if icon != nil, th < 36 { title.frame.origin.y = (36 - th) / 2 }
      y = max(icon == nil ? 0 : 36, th)
      if s.warnings.isEmpty {
        y += 14
        y += place(text("This extension requires no special permissions.", size: 13, color: theme.textSecondary.ns), x: 0, y: y, width: width)
      } else {
        y += 14
        y += place(text("It can:", size: 13, color: theme.textPrimary.ns), x: 0, y: y, width: width)
        y += 6
        let list = NSScrollView(frame: .zero)
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        let rows = FlippedView()
        var ry: CGFloat = 0
        for w in s.warnings {
          let bullet = NSTextField(labelWithString: "•")
          bullet.font = .systemFont(ofSize: 13)
          bullet.textColor = theme.textSecondary.ns
          let bw = ceil(bullet.intrinsicContentSize.width)
          bullet.frame = CGRect(x: -2, y: ry, width: bw + 4, height: bullet.intrinsicContentSize.height)
          rows.addSubview(bullet)
          let line = text(w, size: 13, color: theme.textSecondary.ns)
          let lw = width - bw - 7
          line.preferredMaxLayoutWidth = lw
          let lh = ceil(line.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: lw + 4, height: 10_000)).height ?? 16)
          line.frame = CGRect(x: bw + 7 - 2, y: ry, width: lw + 4, height: lh)
          rows.addSubview(line)
          ry += lh + 4
        }
        rows.frame = CGRect(x: 0, y: 0, width: width, height: ry)
        list.documentView = rows
        let lh = min(ry, 180)
        list.frame = CGRect(x: 0, y: y, width: width, height: lh)
        addSubview(list)
        y += lh
      }
      if let from = s.loadedFrom {
        y += 10
        y += place(text("Loaded from \(from)", size: 11, color: theme.textTertiary.ns, lines: 2), x: 0, y: y, width: width)
      }
    }
    y += 18
    let specs: [(String, Bool, ExtensionDialogEvent)] = s.status == "error"
      ? [("OK", true, .cancel)]
      : [("Cancel", false, .cancel), (s.status == "installing" ? "Adding…" : s.action, true, .confirm)]
    y += buttons(specs, top: y, dark: s.dark, theme: theme, goButton: s.goButton, goButtonText: s.goButtonText)
    report(y)
  }
}

@MainActor
public final class ExtensionPinsView: ExtensionDialogBody {
  private var state: ExtensionPinsState?

  public func update(_ next: ExtensionPinsState) {
    guard next != state else { return }
    state = next
    rebuild()
  }

  override func rebuild() {
    subviews.forEach { $0.removeFromSuperview() }
    guard let s = state, bounds.width > 0 else { return }
    let theme = NewTabTheme(dark: s.dark, tokens: s.theme)
    let width = bounds.width
    var y = place(text("Pin Extensions", size: 15, weight: .semibold, color: theme.textPrimary.ns), x: 0, y: 0, width: width)
    y += 4
    y += place(text("Pinned extensions appear in the toolbar, next to the address.", size: 13, color: theme.textSecondary.ns), x: 0, y: y, width: width)
    y += 12
    if s.extensions.isEmpty {
      y += place(text("No extensions are turned on.", size: 13, color: theme.textTertiary.ns), x: 0, y: y, width: width)
    } else {
      let list = NSScrollView(frame: .zero)
      list.drawsBackground = false
      list.hasVerticalScroller = true
      list.autohidesScrollers = true
      list.scrollerStyle = .overlay
      let rows = FlippedView()
      var ry: CGFloat = 0
      for ext in s.extensions {
        let label = NSTextField(labelWithString: ext.name)
        label.font = .systemFont(ofSize: 13)
        label.textColor = theme.textPrimary.ns
        label.lineBreakMode = .byTruncatingTail
        let lh = label.intrinsicContentSize.height
        let rowHeight = max(16, lh) + 12
        let row = PromptPressable(frame: CGRect(x: 0, y: ry, width: width, height: rowHeight))
        let box = NSView(frame: CGRect(x: 0, y: (rowHeight - 14) / 2, width: 14, height: 14))
        box.wantsLayer = true
        box.layer?.cornerRadius = 3.5
        box.layer?.backgroundColor = ext.pinned ? theme.accent.cg : (CSSColor(s.control)?.cg ?? NSColor.white.cgColor)
        box.layer?.borderWidth = ext.pinned ? 0 : 1 / (window?.backingScaleFactor ?? 2) * 2
        box.layer?.borderColor = CSSColor(s.controlBorder)?.cg
        if ext.pinned {
          let check = NSImageView(frame: box.bounds)
          check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
          check.imageScaling = .scaleNone
          check.contentTintColor = .white
          box.addSubview(check)
        }
        row.addSubview(box)
        let icon = NSImageView(frame: CGRect(x: 14 + 10, y: (rowHeight - 16) / 2, width: 16, height: 16))
        icon.image = image(ext.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        row.addSubview(icon)
        let x: CGFloat = 14 + 10 + 16 + 10
        label.frame = CGRect(x: x - 2, y: (rowHeight - lh) / 2, width: max(0, width - x + 4), height: lh)
        row.addSubview(label)
        let id = ext.id, pinned = ext.pinned
        row.onPress = { [weak self] in self?.onEvent(.toggle(id, !pinned)) }
        row.setAccessibilityRole(.checkBox)
        row.setAccessibilityLabel(ext.name)
        row.setAccessibilityValue(ext.pinned ? 1 : 0)
        rows.addSubview(row)
        ry += rowHeight
      }
      rows.frame = CGRect(x: 0, y: 0, width: width, height: ry)
      list.documentView = rows
      let lh = min(ry, 300)
      list.frame = CGRect(x: 0, y: y, width: width, height: lh)
      addSubview(list)
      y += lh
    }
    y += 16
    y += buttons([("Done", true, .done)], top: y, dark: s.dark, theme: theme, goButton: s.goButton, goButtonText: s.goButtonText)
    report(y)
  }
}
