import AppKit
import SolaraModel
import SolaraStore

@MainActor
public final class SplitChromeView: NSView {
  public let windowId: String
  public var onResize: ((_ splitId: String, _ sizes: [Double]?, _ stackSizes: [Double]?) -> Void)?
  public var onToastHidden: ((Int) -> Void)? {
    get { toast.onHidden }
    set { toast.onHidden = newValue }
  }
  public var onToastAction: ((Int) -> Void)? {
    get { toast.onAction }
    set { toast.onAction = newValue }
  }

  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
  private var covered = false
  private var theme = SplitChromeTheme.fallback
  private var dividers: [String: SplitDividerView] = [:]
  private let zones = SplitDropZonesView()
  private let toast = SplitToastView()
  private let notice = SplitToastView()
  private var drag: (splitId: String, kind: SplitDivider.Kind, sizes: [Double], stack: [Double]?, vertical: Bool)?
  private var pending: (splitId: String, sizes: [Double]?, stack: [Double]?)?
  private var link: CADisplayLink?
  private(set) public var dispatches = 0

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(zones)
    addSubview(notice)
    addSubview(toast)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    let local = convert(point, from: superview)
    if let hit = toast.hitTest(local) { return hit }
    return dividers.values.first { !$0.isHidden && $0.frame.contains(local) }
  }

  public func update(state: BrowserState) {
    guard let window = state.windows[windowId] else { return }
    let active = window.activeTabIds[window.profileId]
    let next = Splits.splitOf(state, active)
    guard next != split || active != activeId else { return }
    split = next
    activeId = active
    needsLayout = true
  }

  public func setChrome(theme next: SplitChromeTheme, fullscreenTab nextFullscreen: String?, covered nextCovered: Bool = false) {
    if next != theme {
      theme = next
      zones.theme = next
      toast.theme = next
      notice.theme = next
      for divider in dividers.values { divider.dark = next.dark }
    }
    if nextFullscreen != fullscreenTab || nextCovered != covered {
      fullscreenTab = nextFullscreen
      covered = nextCovered
      needsLayout = true
    }
  }

  public func setDrag(_ frame: SplitDragFrame?) { zones.apply(frame) }

  public func setToast(_ spec: SplitToastSpec?) { toast.show(spec) }

  public func setNotice(_ spec: SplitToastSpec?) { notice.show(spec.map { var sticky = $0; sticky.sticky = true; return sticky }) }

  public override func layout() {
    super.layout()
    zones.frame = bounds
    toast.frame = bounds
    notice.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - SplitToastView.noticeLift))
    relayout()
  }

  public var panes: [String: CGRect] { SplitSlots.shared.panes(windowId) }

  private func relayout() {
    let area = SplitLayout.bounds(in: self, fullscreenTab: fullscreenTab)
    let laid = SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: area)
    let panes = laid.panes
    let shown = covered ? [] : laid.dividers
    SplitSlots.shared.publish(windowId, panes)
    var seen = Set<String>()
    for divider in shown {
      let key = Self.key(divider.kind)
      seen.insert(key)
      let view = dividers[key] ?? makeDivider(key)
      view.divider = divider
      view.frame = SplitDividerView.frame(for: divider)
    }
    for (key, view) in dividers where !seen.contains(key) {
      if view.dragging { continue }
      view.removeFromSuperview()
      dividers[key] = nil
    }
  }

  static func key(_ kind: SplitDivider.Kind) -> String {
    switch kind {
    case .root(let index): "r\(index)"
    case .stack: "s"
    }
  }

  private func makeDivider(_ key: String) -> SplitDividerView {
    let view = SplitDividerView()
    view.dark = theme.dark
    view.onBegin = { [weak self, weak view] in
      guard let self, let split = self.split, let divider = view?.divider else { return }
      self.drag = (split.id, divider.kind, split.sizes, split.stack?.sizes, divider.vertical)
    }
    view.onMove = { [weak self] delta in self?.moved(delta) }
    view.onEnd = { [weak self] in self?.ended() }
    dividers[key] = view
    addSubview(view, positioned: .below, relativeTo: zones)
    return view
  }

  private func moved(_ delta: CGFloat) {
    guard let drag else { return }
    let area = SplitLayout.bounds(in: self, fullscreenTab: fullscreenTab)
    let total = Double(drag.vertical ? area.width : area.height)
    switch drag.kind {
    case .root(let index):
      pending = (drag.splitId, ShellGeometry.resize(drag.sizes, index, delta: Double(delta), total: total), nil)
    case .stack:
      guard let stack = drag.stack else { return }
      pending = (drag.splitId, nil, ShellGeometry.resize(stack, 0, delta: Double(delta), total: total))
    }
    guard link == nil else { return }
    let made = displayLink(target: self, selector: #selector(frameTick(_:)))
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func frameTick(_ link: CADisplayLink) {
    flush()
    if drag == nil { stopLink() }
  }

  private func ended() {
    flush()
    drag = nil
    stopLink()
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  private func flush() {
    guard let pending else { return }
    self.pending = nil
    dispatches += 1
    onResize?(pending.splitId, pending.sizes, pending.stack)
  }

  public func devDragBegin(_ key: String) -> Bool {
    guard let view = dividers[key] else { return false }
    view.onBegin?()
    return drag != nil
  }

  public func devDragMove(_ delta: CGFloat) { moved(delta) }

  public func devDragEnd() { ended() }

  public func sample() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
    return [
      "split": split?.id ?? NSNull(),
      "panes": panes.mapValues(rect),
      "dividers": dividers.map { ["key": $0.key, "frame": rect($0.value.frame), "hovered": $0.value.hovered, "dragging": $0.value.dragging] },
      "zones": zones.sample(),
      "toast": toast.spec.map { ["id": $0.id, "title": $0.title, "appear": toast.appearValue, "frame": rect(toast.cardFrame)] as [String: Any] } ?? NSNull(),
      "notice": notice.spec.map { ["id": $0.id, "title": $0.title, "frame": rect(notice.convert(notice.cardFrame, to: self))] as [String: Any] } ?? NSNull(),
      "dispatches": dispatches,
    ]
  }
}
