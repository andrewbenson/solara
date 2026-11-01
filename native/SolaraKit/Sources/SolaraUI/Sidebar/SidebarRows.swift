import AppKit
import SolaraModel
import SolaraStore

public struct SidebarClickMods: Equatable, Sendable {
  public var meta = false
  public var shift = false
  public var alt = false

  public var none: Bool { !meta && !shift && !alt }

  init(_ flags: NSEvent.ModifierFlags) {
    meta = flags.contains(.command)
    shift = flags.contains(.shift)
    alt = flags.contains(.option)
  }
}

public enum SidebarAction: Sendable {
  case click(tabId: String, mods: SidebarClickMods)
  case close(tabId: String)
  case middleClick(tabId: String)
  case rename(kind: String, id: String)
  case backToPinned(tabId: String)
  case tileDoubleClick(tabId: String)
  case toggleMute(tabId: String)
  case tabMenu(tabId: String)
  case groupMenu(groupId: String)
  case toggleGroup(groupId: String)
  case closeGroup(groupId: String)
  case sidebarMenu
  case overflowMenu
  case newTab(split: Bool)
  case newTabDoubleClick
  case folder(folderId: String)
  case folderMenu(folderId: String)
  case tidy
  case clear
  case renamed(kind: String, id: String, text: String?)
  case hover(kind: String?, id: String?)
  case scrolled
  case live(action: String, folderId: String, id: String?, meta: Bool)
  case media(tabId: String, action: MediaAction)
  case cleanUp(SidebarCleanUpChoice)
}

@MainActor
final class SidebarContext {
  var state: BrowserState
  var query: SidebarQuery
  var host: SidebarHostState
  var flags: SidebarFlags
  var palette: SidebarPalette
  var windowId: String
  var activeId: String?
  let showClear: Bool
  let favicons: SidebarFavicons
  var live: SidebarLiveBlocks?
  var send: (SidebarAction) -> Void = { _ in }

  let paletteGeneration: Int

  init(state: BrowserState, host: SidebarHostState, windowId: String, favicons: SidebarFavicons, previous: SidebarContext? = nil) {
    self.state = state
    query = SidebarQuery(state)
    self.host = host
    if let previous, previous.host == host {
      flags = previous.flags
    } else {
      flags = SidebarFlags(host)
    }
    if let previous, previous.host.dark == host.dark, previous.host.theme == host.theme, previous.host.border == host.border, previous.host.glow == host.glow {
      palette = previous.palette
      paletteGeneration = previous.paletteGeneration
    } else {
      palette = SidebarPalette(host)
      paletteGeneration = (previous?.paletteGeneration ?? 0) + 1
    }
    self.windowId = windowId
    activeId = state.activeTabId(windowId, host.profileId)
    showClear = host.clear
    self.favicons = favicons
  }

  func title(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if !tab.title.isEmpty { return tab.title }
    guard !tab.url.isEmpty else { return "New Tab" }
    var label = tab.url.replacingOccurrences(of: #"^[a-zA-Z][\w+.-]*://"#, with: "", options: .regularExpression)
    if label.hasPrefix("www.") { label.removeFirst(4) }
    if label.hasSuffix("/") { label.removeLast() }
    return label.isEmpty ? "New Tab" : label
  }

  func iconSpec(_ tab: Tab, size: CGFloat = 16) -> TabIconSpec {
    let unloaded = state.settings.bool("fadeUnloadedTabs") && query.pageUnloaded(tab.id)
    return TabIconSpec(
      url: tab.url, favicon: tab.favicon, customIcon: tab.customIcon, profileId: tab.profileId, size: size,
      dimmed: flags.sleeping.contains(tab.id) || unloaded, engineSymbol: host.engines[tab.id])
  }
}

@MainActor
class SidebarRowView: NSView {
  var item: SidebarItem?
  weak var context: SidebarContext?
  let body = NSView()
  var hovered = false { didSet { if hovered != oldValue { repaint() } } }
  var pressed = false { didSet { if pressed != oldValue { pressChanged() } } }
  var hoverKey: String { item?.key ?? "" }
  var pressScales: Bool { true }
  private(set) var retired = false

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    body.wantsLayer = true
    addSubview(body)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc var onMouseEnter: Any? { self }

  override func mouseEntered(with event: NSEvent) { hoverHost?.pointerEntered(self) }
  override func mouseExited(with event: NSEvent) { hoverHost?.pointerExited(self) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if retired { return nil }
    let hit = super.hitTest(point)
    return hit === body ? self : hit
  }

  func retire() {
    retired = true
    retiredLook()
  }

  func retiredLook() {}

  var hoverHost: SidebarView? {
    var view = superview
    while let v = view {
      if let host = v as? SidebarView { return host }
      view = v.superview
    }
    return nil
  }

  override func layout() {
    super.layout()
    body.frame = bounds
    layoutBody()
  }

  private var rendered: AnyHashable?

  func update(_ item: SidebarItem, _ context: SidebarContext) {
    let key = renderKey(item, context)
    if let key, key == rendered, item == self.item {
      self.context = context
      return
    }
    let resized = self.item?.frame.size != item.frame.size
    self.item = item
    self.context = context
    rendered = key
    render()
    if resized { needsLayout = true }
  }

  func renderKey(_ item: SidebarItem, _ context: SidebarContext) -> AnyHashable? { nil }

  func render() {}
  func repaint() {}
  func layoutBody() {}
  func click(_ mods: SidebarClickMods, count: Int) {}
  func middleClick() {}
  func contextMenu() { context?.send(.sidebarMenu) }
  var hoverTarget: (kind: String, id: String)? { nil }
  var accessibleTitle: String? { nil }

  override func isAccessibilityElement() -> Bool { !retired && accessibleTitle != nil }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { accessibleTitle }

  override func accessibilityPerformPress() -> Bool {
    guard !retired, accessibleTitle != nil else { return false }
    click(SidebarClickMods([]), count: 1)
    return true
  }

  override func accessibilityPerformShowMenu() -> Bool {
    guard !retired, accessibleTitle != nil else { return false }
    contextMenu()
    return true
  }

