import AppKit
import QuartzCore
import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct SmallBarButtonState: Decodable, Equatable, Sendable {
  public var id: String
  public var icon: String
  public var size: Double
  public var tooltip: String
  public var disabled: Bool?

  public init(id: String, icon: String, size: Double, tooltip: String, disabled: Bool? = nil) {
    self.id = id
    self.icon = icon
    self.size = size
    self.tooltip = tooltip
    self.disabled = disabled
  }
}

public struct SmallBarProfile: Decodable, Equatable, Sendable {
  public var swatch: String
  public var symbol: String?
  public var text: String
  public var emoji: Bool
  public var tooltip: String

  public static func resolve(in state: BrowserState, profileId: String, swatch: (Profile) -> String) -> Self? {
    guard state.profileOrder.count > 1, let profile = state.profiles[profileId] else { return nil }
    let icon = profile.icon
    let symbol = icon.flatMap { $0.hasPrefix("symbol:") ? String($0.dropFirst(7)) : nil }
    return Self(swatch: swatch(profile), symbol: symbol,
      text: icon ?? profile.name.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "?",
      emoji: icon != nil, tooltip: "Profile: \(profile.name)")
  }
}

public struct SmallBarState: Decodable, Equatable, Sendable {
  public var tabId: String?
  public var icon: String
  public var url: String
  public var favicon: String?
  public var profileId: String
  public var host: String
  public var title: String
  public var loading: Bool
  public var progress: Double
  public var hidden: Bool
  public var buttons: [SmallBarButtonState]
  public var profile: SmallBarProfile?
  public var theme: MediaThemeState

  public init(page: SmallBarPage?, facts: SmallBarPageFacts, profileId: String, profile: SmallBarProfile?,
    hidden: Bool, theme: MediaThemeState, product: String) {
    let url = page?.tab.url ?? ""
    self.tabId = page?.id
    self.icon = page?.icon(unsafe: facts.unsafe) ?? "search"
    self.url = url
    self.favicon = page?.tab.favicon
    self.profileId = page?.tab.profileId ?? profileId
    self.host = url.hasPrefix("file:") ? "File" : breadcrumb(url).host
    let customTitle = page?.tab.customTitle ?? ""
    self.title = customTitle.isEmpty ? page?.tab.title ?? "" : customTitle
    self.loading = page?.loading == true
    self.progress = loading ? facts.progress : 0
    self.hidden = hidden || page == nil
    self.buttons = [
      SmallBarButtonState(id: "copy", icon: "link", size: 14, tooltip: "Copy Link (⇧⌘C)", disabled: url.isEmpty),
      SmallBarButtonState(id: "open", icon: "arrow.up.left.and.arrow.down.right", size: 13, tooltip: "Open in \(product) (⌘O)", disabled: page == nil),
    ]
    self.profile = profile
    self.theme = theme
  }

  public static func decode(_ json: String) -> SmallBarState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SmallBarState.self, from: data)
  }
}

public struct SmallBarPage {
  public let tab: Tab
  public let loading: Bool
  public var id: String { tab.id }

  public static func resolve(windowId: String, state: BrowserState, closing: Set<String>) -> Self? {
    guard !closing.contains(windowId), let window = state.windows[windowId], window.isSmall,
      let tab = state.activeTab(windowId), tab.windowId == windowId, tab.profileId == window.profileId,
      window.tabIds.contains(tab.id) else { return nil }
    return Self(tab: tab, loading: state.live[tab.id]?.isLoading == true)
  }

  public func icon(unsafe: Bool) -> String {
    if tab.url.isEmpty { return "search" }
    return unsafe ? "insecure" : "favicon"
  }
}

public struct SmallBarPageFacts: Equatable, Sendable {
  public private(set) var progress = 0.0
  public private(set) var unsafe = false

  public init() {}

  public static let events: Set<String> = ["onProgress", "onSecurity", "onDiscarded", "onCrashed", "onPagePhysicalReplaced"]

  public mutating func receive(_ name: String, _ payload: JSONValue) {
    switch name {
    case "onProgress":
      if let value = payload["progress"]?.number, value.isFinite { progress = min(1, max(0, value)) }
    case "onSecurity":
      let level = payload["chromium"]?.string
      unsafe = level == "warning" || level == "dangerous"
    case "onDiscarded", "onCrashed", "onPagePhysicalReplaced":
      self = Self()
    default: break
    }
  }
}

public enum SmallBarAction: Equatable, Sendable {
  case button(String)
  case fieldClick
  case fieldMenu
  case profile
}

public enum SmallBarCommand: Equatable, Sendable {
  case edit(String)
  case menu
  case copy
  case expand
  case profile

