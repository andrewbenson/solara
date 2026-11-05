import AppKit

@MainActor
final class BookmarksBarButton: NSView {
  static let font = NSFont.systemFont(ofSize: 12)
  private static let labelInset: CGFloat = 2
  var onPress: (_ flags: NSEvent.ModifierFlags, _ middle: Bool) -> Void = { _, _ in }
  var onContext: () -> Void = {}
  var onOpenMenu: () -> Void = {}
  var onKey: (_ key: String, _ flags: NSEvent.ModifierFlags) -> Bool = { _, _ in false }
  #if DEBUG
  var devFullKeyboardAccess: Bool?
  #endif
  var fullKeyboardAccessEnabled: Bool {
    #if DEBUG
    if let devFullKeyboardAccess { return devFullKeyboardAccess }
    #endif
    return NSApp?.isFullKeyboardAccessEnabled ?? false
  }
  var controlId = ""
  var controlKind: BookmarksBarKeyboard.Kind = .link
  var onPointerDown: ((CGPoint) -> Void)?
  var onPointerDrag: ((CGPoint) -> Void)?
  var onPointerUp: ((CGPoint) -> Bool)?
  var highlighted = false { didSet { apply() } }
  var dragging = false { didSet { apply() } }

  private let title = NSTextField(labelWithString: "")
  private let image = NSImageView()
  private var theme: [String: String] = [:]
  private var symbol = ""
  private var faviconKey: String?
  private var faviconTask: Task<Void, Never>?
  private var faviconImage: NSImage?
  private var initial: String?
  private var dark = false
  private var iconSize: CGFloat = 16
  private var hovered = false
  private var pressedButton: Int?
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  var isVisibleControl: Bool { !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0 }
  override var acceptsFirstResponder: Bool {
    BookmarksBarKeyboard.acceptsFocus(fullKeyboardAccess: fullKeyboardAccessEnabled, visible: isVisibleControl)
  }
  override var canBecomeKeyView: Bool { acceptsFirstResponder && super.canBecomeKeyView }
  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSColor.black.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
  }

  override func becomeFirstResponder() -> Bool {
    guard acceptsFirstResponder else { return false }
    needsDisplay = true
    noteFocusRingMaskChanged()
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    noteFocusRingMaskChanged()
    return true
  }

  override func keyDown(with event: NSEvent) {
    let key = Self.keyName(event)
    if onKey(key, event.modifierFlags) { return }
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if key == "Tab", flags.isEmpty || flags == .shift {
      if flags == .shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
      return
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, onKey(Self.keyName(event), event.modifierFlags) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func showContextMenuForSelection(_ sender: Any?) { onContext() }

  override func accessibilityHelp() -> String? { toolTip }

  private static func keyName(_ event: NSEvent) -> String {
    switch event.keyCode {
    case 123: return "Left"
    case 124: return "Right"
    case 115: return "Home"
    case 119: return "End"
    case 36, 76: return "Return"
    case 49: return "Space"
    case 125: return "Down"
    case 109: return "F10"
    case 110: return "ContextMenu"
    case 53: return "Escape"
    case 48: return "Tab"
    default: return event.charactersIgnoringModifiers ?? ""
    }
  }

  var measuredWidth: CGFloat {
    guard !title.stringValue.isEmpty else { return 28 }
    return min(190, ceil((title.stringValue as NSString).size(withAttributes: [.font: Self.font]).width) + iconSize + 6 + 14)
  }

  init() {
    super.init(frame: .zero)
    focusRingType = .default
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = true
    title.font = Self.font
    title.lineBreakMode = .byTruncatingTail
    title.setAccessibilityElement(false)
    image.imageScaling = .scaleProportionallyUpOrDown
    image.setAccessibilityElement(false)
    image.wantsLayer = true
    image.layer?.cornerRadius = 3
    image.layer?.masksToBounds = true
    addSubview(image)
    addSubview(title)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { faviconTask?.cancel() }

  func configure(title: String, symbol: String, folder: Bool, theme: [String: String]) {
    self.title.stringValue = title
    self.symbol = symbol
    self.theme = theme
    pressedButton = nil
    iconSize = symbol == "globe" ? 14 : 16
    setAccessibilityLabel(title)
    setAccessibilityRoleDescription(folder ? "folder" : NSAccessibility.Role.button.description(with: nil))
    toolTip = title
    apply()
    needsLayout = true
  }

  func setFavicon(_ item: BookmarksBarItem?, profileId: String, dark: Bool, favicons: PageFavicons) {
    let key = item?.url.map { PageFavicons.key($0, item?.favicon, profileId, dark: dark) }
    guard key != faviconKey else { return }
    faviconKey = key
    faviconTask?.cancel()
    faviconTask = nil
    faviconImage = nil
    self.dark = dark
    initial = item?.url.flatMap { SettingsFavicon.hostInitial($0) }
    guard let item, let url = item.url else {
      apply()
      return
    }
    faviconImage = favicons.cached(url, item.favicon, profileId, dark: dark) ?? favicons.bundled(url, dark: dark)
    apply()
    faviconTask = Task { [weak self, favicons] in
      let loaded = await favicons.fetch(url, item.favicon, profileId, dark: dark)
      guard !Task.isCancelled, let self, self.faviconKey == key else { return }
      if let loaded { self.faviconImage = loaded }
      self.apply()
    }
  }

  override func layout() {
    super.layout()
    let labeled = !title.stringValue.isEmpty
    image.frame = CGRect(x: labeled ? 7 : (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
    let height = title.fittingSize.height
    let left = 7 + iconSize + 6
    let inset = Self.labelInset
    title.frame = CGRect(x: left - inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - left - 7 + inset * 2), height: height)
    title.isHidden = !labeled
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; apply() }
  override func mouseExited(with event: NSEvent) { hovered = false; apply() }

  @objc private func devPointerChanged(_ note: Notification) { hovered = DevPointer.inside(self, note); apply() }

  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

  override func mouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.mouseDown(with: event) }
    beginPress(at: event.locationInWindow, flags: event.modifierFlags)
  }

  override func mouseDragged(with event: NSEvent) { dragPress(to: event.locationInWindow) }

  override func mouseUp(with event: NSEvent) {
    endPress(at: event.locationInWindow, flags: event.modifierFlags, inside: isHitBy(event) && bounds.contains(convert(event.locationInWindow, from: nil)))
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2, isHitBy(event) else { return super.otherMouseDown(with: event) }
    pressedButton = 2
    apply()
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
    release(event, button: 2)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard isHitBy(event) else { return super.rightMouseDown(with: event) }
    pressedButton = nil
    apply()
    onContext()
  }

  override func accessibilityPerformPress() -> Bool { onPress([], false); return true }
  override func accessibilityPerformShowMenu() -> Bool { onContext(); return true }

  func beginPress(at point: CGPoint, flags: NSEvent.ModifierFlags) {
    if flags.contains(.control) {
      cancelPress()
      onContext()
      return
    }
    pressedButton = 0
    apply()
    onPointerDown?(point)
  }

  func dragPress(to point: CGPoint) {
    guard pressedButton == 0 else { return }
    onPointerDrag?(point)
  }

  func endPress(at point: CGPoint, flags: NSEvent.ModifierFlags, inside: Bool) {
    guard pressedButton == 0 else { return }
    let dragged = onPointerUp?(point) ?? false
    cancelPress()
    if !dragged && inside { onPress(flags, false) }
  }

  func cancelPress() {
    pressedButton = nil
    apply()
  }

  private func release(_ event: NSEvent, button: Int) {
    let wasPressed = pressedButton == button
    pressedButton = nil
    apply()
    guard wasPressed, isHitBy(event), bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onPress(event.modifierFlags, button == 2)
  }

  private func apply() {
    let background = pressedButton != nil && !dragging ? theme["toolbarPressed"] : hovered || highlighted ? theme["toolbarHover"] : nil
    layer?.backgroundColor = toolbarColor(background)?.cgColor
    title.textColor = toolbarColor(theme["textTab"]) ?? .labelColor
    if let faviconImage {
      image.image = faviconImage
      image.contentTintColor = nil
    } else if let initial {
      image.image = Self.initialTile(initial, dark: dark, color: toolbarColor(theme["icon"]) ?? .secondaryLabelColor)
      image.contentTintColor = nil
    } else {
      image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
      image.contentTintColor = toolbarColor(theme["icon"]) ?? .secondaryLabelColor
    }
  }

  private static func initialTile(_ initial: String, dark: Bool, color: NSColor) -> NSImage {
    let side: CGFloat = 14
    let tile: CGFloat = 12
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
      let square = NSRect(x: (side - tile) / 2, y: (side - tile) / 2, width: tile, height: tile)
      let fill = dark ? NSColor(srgbRed: 247 / 255, green: 245 / 255, blue: 1, alpha: 0.2) : NSColor.black.withAlphaComponent(0.13)
      fill.setFill()
      NSBezierPath(roundedRect: square, xRadius: tile * 0.32, yRadius: tile * 0.32).fill()
      let text = NSAttributedString(string: initial, attributes: [.font: NSFont.systemFont(ofSize: (tile * 0.64).rounded(), weight: .semibold), .foregroundColor: color])
      let size = text.size()
      text.draw(at: NSPoint(x: square.midX - size.width / 2, y: square.midY - size.height / 2))
      return true
    }
  }
}