  func pointerMoved() {}

  private func pressChanged() {
    repaint()
    if pressScales { PressFeedback.apply(body, pressed: pressed) }
  }

  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) {
      hoverHost?.dismissHover()
      return contextMenu()
    }
    if let host = hoverHost { SidebarDragController.of(host).press(self, event) }
    pressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    if let host = hoverHost, SidebarDragController.of(host).dragged(self, event) {
      pressed = false
      return
    }
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    if let host = hoverHost, SidebarDragController.of(host).release(self, event) {
      pressed = false
      return
    }
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    let wasPressed = pressed
    pressed = false
    guard inside, wasPressed else { return }
    hoverHost?.dismissHover()
    click(SidebarClickMods(event.modifierFlags), count: event.clickCount)
  }

  override func rightMouseDown(with event: NSEvent) {
    hoverHost?.dismissHover()
    contextMenu()
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.otherMouseUp(with: event) }
    middleClick()
  }
}

final class TabRowView: SidebarRowView {
  private let surface = SurfaceLayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: 13)
  private var back: SymbolView?
  private var audio: SidebarIconButton?
  private var badges: TabMediaBadgesView?
  private var closeButton: SidebarIconButton?
  private var spinner: SpinnerView?
  private var subtitle: FadeLabel?

  override var accessibleTitle: String? {
    guard let tab, let context else { return nil }
    let title = context.title(tab)
    return TabIconSpec.engineName(context.host.engines[tab.id]).map { "\(title), Opens in \($0)" } ?? title
  }
  private var developerRing: (gap: CAShapeLayer, dash: CAShapeLayer)?
  private var closeLook: (symbol: String, tooltip: String) = ("xmark", "Close Tab")
  private var developer = false
  private var tab: Tab?
  private var active = false
  private var selected = false
  private var loading = false
  private var showsAudio = false
  private var resettable = false
  private var resetting = false
  private var rename: SidebarRenameField?

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.layer?.addSublayer(surface)
    surface.radius = SidebarMetrics.rowRadius
    for view in [icon, label] as [NSView] { body.addSubview(view) }
  }

  required init?(coder: NSCoder) { fatalError() }

  private func attached<View: NSView>(_ view: inout View?, _ make: () -> View) -> View {
    if let view { return view }
    let made = make()
    body.addSubview(made)
    view = made
    needsLayout = true
    return made
  }

  private func makeClose() -> SidebarIconButton {
    let button = SidebarIconButton()
    button.radius = 6
    button.onPress = { [weak self] in
      guard let self, let id = self.tab?.id else { return }
      self.context?.send(.close(tabId: id))
    }
    return button
  }

  private func makeAudio() -> SidebarIconButton {
    let button = SidebarIconButton()
    button.radius = 0
    button.onPress = { [weak self] in
      guard let self, let id = self.tab?.id else { return }
      self.context?.send(.toggleMute(tabId: id))
    }
    return button
  }

  private func makeDeveloperRing() -> (gap: CAShapeLayer, dash: CAShapeLayer) {
    let ring = (gap: CAShapeLayer(), dash: CAShapeLayer())
    for (shape, color) in [(ring.gap, NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)), (ring.dash, NSColor(srgbRed: 0xF5 / 255, green: 0xC5 / 255, blue: 0x2A / 255, alpha: 1))] {
      shape.fillColor = nil
      shape.strokeColor = color.cgColor
      shape.lineWidth = 2
      shape.actions = SurfaceLayer.noActions
      body.layer?.addSublayer(shape)
    }
    ring.dash.lineDashPattern = [6, 6]
    needsLayout = true
    return ring
  }

  var tabId: String? { tab?.id }

  override func retiredLook() {
    active = false
    selected = false
    repaint()
  }

  private struct Inputs: Hashable {
    let tab: Tab
    let active, selected, loading, playing, developer, sleeping, renaming, resettable, faded, pip: Bool
    let capture: TabCapture?
    let closeKind: String
    let engine, closeHint: String?
    let palette: Int
    let mark: ObjectIdentifier?

    func hash(into hasher: inout Hasher) { hasher.combine(tab.id) }
  }

  override func renderKey(_ item: SidebarItem, _ context: SidebarContext) -> AnyHashable? {
    guard case .tab(let id) = item.kind, let tab = context.state.tabs[id] else { return nil }
    let flags = context.flags
    return Inputs(
      tab: tab, active: context.activeId == id, selected: flags.selection.contains(id), loading: flags.loading.contains(id),
      playing: flags.playing.contains(id), developer: flags.developer.contains(id), sleeping: flags.sleeping.contains(id),
      renaming: context.host.renaming == "tab:\(id)", resettable: context.query.awayFromPinnedUrl(id),
      faded: context.state.settings.bool("fadeUnloadedTabs") && context.query.pageUnloaded(id),
      pip: flags.pip.contains(id), capture: flags.capture[id],
      closeKind: "\(context.query.closeKind(id))", engine: context.host.engines[id], closeHint: context.host.closeHint,
      palette: context.paletteGeneration, mark: context.favicons.newTabMark.map(ObjectIdentifier.init))
  }

  override func render() {
    guard let context, case .tab(let id)? = item?.kind, let tab = context.state.tabs[id] else { return }
    self.tab = tab
    active = context.activeId == id
    selected = context.flags.selection.contains(id)
    loading = context.flags.loading.contains(id)
    showsAudio = context.flags.playing.contains(id) || tab.muted
    resettable = context.query.awayFromPinnedUrl(id)
    developer = context.flags.developer.contains(id)
    let palette = context.palette
    if developer {
      let subtitle = attached(&subtitle) { FadeLabel(fontSize: 11) }
      subtitle.isHidden = false
      subtitle.text = URL(string: tab.url).map { url in url.port.map { "\(url.host() ?? ""):\($0)" } ?? url.host() ?? "" } ?? ""
      subtitle.color = palette.textSecondary
    } else {
      subtitle?.isHidden = true
    }
    icon.favicons = context.favicons
    icon.set(context.iconSpec(tab), palette: palette)
    TabMediaBadgesView.attach(&badges, to: body, flags: context.flags, tabId: id, host: context.host, palette: palette)
    badges?.frame = icon.frame
    label.text = context.host.renaming == "tab:\(id)" ? "" : context.title(tab)
    if (context.host.renaming == "tab:\(id)") != (rename != nil) { needsLayout = true }
    if showsAudio {
      let audio = attached(&audio, makeAudio)
      audio.set(tab.muted ? "speaker.slash" : "speaker.wave.2", size: 12, weight: .regular, color: palette.textTab, tooltip: tab.muted ? "Unmute Site" : "Mute Site")
      audio.isHidden = false
    } else {
      audio?.isHidden = true
    }
    let kind = context.query.closeKind(id)
    let closeTip = kind == .removePin ? "Remove Pinned Tab" : (kind == .unload ? "Unload Tab" : "Close Tab") + (context.host.closeHint.map { "  \($0)" } ?? "")
    closeLook = (kind == .unload ? "minus" : "xmark", closeTip)
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    let fill: NSColor = (!active && pressed) ? palette.pressed : active ? palette.selected : selected ? palette.multiSelected : hovered ? palette.hover : .clear
    surface.fill = fill
    surface.border = active || selected ? 0.5 : 0
    surface.borderColors = active ? palette.selectedBorder : []
    surface.borderTint = selected && !active ? palette.multiSelectedStroke : nil
    surface.glowColor = active ? palette.glowColor : nil
    surface.glowOpacity = active ? palette.glowOpacity : 0
    surface.glowRadius = palette.glowRadius
    label.color = active ? palette.selectedText : palette.textTab
    let ringShown = developer && active
    if ringShown || developerRing != nil {
      let ring = developerRing ?? makeDeveloperRing()
      developerRing = ring
      ring.gap.isHidden = !ringShown
      ring.dash.isHidden = !ringShown
    }
    let renaming = context.host.renaming == "tab:\(tab?.id ?? "")"
    let closeShown = hovered && !renaming
    if closeShown {
      let close = attached(&closeButton, makeClose)
      close.set(closeLook.symbol, size: 10, weight: .semibold, color: palette.icon, tooltip: closeLook.tooltip)
      close.hoverFill = palette.toolbarHover
      close.pressedFill = palette.toolbarPressed
      close.isHidden = false
    } else {
      closeButton?.isHidden = true
    }
    if loading && !closeShown {
      attached(&spinner) { SpinnerView() }.isHidden = false
    } else if let spinner {
      spinner.removeFromSuperview()
      self.spinner = nil
    }
    resetting = resettable && hovered && backHovered && !renaming
    if resetting {
      let back = attached(&back) { SymbolView() }
      back.set("arrow.uturn.backward", size: 11, weight: .semibold, color: active ? palette.selectedText : palette.textTab)
      back.isHidden = false
    } else {
      back?.isHidden = true
    }
    icon.isHidden = resetting
    if resetting { label.text = "Back to Pinned URL" } else if let tab, !renaming { label.text = context.title(tab) }
    if closeShown { closeButton?.syncHover() }
    let shape = [!closeShown, loading, showsAudio, developer]
    if shape != laidOutShape {
      laidOutShape = shape
      needsLayout = true
    }
  }

  private var laidOutShape: [Bool] = []

  private var backHovered: Bool {
    guard let window else { return false }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return NSRect(x: 9, y: 9, width: 16, height: 16).contains(point)
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    var x: CGFloat = 9
    icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
    back?.frame = icon.frame
    badges?.frame = icon.frame
    x += 16
    if showsAudio {
      x += 6
      audio?.frame = NSRect(x: x, y: (h - 16) / 2, width: 18, height: 16)
      x += 18
    }
    x += 5
    let right = bounds.width - 6
    let closeShown = closeButton.map { !$0.isHidden } ?? false
    let slot: CGFloat = closeShown ? 22 : (loading ? 14 : 0)
    closeButton?.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22)
    spinner?.frame = NSRect(x: right - 14, y: (h - 12) / 2, width: 12, height: 12)
    let titleWidth = max(0, right - slot - x)
    if developer {
      label.frame = NSRect(x: x, y: (h - 30) / 2 + 14, width: titleWidth, height: 16)
      subtitle?.frame = NSRect(x: x, y: (h - 30) / 2, width: titleWidth, height: 14)
    } else {
      label.frame = NSRect(x: x, y: (h - 18) / 2, width: titleWidth, height: 18)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let ring = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: SidebarMetrics.rowRadius - 1, cornerHeight: SidebarMetrics.rowRadius - 1, transform: nil)
    for shape in [developerRing?.gap, developerRing?.dash].compactMap({ $0 }) {
      shape.frame = bounds
      shape.path = ring
    }
    CATransaction.commit()
    if let tab, let context {
      let active = self.active
      syncRename(
        context.host.renaming == "tab:\(tab.id)", kind: "tab", id: tab.id, frame: label.frame.insetBy(dx: 0, dy: -1),
        initial: tab.customTitle ?? tab.title, placeholder: tab.title.isEmpty ? "Tab name" : tab.title, font: .systemFont(ofSize: 13),
        color: active ? context.palette.selectedText : context.palette.textPrimary, field: &rename)
    }
  }

  override func pointerMoved() {
    guard resettable else { return }
    let now = resettable && backHovered
    if now != resetting { repaint() }
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context, let id = tab?.id else { return }
    if resetting {
      context.send(.backToPinned(tabId: id))
      return
    }
    context.send(.click(tabId: id, mods: mods))
    if count == 2 { context.send(.rename(kind: "tab", id: id)) }
  }

  override func middleClick() {
    guard let id = tab?.id else { return }
    context?.send(.middleClick(tabId: id))
  }

  override var hoverTarget: (kind: String, id: String)? {
    guard let id = tab?.id, context?.host.renaming != "tab:\(id)" else { return nil }
    return ("tab", id)
  }

  override func contextMenu() {
    guard let id = tab?.id else { return }
    context?.send(.tabMenu(tabId: id))
  }
}