  public static func resolve(_ action: SmallBarAction, windowId: String, tabId: String, state: BrowserState, closing: Set<String>) -> Self? {
    guard let target = ToolbarActionCommand.resolve(windowId: windowId, tabId: tabId, state: state, closing: closing),
      target.small, !target.peek, target.activation == nil else { return nil }
    let url = target.tab.url
    switch action {
    case .fieldClick: return state.windowUi[windowId]?.panelOpen == true ? nil : .edit(url)
    case .fieldMenu: return url.isEmpty || state.windowUi[windowId]?.panelOpen == true ? nil : .menu
    case .button("copy"): return url.isEmpty ? nil : .copy
    case .button("open"): return .expand
    case .profile: return .profile
    default: return nil
    }
  }
}

public enum SmallBarMetrics {
  public static let height: CGFloat = 38
  public static let inset: CGFloat = 6
  public static let button: CGFloat = 28
  public static let buttonGap: CGFloat = 2
  public static let fieldGap: CGFloat = 6
  public static let fieldHeight: CGFloat = 28
  public static let fieldLeft: CGFloat = 84

  public static func fieldFrame(width: CGFloat, buttons: Int) -> CGRect {
    let buttonsWidth = CGFloat(buttons) * button + CGFloat(max(0, buttons - 1)) * buttonGap
    let right = inset + buttonsWidth + fieldGap
    return CGRect(x: fieldLeft, y: height / 2 - fieldHeight / 2, width: max(0, width - fieldLeft - right), height: fieldHeight)
  }
  public static func popupAnchor(width: CGFloat) -> CGRect {
    CGRect(x: max(0, width - inset - button), y: (height - button) / 2, width: button, height: button)
  }

  public static func panelPlacement(width: CGFloat, buttons: Int) -> OmniboxPanelPlacement? {
    let field = fieldFrame(width: width, buttons: buttons)
    guard !field.isEmpty, width > field.minX + 12 else { return nil }
    return OmniboxPanelPlacement(left: field.minX, top: field.minY,
      width: min(max(350, field.width + 137), width - field.minX - 12), from: field)
  }

}

