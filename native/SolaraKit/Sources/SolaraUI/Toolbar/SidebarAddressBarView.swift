import AppKit
import QuartzCore

public struct SidebarFieldLook: Decodable, Equatable, Sendable {
  public var resting: String
  public var stroke: String
  public var hover: String
  public var placeholder: String
  public var prompt: String
}

public struct SidebarAddressBarState: Decodable, Equatable, Sendable {
  public var palette: ToolbarPaletteState
  public var accent: String
  public var look: SidebarFieldLook
  public var buttons: [ToolbarButtonState]
  public var url: ToolbarUrlState?
  public var extensions: [ToolbarButtonState]
  public var progress: Double?

  public static func decode(_ json: String) -> SidebarAddressBarState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SidebarAddressBarState.self, from: data)
  }
}

public enum SidebarHeaderMetrics {
  public static let toggleX: CGFloat = ShellMetrics.railLightsTrailing + 8 + SidebarHeaderMetrics.plate / 2
  public static let pitch: CGFloat = 35
  public static let edge: CGFloat = 7
  public static let minGap: CGFloat = 2
  public static let button: CGFloat = 30
  public static let buttonsY: CGFloat = ShellMetrics.lightsCenter.y
  public static let plate: CGFloat = 32
  public static let plateRadius: CGFloat = 6
  public static let fieldTop: CGFloat = 46
  public static let fieldHeight: CGFloat = SidebarMetrics.rowHeight
  public static let fieldRadius: CGFloat = 10
  public static let height: CGFloat = fieldTop + fieldHeight
  public static let navigation = ["back", "forward", "reload"]

  public static func navigationFitting(width: CGFloat, toggle: Bool) -> (count: Int, step: CGFloat) {
    let span = width - edge - button / 2 - (toggle ? toggleX : toggleX - pitch)
    let count = max(0, min(3, Int((span / (button + minGap)).rounded(.down))))
    return (count, count > 0 ? min(pitch, span / CGFloat(count)) : pitch)
  }
}

@MainActor
public final class SidebarAddressBarView: NSView {
  public var onClick: (ToolbarClick) -> Void = { _ in }
  public var onAnchors: ([String: CGRect]) -> Void = { _ in }
  public private(set) var state: SidebarAddressBarState?
  public var navigationOnly = false { didSet { needsLayout = true } }
  public var navigationLeadingInset = ShellMetrics.railToolbarLeadingInset { didSet { needsLayout = true } }

  private var buttons: [ToolbarButtonView] = []
  private let field = ToolbarUrlFieldView()
  private var reportedAnchors: [String: CGRect]?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    field.onClick = { [weak self] click in self?.onClick(click) }
    addSubview(field)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(_ next: SidebarAddressBarState) {
    guard next != state else { return }
    state = next
    buttons = sync(buttons, next.buttons, next.palette)
    field.update(next.url ?? SidebarAddressBarView.empty, palette: next.palette, look: next.look, accessory: next.extensions, progress: next.progress, accent: next.accent)
    needsLayout = true
  }

  public func clear() {
    state = nil
    for button in buttons { button.removeFromSuperview() }
    buttons = []
    field.isHidden = true
  }

  static let empty = ToolbarUrlState(host: "", restTrail: "", hoverTrail: "", hoverButtons: [], trailing: [], pinned: false)

  public var fieldFrame: CGRect { field.frame }
  public var navigationFrames: [String: CGRect] {
    Dictionary(uniqueKeysWithValues: buttons.filter { !$0.isHidden }.map { ("button:" + $0.state.id, $0.frame) })
  }

  private func sync(_ views: [ToolbarButtonView], _ specs: [ToolbarButtonState], _ palette: ToolbarPaletteState) -> [ToolbarButtonView] {
    var out: [ToolbarButtonView] = []
    for (i, spec) in specs.enumerated() {
      if i < views.count, views[i].state.id == spec.id {
        views[i].state = spec
        views[i].palette = palette
        out.append(views[i])
      } else {
        let made = ToolbarButtonView(state: spec, palette: palette)
        made.onClick = { [weak self] click in self?.onClick(click) }
        addSubview(made)
        out.append(made)
      }
    }
    for v in views where !out.contains(where: { $0 === v }) { v.removeFromSuperview() }
    return out
  }

  public override func layout() {
    super.layout()
    let M = SidebarHeaderMetrics.self
    let scale = window?.backingScaleFactor ?? 2
    let px = { (v: CGFloat) in (v * scale).rounded() / scale }
    if navigationOnly {
      field.isHidden = true
      var x = navigationLeadingInset + ShellMetrics.toolbarIconCenters[0] - M.plate / 2
      for button in buttons {
        button.isHidden = false
        button.frame = CGRect(x: px(x), y: px((bounds.height - M.plate) / 2), width: M.plate, height: M.plate)
        x += M.pitch
        button.recheckHover()
      }
      return
    }
    field.isHidden = false
    let toggle = buttons.first { $0.state.id == "sidebar" }
    let navigation = buttons.filter { M.navigation.contains($0.state.id) }
    let fitting = M.navigationFitting(width: bounds.width, toggle: toggle != nil)
    let shown = Array(navigation.prefix(fitting.count))
    let last = bounds.width - M.edge - M.button / 2
    let place = { (b: ToolbarButtonView, center: CGFloat) in
      b.isHidden = false
      b.frame = CGRect(x: px(center - M.plate / 2), y: px(M.buttonsY - M.plate / 2), width: M.plate, height: M.plate)
    }
    if let toggle { place(toggle, M.toggleX) }
    for (i, b) in shown.enumerated() { place(b, last - CGFloat(shown.count - 1 - i) * fitting.step) }
    for b in navigation where !shown.contains(where: { $0 === b }) { b.isHidden = true }
    field.frame = CGRect(x: SidebarMetrics.inset, y: M.fieldTop, width: max(0, bounds.width - 2 * SidebarMetrics.inset), height: M.fieldHeight)
    field.layoutSubtreeIfNeeded()
    for b in buttons { b.recheckHover() }
    refreshFullScreenAnchors()
  }