final class SplitPaneView: NSView {
  let tabId: String
  private let plate = CALayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: 12)
  var hovered = false
  var pressed = false

  override var isFlipped: Bool { true }

  init(tabId: String) {
    self.tabId = tabId
    super.init(frame: .zero)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = 7
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    addSubview(icon)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func render(_ context: SidebarContext) {
    guard let tab = context.state.tabs[tabId] else { return }
    let active = context.activeId == tabId
    icon.favicons = context.favicons
    icon.set(context.iconSpec(tab, size: 14), palette: context.palette)
    label.text = context.title(tab)
    label.color = active ? context.palette.selectedText : context.palette.textTab
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = active ? nil : (pressed ? context.palette.pressed : hovered ? context.palette.rowHover : .clear).cgColor
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    icon.frame = NSRect(x: 6, y: (h - 14) / 2, width: 14, height: 14)
    label.frame = NSRect(x: 25, y: (h - 16) / 2, width: max(0, bounds.width - 25), height: 16)
  }
}

final class SplitRowView: SidebarRowView {
  private let surface = SurfaceLayer()
  private var panes: [SplitPaneView] = []
  private var dividers: [CALayer] = []
  private var active = false
  private var pressedPane: String?

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.layer?.addSublayer(surface)
    surface.radius = SidebarMetrics.rowRadius
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context, case .split(let id)? = item?.kind else { return }
    let ids = context.query.splitPanes(id)
    if panes.map(\.tabId) != ids {
      panes.forEach { $0.removeFromSuperview() }
      dividers.forEach { $0.removeFromSuperlayer() }
      panes = ids.map { SplitPaneView(tabId: $0) }
      dividers = ids.dropFirst().map { _ in
        let line = CALayer()
        line.actions = SurfaceLayer.noActions
        return line
      }
      panes.forEach { body.addSubview($0) }
      dividers.forEach { body.layer?.addSublayer($0) }
      needsLayout = true
    }
    let wasActive = active
    active = ids.contains(context.activeId ?? "")
    if active != wasActive { needsLayout = true }
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    surface.fill = active ? palette.selected : hovered ? palette.hover : .clear
    surface.border = active ? 1 : 0
    surface.borderColors = active ? palette.selectedBorder : []
    surface.glowColor = active ? palette.glowColor : nil
    surface.glowOpacity = active ? palette.glowOpacity : 0
    surface.glowRadius = palette.glowRadius
    let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    for pane in panes {
      pane.hovered = hovered && point.map { pane.frame.contains($0) } == true
      pane.pressed = pressedPane == pane.tabId && pressed
      pane.render(context)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for line in dividers { line.backgroundColor = palette.divider.cgColor }
    CATransaction.commit()
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    let pad: CGFloat = active ? 2 : 3
    let inner = bounds.width - pad * 2
    let count = CGFloat(max(panes.count, 1))
    let share = inner / count
    for (i, pane) in panes.enumerated() {
      var x = pad + CGFloat(i) * share
      var width = share
      if i > 0 {
        dividers[i - 1].frame = CGRect(x: x, y: (bounds.height - 16) / 2, width: 1, height: 16)
        x += 3
        width -= 3
      }
      pane.frame = NSRect(x: x, y: 3, width: width, height: bounds.height - 6)
    }
    CATransaction.commit()
  }