final class SmallBarField: NSView {
  private let plate = CALayer()
  private let icon = TabIconView()
  private let symbol = SymbolView()
  private let host = NSTextField(labelWithString: "")
  private let title = FadeLabel(fontSize: 13)
  private let placeholder = NSTextField(labelWithString: "Search or enter address")
  private let bar = CALayer()
  private var tracking: NSTrackingArea?
  private var down: NSEvent?
  private var state: SmallBarState?
  private var shownProgress: Double?
  private(set) var hovered = false { didSet { if hovered != oldValue { paint() } } }
  var onAction: ((SmallBarAction) -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = 8
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    icon.favicons = MediaImages.favicons
    addSubview(icon)
    addSubview(symbol)
    host.font = .systemFont(ofSize: 13, weight: .medium)
    host.lineBreakMode = .byTruncatingHead
    host.isSelectable = false
    addSubview(host)
    title.fadeWidth = 14
    addSubview(title)
    placeholder.font = .systemFont(ofSize: 13)
    placeholder.lineBreakMode = .byTruncatingTail
    placeholder.isSelectable = false
    addSubview(placeholder)
    bar.actions = SurfaceLayer.noActions
    bar.cornerRadius = 1
    bar.opacity = 0.85
    bar.anchorPoint = CGPoint(x: 0, y: 0)
    layer?.addSublayer(bar)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  func update(_ next: SmallBarState) {
    state = next
    let palette = MediaPalette(next.theme)
    let sidebar = MediaImages.sidebarPalette(next.theme)
    alphaValue = next.hidden ? 0 : 1
    icon.isHidden = next.icon != "favicon"
    symbol.isHidden = next.icon == "favicon"
    if next.icon == "favicon" {
      icon.set(TabIconSpec(url: next.url, favicon: next.favicon, profileId: next.profileId, size: 16), palette: sidebar)
    } else if next.icon == "insecure" {
      symbol.set("lock.open.trianglebadge.exclamationmark.fill", size: 12, color: palette.textSecondary)
    } else {
      symbol.set("magnifyingglass", size: 12, color: palette.placeholder)
    }
    let hasUrl = !next.url.isEmpty
    host.isHidden = !hasUrl
    host.stringValue = next.host
    host.textColor = palette.textPrimary
    title.isHidden = !hasUrl || next.title.isEmpty || next.title == next.host
    title.text = "  \(next.title)"
    title.color = palette.textSecondary
    placeholder.isHidden = hasUrl
    placeholder.textColor = palette.placeholder
    setAccessibilityLabel(hasUrl ? "\(next.host) \(next.title)" : "Search or enter address")
    MediaMotion.setInstantly { bar.backgroundColor = palette.accent.cgColor }
    bar.isHidden = !next.loading
    if next.loading { animateProgress(max(next.progress, 0.08)) } else { shownProgress = nil }
    paint()
    needsLayout = true
  }

  private func animateProgress(_ target: Double) {
    let width = (bounds.width) * 0.96
    let from = shownProgress
    shownProgress = target
    let height: CGFloat = 1.5
    guard let from, from != target else {
      MediaMotion.setInstantly { bar.bounds = CGRect(x: 0, y: 0, width: width * target, height: height) }
      return
    }
    let tween = RNTween(from: from, to: target, start: CACurrentMediaTime(), duration: 0.2, easing: .outQuad)
    let presented = (bar.presentation()?.bounds.width).map { Double($0 / max(1, width)) } ?? from
    let live = RNTween(from: presented, to: target, start: tween.start, duration: 0.2, easing: .outQuad)
    MediaMotion.setInstantly { bar.bounds = CGRect(x: 0, y: 0, width: width * target, height: height) }
    bar.add(MediaMotion.keyframes("bounds.size.width", live) { NSNumber(value: Double(width) * $0) }, forKey: "progress")
  }

  private func paint() {
    guard let state else { return }
    let palette = MediaPalette(state.theme)
    MediaMotion.setInstantly { plate.backgroundColor = hovered ? palette.toolbarHover.cgColor : nil }
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    MediaMotion.setInstantly {
      plate.frame = bounds
      bar.position = CGPoint(x: 8, y: h - 1.5)
      if let p = shownProgress { bar.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.96 * p, height: 1.5) }
    }
    icon.frame = CGRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
    symbol.frame = icon.frame
    let x: CGFloat = 8 + 16 + 8
    let available = max(0, bounds.width - x - 8)
    let hostSize = host.intrinsicContentSize
    let hostWidth = min(ceil(hostSize.width), available * 0.6)
    host.frame = CGRect(x: x - 2, y: ((h - hostSize.height) / 2).rounded(), width: hostWidth + 4, height: hostSize.height)
    title.frame = CGRect(x: x + hostWidth, y: (h - 18) / 2, width: max(0, available - hostWidth), height: 18)
    let ph = placeholder.intrinsicContentSize
    placeholder.frame = CGRect(x: x, y: ((h - ph.height) / 2).rounded(), width: available, height: ph.height)
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
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    down = event
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = down else { return }
    let a = start.locationInWindow, b = event.locationInWindow
    if hypot(b.x - a.x, b.y - a.y) >= 3 {
      down = nil
      window?.performDrag(with: start)
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard down != nil else { return }
    down = nil
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onAction?(.fieldClick) }
  }

  override func rightMouseDown(with event: NSEvent) { onAction?(.fieldMenu) }

  override func accessibilityPerformPress() -> Bool {
    onAction?(.fieldClick)
    return true
  }

  var progressWidth: CGFloat { bar.isHidden ? 0 : (bar.presentation()?.bounds.width ?? bar.bounds.width) }
}

final class SmallBarBadge: NSView {
  private let disc = CALayer()
  private let symbol = SymbolView()
  private let letter = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    disc.actions = SurfaceLayer.noActions
    layer?.addSublayer(disc)
    addSubview(symbol)
    letter.alignment = .center
    letter.textColor = .white
    addSubview(letter)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ profile: SmallBarProfile, size: CGFloat) {
    MediaMotion.setInstantly {
      disc.frame = CGRect(x: 0, y: 0, width: size, height: size)
      disc.cornerRadius = size / 2
      disc.backgroundColor = MediaPalette.parse(profile.swatch)?.cgColor
    }
    symbol.isHidden = profile.symbol == nil
    letter.isHidden = profile.symbol != nil
    if let name = profile.symbol {
      symbol.frame = disc.frame
      symbol.set(name, size: size * 0.5, weight: .semibold, color: .white)
    } else {
      letter.font = .systemFont(ofSize: size * (profile.emoji ? 0.55 : 0.46), weight: .semibold)
      letter.stringValue = profile.text
      let f = letter.fittingSize
      letter.frame = CGRect(x: (size - f.width) / 2, y: (size - f.height) / 2, width: f.width, height: f.height)
    }
  }
}

public final class SmallBarView: NSView {
  public var onAction: ((SmallBarAction) -> Void)?