  func refreshFullScreenAnchors() {
    guard window != nil else { return }
    var anchors: [String: CGRect] = ["field": windowRect(field.frame)]
    for (slot, rect) in field.accessoryAnchors { anchors[slot] = windowRect(field.convert(rect, to: self)) }
    guard anchors != reportedAnchors else { return }
    reportedAnchors = anchors
    onAnchors(anchors)
  }

  public func reannounceAnchors() {
    reportedAnchors = nil
    layoutSubtreeIfNeeded()
    refreshFullScreenAnchors()
  }

  private func windowRect(_ local: CGRect) -> CGRect {
    guard let root = window?.contentView else { return local }
    let r = fullScreenRect(local, to: root)
    return root.isFlipped ? r : CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
  }

  public override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    needsLayout = true
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reportedAnchors = nil
    needsLayout = true
  }

  public func sample() -> [String: Any] {
    let rect = { (r: CGRect) in [r.minX, r.minY, r.width, r.height].map { Double($0) } }
    var out: [String: Any] = ["frame": rect(frame), "field": rect(field.frame)]
    out["buttons"] = buttons.filter { !$0.isHidden }.map { ["id": $0.state.id, "frame": rect($0.frame)] as [String: Any] }
    out["field.sample"] = field.sample()
    return out
  }
}

@MainActor
public final class SidebarAddressBars {
  public static let shared = SidebarAddressBars()

  public var onClick: (String, SidebarAddressBarView, ToolbarClick) -> Void = { _, _, _ in }
  public var onAnchors: (String, [String: CGRect]) -> Void = { _, _ in }

  public private(set) var anchors: [String: [String: CGRect]] = [:]
  private var views: [String: SidebarAddressBarView] = [:]
  private var states: [String: SidebarAddressBarState] = [:]
  private var navigationViews: [String: SidebarAddressBarView] = [:]
  private var claims: Set<String> = []
  private var remounts: Set<String> = []

  public static let claimsChanged = Notification.Name("SidebarAddressBars.claimsChanged")

  public func view(_ windowId: String) -> SidebarAddressBarView {
    if let view = views[windowId] { return view }
    let view = SidebarAddressBarView(frame: CGRect(x: 0, y: 0, width: 0, height: SidebarHeaderMetrics.height))
    view.onClick = { [weak self, weak view] click in
      guard let self, let view, self.views[windowId] === view else { return }
      self.onClick(windowId, view, click)
    }
    view.onAnchors = { [weak self] anchors in
      guard let self else { return }
      self.anchors[windowId] = anchors
      self.onAnchors(windowId, anchors)
    }
    if let state = states[windowId] { view.update(state) }
    views[windowId] = view
    return view
  }

  public func existing(_ windowId: String) -> SidebarAddressBarView? { views[windowId] }

  public func navigationView(_ windowId: String) -> SidebarAddressBarView {
    if let view = navigationViews[windowId] { return view }
    let view = SidebarAddressBarView(frame: .zero)
    view.navigationOnly = true
    view.onClick = { [weak self, weak view] click in
      guard let self, let view, self.navigationViews[windowId] === view else { return }
      self.onClick(windowId, view, click)
    }
    if let state = states[windowId] { view.update(state) }
    navigationViews[windowId] = view
    return view
  }

  public func removeNavigationView(_ windowId: String) {
    navigationViews.removeValue(forKey: windowId)?.removeFromSuperview()
  }

  public func reannounceOnNextSet() {
    remounts.formUnion(views.keys)
  }

  public func set(_ windowId: String, json: String?) {
    guard let json, let state = SidebarAddressBarState.decode(json) else {
      states[windowId] = nil
      remounts.remove(windowId)
      navigationViews[windowId]?.clear()
      if claims.contains(windowId) { return }
      views[windowId]?.removeFromSuperview()
      views[windowId] = nil
      anchors[windowId] = nil
      return
    }
    let remounted = remounts.remove(windowId) != nil
    let mounting = states[windowId] == nil || remounted
    states[windowId] = state
    views[windowId]?.update(state)
    navigationViews[windowId]?.update(state)
    if mounting { views[windowId]?.reannounceAnchors() }
  }

  public func claim(_ windowId: String) {
    guard claims.insert(windowId).inserted else { return }
    NotificationCenter.default.post(name: SidebarAddressBars.claimsChanged, object: self, userInfo: ["windowId": windowId])
  }

  public func release(_ windowId: String) {
    guard claims.remove(windowId) != nil else { return }
    if states[windowId] == nil {
      views[windowId]?.removeFromSuperview()
      views[windowId] = nil
      anchors[windowId] = nil
    }
    NotificationCenter.default.post(name: SidebarAddressBars.claimsChanged, object: self, userInfo: ["windowId": windowId])
  }

  public func claimed(_ windowId: String) -> Bool { claims.contains(windowId) }
}