  override func pointerMoved() {
    repaint()
    hoverHost?.hoverTargetMoved()
  }

  override var hoverTarget: (kind: String, id: String)? { hoveredPaneId.map { ("tab", $0) } }

  private func pane(at event: NSEvent) -> SplitPaneView? {
    let point = body.convert(event.locationInWindow, from: nil)
    return panes.first { $0.frame.insetBy(dx: -1.5, dy: -3).contains(point) }
  }

  override func mouseDown(with event: NSEvent) {
    pressedPane = pane(at: event)?.tabId
    if event.modifierFlags.contains(.control) {
      hoverHost?.dismissHover()
      return contextMenu()
    }
    if let host = hoverHost { SidebarDragController.of(host).press(self, event) }
    pressed = pressedPane != nil
    if let pane = pane(at: event) { PressFeedback.apply(pane, pressed: true) }
  }

  override func mouseUp(with event: NSEvent) {
    let target = pane(at: event)
    if let id = pressedPane, let pane = panes.first(where: { $0.tabId == id }) { PressFeedback.apply(pane, pressed: false) }
    if let host = hoverHost, SidebarDragController.of(host).release(self, event) {
      pressed = false
      return
    }
    let wasPressed = pressed
    pressed = false
    guard wasPressed, let target, target.tabId == pressedPane else { return }
    hoverHost?.dismissHover()
    context?.send(.click(tabId: target.tabId, mods: SidebarClickMods(event.modifierFlags)))
  }

  override func rightMouseDown(with event: NSEvent) {
    pressedPane = pane(at: event)?.tabId
    hoverHost?.dismissHover()
    contextMenu()
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, let target = pane(at: event) else { return super.otherMouseUp(with: event) }
    context?.send(.middleClick(tabId: target.tabId))
  }

  override func contextMenu() {
    guard let id = pressedPane ?? panes.first?.tabId else { return }
    context?.send(.tabMenu(tabId: id))
  }

  var hoveredPaneId: String? {
    guard hovered, let window else { return nil }
    let point = body.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return panes.first { $0.frame.contains(point) }?.tabId
  }
}

final class GroupHeaderView: SidebarRowView {
  private let surface = SurfaceLayer()
  private let icon = TabIconView()
  private let label = FadeLabel(fontSize: 13, weight: .medium)
  private let chevron = SymbolView()
  private let closeButton = SidebarIconButton()
  private let titleBox = NSView()
  private let meetingLabel = NSTextField(labelWithString: "")
  private var meetingTick: Timer?
  private var groupId = ""
  private var collapsed = false
  private var hasIcon = false
  private var closeable = false
  private var rename: SidebarRenameField?