  private let field = SmallBarField()
  private var buttons: [String: SidebarIconButton] = [:]
  private var order: [String] = []
  private let profileButton = SidebarIconButton()
  private let badge = SmallBarBadge()
  private var state: SmallBarState?
  private var copyReset: Task<Void, Never>?
  private(set) var copied = false

  public var tabId: String? { state?.tabId }

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    field.onAction = { [weak self] in self?.onAction?($0) }
    addSubview(field)
    profileButton.radius = 7
    profileButton.onPress = { [weak self] in self?.onAction?(.profile) }
    profileButton.addSubview(badge)
    addSubview(profileButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(_ next: SmallBarState) {
    if let state, state.tabId != next.tabId || state.profileId != next.profileId || state.url != next.url {
      copyReset?.cancel()
      copyReset = nil
      copied = false
    }
    state = next
    let palette = MediaPalette(next.theme)
    field.update(next)
    let ids = next.buttons.map(\.id)
    for (id, button) in buttons where !ids.contains(id) {
      button.removeFromSuperview()
      buttons[id] = nil
    }
    for spec in next.buttons {
      let button = buttons[spec.id] ?? {
        let made = SidebarIconButton()
        made.radius = 7
        let id = spec.id
        made.onPress = { [weak self, weak made] in
          guard let made, made.alphaValue > 0, self?.state?.buttons.first(where: { $0.id == id })?.disabled != true else { return }
          self?.onAction?(.button(id))
        }
        addSubview(made)
        buttons[spec.id] = made
        return made
      }()
      let disabled = spec.disabled == true
      button.hoverFill = disabled ? .clear : palette.toolbarHover
      button.pressedFill = disabled ? .clear : palette.toolbarPressed
      setIcon(spec, on: button, theme: next.theme, palette: palette)
      button.setAccessibilityElement(true)
      button.setAccessibilityRole(.button)
      button.setAccessibilityLabel(spec.tooltip)
      button.setAccessibilityEnabled(!disabled)
    }
    order = ids
    profileButton.isHidden = next.profile == nil
    if let profile = next.profile {
      profileButton.hoverFill = palette.toolbarHover
      profileButton.pressedFill = palette.toolbarPressed
      profileButton.toolTip = profile.tooltip
      profileButton.setAccessibilityElement(true)
      profileButton.setAccessibilityRole(.button)
      profileButton.setAccessibilityLabel(profile.tooltip)
      badge.set(profile, size: 16)
    }
    needsLayout = true
  }

  public func showCopyConfirmation() {
    guard let state, state.tabId != nil, !state.url.isEmpty else { return }
    copyReset?.cancel()
    setCopied(true)
    copyReset = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1400))
      guard !Task.isCancelled else { return }
      self?.copyReset = nil
      self?.setCopied(false)
    }
  }

  private func setCopied(_ copied: Bool) {
    self.copied = copied
    guard let state, let spec = state.buttons.first(where: { $0.id == "copy" }), let button = buttons[spec.id] else { return }
    setIcon(spec, on: button, theme: state.theme, palette: MediaPalette(state.theme))
  }

  private func setIcon(_ spec: SmallBarButtonState, on button: SidebarIconButton, theme: MediaThemeState, palette: MediaPalette) {
    let ink = spec.disabled == true ? (MediaPalette.parse(theme.colors["iconDisabled"]) ?? palette.textTertiary) : palette.icon
    let icon = spec.id == "copy" && copied ? "checkmark" : spec.icon
    button.set(icon, size: spec.size, weight: .regular, color: ink, tooltip: spec.tooltip)
  }

  public var buttonCount: Int { order.count + (state?.profile == nil ? 0 : 1) }

  public override func layout() {
    super.layout()
    let m = SmallBarMetrics.self
    field.frame = m.fieldFrame(width: bounds.width, buttons: buttonCount)
    var x = bounds.width - m.inset - (CGFloat(buttonCount) * m.button + CGFloat(max(0, buttonCount - 1)) * m.buttonGap)
    let y = m.height / 2 - m.button / 2
    for id in order {
      buttons[id]?.frame = CGRect(x: x, y: y, width: m.button, height: m.button)
      x += m.button + m.buttonGap
    }
    profileButton.frame = CGRect(x: x, y: y, width: m.button, height: m.button)
    badge.frame = CGRect(x: (m.button - 16) / 2, y: (m.button - 16) / 2, width: 16, height: 16)
  }

  public var controlFrames: [String: CGRect] {
    var out = ["field": field.frame, "profile": profileButton.frame]
    for (id, b) in buttons { out[id] = b.frame }
    return out
  }

  public var progressWidth: CGFloat { field.progressWidth }
  public var fieldHovered: Bool { field.hovered }
}