  override var pressScales: Bool { false }
  override var accessibleTitle: String? { label.text }

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.layer?.addSublayer(surface)
    surface.radius = 11.5
    titleBox.wantsLayer = true
    for view in [label, chevron] as [NSView] { titleBox.addSubview(view) }
    meetingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    meetingLabel.alignment = .right
    meetingLabel.isHidden = true
    for view in [icon, titleBox, meetingLabel, closeButton] as [NSView] { body.addSubview(view) }
    chevron.wantsLayer = true
    closeButton.onPress = { [weak self] in
      guard let self else { return }
      self.context?.send(.closeGroup(groupId: self.groupId))
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { stopMeetingTick() }
  }

  override func render() {
    guard let context, case .groupHeader(let id)? = item?.kind, let group = context.state.groups[id] else { return }
    if (context.host.renaming == "group:\(id)") != (rename != nil) { needsLayout = true }
    let wasCollapsed = collapsed
    let first = groupId != id
    groupId = id
    collapsed = group.collapsed == true
    let palette = context.palette
    let firstTab = group.tabIds.first.flatMap { context.state.tabs[$0] }
    hasIcon = group.icon != nil || firstTab != nil
    icon.isHidden = !hasIcon
    icon.favicons = context.favicons
    icon.set(
      TabIconSpec(url: firstTab?.url ?? "", favicon: firstTab?.favicon, customIcon: group.icon ?? firstTab?.customIcon, profileId: firstTab?.profileId ?? context.host.profileId),
      palette: palette)
    let title = context.host.renaming == "group:\(id)" ? "" : context.query.groupLabel(id)
    if title != label.text { needsLayout = true }
    label.text = title
    label.color = palette.groupTitle
    chevron.set("chevron.down", size: 9, weight: .semibold, color: palette.groupTitle.withAlphaComponent(palette.groupTitle.alphaComponent * 0.5))
    let control = context.query.groupClose(id)
    closeable = control != nil
    closeButton.set(control == .unload ? "minus" : "xmark", size: 10, weight: .semibold, color: palette.icon, tooltip: control == .unload ? "Unload Tabs" : "Close Group")
    closeButton.hoverFill = palette.toolbarHover
    closeButton.pressedFill = palette.toolbarPressed
    if first || wasCollapsed != collapsed { rotateChevron(animated: !first) }
    renderMeeting()
    repaint()
  }

  private func renderMeeting() {
    guard let context else { return }
    let meeting = SidebarLiveFeed.shared.live?.state.meetingGroups[groupId]
    let countdown = SidebarMeetingCountdown(meeting, now: Date().timeIntervalSince1970 * 1000)
    let text = countdown.label ?? ""
    if text != meetingLabel.stringValue {
      meetingLabel.stringValue = text
      needsLayout = true
    }
    meetingLabel.textColor = countdown.urgent ? SidebarMeetingCountdown.nowColor(dark: context.palette.dark) : context.palette.textSecondary
    if let left = countdown.minutesLeft {
      if meetingTick == nil {
        meetingTick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.renderMeeting() }
        }
      }
      if SidebarMeetingCountdown.dueWiggles(groupId: groupId, minutesLeft: left, done: &SidebarMeetingCountdown.wiggled), let layer = titleBox.layer {
        layer.add(SidebarMeetingCountdown.wiggle(around: titleBox.bounds.size), forKey: "wiggle")
      }
    } else {
      stopMeetingTick()
    }
    let renaming = context.host.renaming == "group:\(groupId)"
    meetingLabel.isHidden = text.isEmpty || renaming || (hovered && closeable)
  }

  private func stopMeetingTick() {
    meetingTick?.invalidate()
    meetingTick = nil
  }

  private func rotateChevron(animated: Bool) {
    guard let layer = chevron.layer else { return }
    let angle: CGFloat = collapsed ? -.pi / 2 : 0
    let size = chevron.bounds.size
    var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
    t = CATransform3DRotate(t, angle, 0, 0, 1)
    t = CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
    layer.sublayerTransform = t
    guard animated else { return }
    let turn = CABasicAnimation(keyPath: "sublayerTransform")
    turn.fromValue = NSValue(caTransform3D: from)
    turn.toValue = NSValue(caTransform3D: t)
    turn.duration = 0.15
    turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
    layer.add(turn, forKey: "fold")
  }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    surface.fill = pressed ? palette.pressed : hovered ? palette.groupHeaderHover : .clear
    let renaming = context.host.renaming == "group:\(groupId)"
    closeButton.isHidden = !(hovered && !renaming && closeable)
    if !closeButton.isHidden { closeButton.syncHover() }
    meetingLabel.isHidden = meetingLabel.stringValue.isEmpty || renaming || !closeButton.isHidden
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surface.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    icon.frame = NSRect(x: 9, y: (h - 16) / 2, width: 16, height: 16)
    let x: CGFloat = 9 + 16 + 5
    let right = bounds.width - 6
    closeButton.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22)
    let meetingWidth = meetingLabel.stringValue.isEmpty ? 0 : ceil(meetingLabel.fittingSize.width)
    let slot = max(22, meetingWidth + 4)
    meetingLabel.frame = NSRect(x: right - 4 - meetingWidth, y: (h - meetingLabel.fittingSize.height) / 2, width: meetingWidth, height: meetingLabel.fittingSize.height)
    let room = max(0, right - slot - x - 10)
    let textWidth = min(room, label.textWidth + 8)
    titleBox.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - slot - x), height: 18)
    label.frame = NSRect(x: 0, y: 0, width: textWidth, height: 18)
    chevron.frame = NSRect(x: textWidth - FadeLabel.cellPadding, y: 4, width: 10, height: 10)
    rotateChevron(animated: false)
    if let context, let group = context.state.groups[groupId] {
      let editing = context.host.renaming == "group:\(groupId)"
      chevron.isHidden = editing
      syncRename(
        editing, kind: "group", id: groupId, frame: NSRect(x: x, y: (h - 20) / 2, width: max(0, right - 22 - x), height: 20),
        initial: group.name, placeholder: context.query.groupLabel(groupId), font: .systemFont(ofSize: 13, weight: .medium),
        color: context.palette.groupTitle, field: &rename)
    }
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context else { return }
    if context.host.renaming != "group:\(groupId)" { context.send(.toggleGroup(groupId: groupId)) }
    if count == 2 { context.send(.rename(kind: "group", id: groupId)) }
  }

  override func contextMenu() { context?.send(.groupMenu(groupId: groupId)) }

  override var hoverTarget: (kind: String, id: String)? {
    collapsed && context?.host.renaming != "group:\(groupId)" ? ("group", groupId) : nil
  }
}

final class GroupBoxView: NSView {
  private let box = CALayer()
  var fill: CALayer { box }
  private var groupId = ""
  private var shown = false
  var item: SidebarItem?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    box.cornerRadius = SidebarMetrics.groupRadius
    box.cornerCurve = .continuous
    box.borderWidth = SidebarMetrics.groupBorder
    box.opacity = 0
    box.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
    layer?.addSublayer(box)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(_ item: SidebarItem, _ context: SidebarContext) {
    self.item = item
    guard case .groupBox(let id) = item.kind, let group = context.state.groups[id] else { return }
    groupId = id
    let surface = context.palette.groupSurface(group.color)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.backgroundColor = surface.fill.cgColor
    box.borderColor = surface.stroke.cgColor
    CATransaction.commit()
  }

  func show(_ on: Bool, animated: Bool) {
    guard on != shown else { return }
    shown = on
    let target: Float = on ? 1 : 0
    let from = box.presentation()?.opacity ?? box.opacity
    box.opacity = target
    guard animated else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = target
    fade.duration = on ? 0.12 : 0.16
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    box.add(fade, forKey: "boxOpacity")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = bounds
    CATransaction.commit()
  }
}

final class NewTabRowView: SidebarRowView {
  private let plate = CALayer()
  private let plus = SymbolView()
  private let label = FadeLabel(fontSize: 13)
  private let hint = NSTextField(labelWithString: "")
  private let overflow = SidebarIconButton()

  override var accessibleTitle: String? { label.text }

  override init(frame: NSRect) {
    super.init(frame: frame)
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarMetrics.rowRadius
    plate.cornerCurve = .continuous
    body.layer?.addSublayer(plate)
    for view in [plus, label] as [NSView] { body.addSubview(view) }
    hint.font = .systemFont(ofSize: 11)
    addSubview(hint)
    addSubview(overflow)
    label.text = "New Tab"
    overflow.onPress = { [weak self] in self?.context?.send(.overflowMenu) }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context else { return }
    let palette = context.palette
    plus.set("plus", size: 13, weight: .medium, color: palette.newTabIcon)
    label.color = palette.newTabLabel
    hint.stringValue = "\(context.host.cleaned) cleaned"
    hint.textColor = palette.textTertiary
    overflow.hoverFill = palette.toolbarHover
    overflow.pressedFill = palette.toolbarPressed
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.backgroundColor = (pressed ? palette.pressed : hovered ? palette.hover : .clear).cgColor
    CATransaction.commit()
    overflow.set("chevron.down", size: 10, weight: .semibold, color: hovered ? palette.textSecondary : palette.textTertiary, tooltip: "Open and recently closed tabs")
    needsLayout = true
  }

  override func layoutBody() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    CATransaction.commit()
    let h = bounds.height
    plus.frame = NSRect(x: 9, y: (h - 16) / 2, width: 16, height: 16)
    label.frame = NSRect(x: 30, y: (h - 18) / 2, width: max(0, bounds.width - 34 - 30), height: 18)
    let right = bounds.width - 6
    overflow.frame = NSRect(x: right - 22, y: (h - 22) / 2, width: 22, height: 22)
    let hintSize = hint.fittingSize
    let fits = 30 + label.textWidth + 8 + hintSize.width <= bounds.width - 34
    hint.isHidden = !(hovered && (context?.host.cleaned ?? 0) > 0 && fits)
    hint.frame = NSRect(x: right - 22 - 2 - hintSize.width, y: (h - hintSize.height) / 2, width: hintSize.width, height: hintSize.height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if overflow.frame.contains(local) { return overflow }
    return bounds.contains(local) ? self : nil
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    context?.send(.newTab(split: mods.alt))
  }
}

final class DividerRowView: SidebarRowView {
  private let line = CALayer()
  private let tidyButton = DividerButton(title: "Tidy", symbol: "sparkles", iconWidth: 10)
  private let clearButton = DividerButton(title: "Clear", symbol: "arrow.down", iconWidth: 8)
  private let gap = CALayer()
  private var reveal: CGFloat = 0

  override var pressScales: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    line.actions = SurfaceLayer.noActions
    gap.actions = SurfaceLayer.noActions
    body.layer?.addSublayer(line)
    body.layer?.addSublayer(gap)
    body.addSubview(tidyButton)
    body.addSubview(clearButton)
    tidyButton.onPress = { [weak self] in self?.context?.send(.tidy) }
    clearButton.onPress = { [weak self] in self?.context?.send(.clear) }
    tidyButton.describe("Tidy pinned tabs")
    clearButton.describe("Clear unpinned tabs")
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}

  override func render() {
    guard let context else { return }
    if tidyButton.isHidden == context.host.tidy || clearButton.isHidden == context.host.clear { needsLayout = true }
    tidyButton.isHidden = !context.host.tidy
    clearButton.isHidden = !context.host.clear
    for button in [tidyButton, clearButton] { button.palette = context.palette }
    repaint()
  }

  override func repaint() {
    guard let context else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.backgroundColor = context.palette.divider.cgColor
    gap.backgroundColor = context.palette.divider.cgColor
    gap.isHidden = !(context.host.tidy && context.host.clear)
    CATransaction.commit()
    let target: CGFloat = hovered ? 1 : 0
    guard target != reveal else { return }
    reveal = target
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = hovered ? 0.12 : 0.16
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
      ctx.allowsImplicitAnimation = true
      for button in [tidyButton, clearButton] { button.animator().alphaValue = target }
      layoutLine(animated: true)
    }
  }

  private var buttonsWidth: CGFloat {
    var width: CGFloat = 0
    if !tidyButton.isHidden { width += tidyButton.fittingWidth }
    if !tidyButton.isHidden && !clearButton.isHidden { width += 9 }
    if !clearButton.isHidden { width += clearButton.fittingWidth }
    return width
  }

  private func layoutLine(animated: Bool) {
    let inset = reveal * buttonsWidth
    let frame = CGRect(x: 9, y: (bounds.height - 1) / 2, width: max(0, bounds.width - 18 - inset), height: 1)
    if animated {
      let resize = CABasicAnimation(keyPath: "bounds.size.width")
      resize.fromValue = line.presentation()?.bounds.width ?? line.bounds.width
      resize.toValue = frame.width
      resize.duration = reveal > 0 ? 0.12 : 0.16
      resize.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
      line.add(resize, forKey: "inset")
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.anchorPoint = CGPoint(x: 0, y: 0.5)
    line.bounds = CGRect(origin: .zero, size: frame.size)
    line.position = CGPoint(x: frame.minX, y: frame.midY)
    CATransaction.commit()
  }

  override func layoutBody() {
    var right = bounds.width - 9
    if !clearButton.isHidden {
      let w = clearButton.fittingWidth
      clearButton.frame = NSRect(x: right - w, y: 0, width: w, height: bounds.height)
      right -= w
    }
    if !tidyButton.isHidden && !clearButton.isHidden {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gap.frame = CGRect(x: right - 1, y: (bounds.height - 9) / 2, width: 1, height: 9)
      CATransaction.commit()
      right -= 9
    }
    if !tidyButton.isHidden {
      let w = tidyButton.fittingWidth
      tidyButton.frame = NSRect(x: right - w, y: 0, width: w, height: bounds.height)
    }
    gap.opacity = Float(reveal)
    for button in [tidyButton, clearButton] { button.alphaValue = reveal }
    layoutLine(animated: false)
  }
}

final class DividerButton: NSView {
  private let symbol = SymbolView()
  private let label = NSTextField(labelWithString: "")
  private let name: String
  private let iconWidth: CGFloat
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { paint() } }
  private var pressed = false { didSet { paint() } }
  var palette: SidebarPalette? { didSet { paint() } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  init(title: String, symbol name: String, iconWidth: CGFloat) {
    self.name = name
    self.iconWidth = iconWidth
    super.init(frame: .zero)
    label.stringValue = title
    label.font = .systemFont(ofSize: 10, weight: .medium)
    addSubview(symbol)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  var fittingWidth: CGFloat { 8 + iconWidth + 3 + label.fittingSize.width }

  func describe(_ text: String) {
    toolTip = text
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(text)
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return onPress != nil
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    symbol.frame = NSRect(x: 8, y: (h - 11) / 2, width: iconWidth, height: 11)
    let size = label.fittingSize
    label.frame = NSRect(x: 8 + iconWidth + 3, y: (h - size.height) / 2, width: size.width, height: size.height)
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
  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  private func paint() {
    guard let palette else { return }
    let color = pressed ? palette.textSecondary : hovered ? palette.textPrimary : palette.textTertiary
    symbol.set(name, size: 9, weight: .semibold, color: color)
    label.textColor = color
  }
}

final class TileView: SidebarRowView {
  private let glass = SidebarGlassTile()
  private let icon = TabIconView()
  private let badge = SymbolView()
  private let mosaic = FolderMosaicView()
  private var tabId: String?
  private var folderId: String?
  private var active = false
  private var selected = false
  private var showsBadge = false
  private var badges: TabMediaBadgesView?
  private var ring: IconRingView?
  private var ringRequest: SidebarFaviconRequest?

  override var accessibleTitle: String? {
    guard let context else { return nil }
    if let folderId {
      let name = context.query.folderMembers(windowId: context.windowId, folderId).lazy.compactMap { context.state.tabs[$0]?.tileFolder?.name }.first
      return name.map { $0.isEmpty ? "Folder" : $0 } ?? "Folder"
    }
    return tabId.flatMap { context.state.tabs[$0] }.map(context.title)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.addSubview(glass)
    body.addSubview(icon)
    body.addSubview(mosaic)
    addSubview(badge)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    guard let context, let item else { return }
    let palette = context.palette
    switch item.kind {
    case .tile(let id):
      tabId = id
      folderId = nil
    case .folder(let id):
      folderId = id
      let members = context.query.folderMembers(windowId: context.windowId, id)
      tabId = context.activeId.flatMap { members.contains($0) ? $0 : nil }
      mosaic.render(members: members, context: context)
    default:
      return
    }
    let tab = tabId.flatMap { context.state.tabs[$0] }
    active = tab != nil && context.activeId == tabId
    selected = folderId == nil ? context.flags.selection.contains(tabId ?? "") : false
    mosaic.isHidden = folderId == nil || tab != nil
    icon.isHidden = tab == nil
    if let tab {
      icon.favicons = context.favicons
      icon.set(context.iconSpec(tab), palette: palette)
    }
    if folderId != nil {
      showsBadge = tab != nil
      badge.set("folder.fill", size: 7, color: palette.textSecondary)
    } else if let tab {
      showsBadge = context.flags.playing.contains(tab.id) || tab.muted
      badge.set(tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 8, color: palette.textSecondary)
    } else {
      showsBadge = false
    }
    badge.isHidden = !showsBadge
    TabMediaBadgesView.attach(&badges, to: body, flags: context.flags, tabId: folderId == nil ? tab?.id : nil, host: context.host, palette: palette)
    badges?.frame = icon.frame
    glass.dark = palette.dark
    renderRing(folderId == nil ? tab : nil, context)
    repaint()
  }

  private func renderRing(_ tab: Tab?, _ context: SidebarContext) {
    let source = active && context.host.iconRing ? tab.flatMap { ringSource($0, context) } : nil
    guard let source, let theme = IconRingView.theme(of: source) else {
      ring?.isHidden = true
      glass.isHidden = false
      return
    }
    let view = ring ?? IconRingView()
    if ring == nil {
      ring = view
      body.addSubview(view, positioned: .above, relativeTo: glass)
      view.frame = bounds
    }
    view.cornerRadius = SidebarMetrics.tileRadius
    view.dark = context.palette.dark
    view.source = source
    view.theme = theme
    view.isHidden = false
    glass.isHidden = true
    if view.drawsTemplateIcon { icon.isHidden = true }
  }

  private func ringSource(_ tab: Tab, _ context: SidebarContext) -> IconRingSource? {
    if let custom = tab.customIcon, !custom.isEmpty {
      return custom.hasPrefix("symbol:") ? nil : IconRingSource(uri: nil, emoji: custom)
    }
    let request = SidebarFaviconRequest(url: tab.url, favicon: tab.favicon, profileId: tab.profileId, dark: context.palette.dark)
    if let known = context.favicons.cached(request) {
      guard let picture = known?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let source = IconRingSource(uri: "sidebar:\(request.profileId)|\(request.dark)|\(request.url)|\(request.favicon ?? "")", emoji: nil)
      else { return nil }
      IconRingView.remember(picture, for: source)
      return source
    }
    guard ringRequest != request else { return nil }
    ringRequest = request
    context.favicons.load(request) { [weak self] picture in
      guard let self, self.ringRequest == request else { return }
      self.ringRequest = nil
      if picture != nil { self.render() }
    }
    return nil
  }

  override func repaint() {
    guard let context else { return }
    let palette = context.palette
    let fill = active ? palette.pinnedSelectedFill : pressed ? palette.pressed : hovered || selected ? palette.hover : palette.pinnedResting
    glass.tint = palette.glassTint(fill, raised: active && !pressed)
    glass.raisedSelection = active
    glass.outlineColor = !active && selected ? palette.dragBorder : nil
  }

  override func layoutBody() {
    glass.frame = bounds
    ring?.frame = bounds
    icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    badges?.frame = icon.frame
    let size = FolderMosaicView.side
    mosaic.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    badge.frame = folderId != nil
      ? NSRect(x: bounds.width - 4 - 10, y: bounds.height - 3 - 9, width: 10, height: 9)
      : NSRect(x: bounds.width - 4 - 12, y: bounds.height - 3 - 10, width: 12, height: 10)
  }

  override func click(_ mods: SidebarClickMods, count: Int) {
    guard let context else { return }
    if let folderId { return context.send(.folder(folderId: folderId)) }
    guard let tabId else { return }
    context.send(.click(tabId: tabId, mods: mods))
    if count == 2 { context.send(.tileDoubleClick(tabId: tabId)) }
  }

  override func middleClick() {
    guard folderId == nil, let tabId else { return }
    context?.send(.middleClick(tabId: tabId))
  }

  override var hoverTarget: (kind: String, id: String)? {
    if let folderId { return ("folder", folderId) }
    return tabId.map { ("tab", $0) }
  }

  override func contextMenu() {
    if let folderId { return context?.send(.folderMenu(folderId: folderId)) ?? () }
    guard let tabId else { return }
    context?.send(.tabMenu(tabId: tabId))
  }
}

final class FolderMosaicView: NSView {
  static let cell: CGFloat = 9
  static let gap: CGFloat = 2
  static let pad: CGFloat = 3.5
  static let side = pad * 2 + cell * 2 + gap
  private var icons: [TabIconView] = []

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func render(members: [String], context: SidebarContext) {
    layer?.backgroundColor = (context.palette.dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)).cgColor
    let ids = Array(members.prefix(4))
    while icons.count < ids.count {
      let view = TabIconView()
      addSubview(view)
      icons.append(view)
    }
    while icons.count > ids.count { icons.removeLast().removeFromSuperview() }
    for (i, id) in ids.enumerated() {
      guard let tab = context.state.tabs[id] else { continue }
      icons[i].favicons = context.favicons
      icons[i].set(context.iconSpec(tab, size: Self.cell), palette: context.palette)
      icons[i].frame = NSRect(
        x: Self.pad + CGFloat(i % 2) * (Self.cell + Self.gap), y: Self.pad + CGFloat(i / 2) * (Self.cell + Self.gap), width: Self.cell, height: Self.cell)
    }
  }
}

final class IncognitoBadgeView: SidebarRowView {
  override var pressScales: Bool { false }
}

final class SidebarRenameField: NSTextField, NSTextFieldDelegate {
  private var finished = false
  var onDone: ((String?) -> Void)?

  init(initial: String, placeholder: String, font: NSFont, color: NSColor) {
    super.init(frame: .zero)
    stringValue = initial
    placeholderString = placeholder
    self.font = font
    textColor = color
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    isEditable = true
    isSelectable = true
    usesSingleLineMode = true
    lineBreakMode = .byClipping
    cell?.isScrollable = true
    delegate = self
  }

  required init?(coder: NSCoder) { fatalError() }

  func begin() {
    guard let window else { return }
    window.makeFirstResponder(self)
    currentEditor()?.selectAll(nil)
  }

  func finish(_ text: String?) {
    guard !finished else { return }
    finished = true
    onDone?(text)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) {
      finish(stringValue)
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      finish(nil)
      return true
    }
    return false
  }

  func controlTextDidEndEditing(_ obj: Notification) { finish(stringValue) }
}

extension SidebarRowView {
  func syncRename(_ editing: Bool, kind: String, id: String, frame: NSRect, initial: @autoclosure () -> String, placeholder: @autoclosure () -> String,
    font: NSFont, color: NSColor, field: inout SidebarRenameField?)
  {
    if !editing {
      field?.removeFromSuperview()
      field = nil
      return
    }
    if field == nil {
      let editor = SidebarRenameField(initial: initial(), placeholder: placeholder(), font: font, color: color)
      editor.onDone = { [weak self] text in self?.context?.send(.renamed(kind: kind, id: id, text: text)) }
      body.addSubview(editor)
      field = editor
      DispatchQueue.main.async { [weak editor] in editor?.begin() }
    }
    field?.frame = frame
  }
}
