import AppKit
import QuartzCore

public enum TabNumberHintActions {
  public static func mapping(rowKeys: [String]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (index, key) in rowKeys.prefix(8).enumerated() { result[key] = ["selectTab:\(index + 1)"] }
    if let last = rowKeys.last { result[last, default: []].insert("selectLastTab", at: 0) }
    return result
  }

  public static func label(_ actions: [String], bindings: [String: String]) -> String? {
    actions.lazy.compactMap { bindings[$0] }.first { !$0.isEmpty }
  }
}

@MainActor
final class TabNumberHintFeed: NSObject {
  static let shared = TabNumberHintFeed()
  static let changed = Notification.Name("SolaraTabNumberHintFeedChanged")
  private(set) weak var window: NSWindow?
  private(set) var bindings: [String: String] = [:]
  private(set) var holdsThroughSelection = false
  #if DEBUG
  private(set) var debugInput = false
  #endif

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name("SolaraTabNumberHintsChanged"), object: nil)
  }

  @objc private func receive(_ notification: Notification) {
    guard notification.userInfo?["visible"] as? Bool == true, let target = notification.object as? NSWindow else {
      cancel()
      return
    }
    window = target
    holdsThroughSelection = notification.userInfo?["holdsThroughSelection"] as? Bool == true
    #if DEBUG
    debugInput = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" && notification.userInfo?["debugInput"] as? Bool == true
    #endif
    bindings = notification.userInfo?["bindings"] as? [String: String] ?? [:]
    publish()
  }

  func cancelOnSelection(in target: NSWindow) {
    if holdsThroughSelection, target === window { return }
    cancel(in: target)
  }

  func cancel(in target: NSWindow? = nil) {
    if let target {
      NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsCancelled"), object: target)
      if target !== window { return }
    }
    guard window != nil || !bindings.isEmpty else { return }
    window = nil
    bindings = [:]
    holdsThroughSelection = false
    #if DEBUG
    debugInput = false
    #endif
    publish()
  }

  private func publish() {
    NotificationCenter.default.post(name: Self.changed, object: self)
  }
}

enum TabNumberHintStyle {
  case row, tile, rail, corner
}

@MainActor
struct TabNumberHintTransition {
  let start: CFTimeInterval
  let duration: CFTimeInterval
  let animated: Bool
  let curve = CAMediaTimingFunction(name: .easeOut)

  func apply(_ layer: CALayer, keyPath: String, to value: Any, key: String) {
    let previous = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
    layer.removeAnimation(forKey: key)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.setValue(value, forKeyPath: keyPath)
    CATransaction.commit()
    guard animated, (previous as? NSObject)?.isEqual(value) != true else { return }
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = previous
    animation.toValue = value
    animation.beginTime = layer.convertTime(start, from: nil)
    animation.duration = duration
    animation.timingFunction = curve
    layer.add(animation, forKey: key)
  }
}

@MainActor
final class TabNumberHintView: NSView {
  private let label = NSTextField(labelWithString: "")
  private let plate = CALayer()
  private var actions: [String] = []
  private var enabled = true
  private var style: TabNumberHintStyle = .row
  private var compact: Bool { style == .rail || style == .corner }
  private var shown = false
  private var inset: CGFloat = 8
  private var generation = 0
  private weak var title: FadeLabel?
  private weak var icon: NSView?
  private var color: NSColor = .labelColor
  private(set) var blocksClose = false
  var visibilityChanged: (() -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.zPosition = 100
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = 5
    layer?.addSublayer(plate)
    label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    label.textColor = color
    label.alignment = .center
    label.lineBreakMode = .byClipping
    label.maximumNumberOfLines = 1
    label.setAccessibilityElement(false)
    addSubview(label)
    layer?.opacity = 0
    isHidden = true
    setAccessibilityElement(false)
    _ = TabNumberHintFeed.shared
    NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TabNumberHintFeed.changed, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard blocksClose, !isHidden, frame.contains(point) else { return nil }
    return superview
  }

  override func isAccessibilityElement() -> Bool { false }

  func configure(actions: [String], enabled: Bool, compact: Bool = false, inset: CGFloat = 8, style: TabNumberHintStyle? = nil) {
    let nextStyle = style ?? (compact ? .corner : .row)
    guard actions != self.actions || enabled != self.enabled || nextStyle != self.style || inset != self.inset else { return }
    let rebound = actions != self.actions || nextStyle != self.style || !enabled
    if rebound { reset() }
    self.actions = actions
    self.enabled = enabled
    self.style = nextStyle
    self.inset = inset
    refresh()
  }

  func present(title: FadeLabel? = nil, icon: NSView? = nil, color: NSColor? = nil) {
    let changed = self.title !== title || self.icon !== icon
    self.title = title
    self.icon = icon
    if let color { self.color = color }
    place()
    if changed { updatePresentation(transition: transition(animated: false)) }
    label.textColor = self.color
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { reset() } else { refresh() }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsLayout = true
  }

  @objc private func refresh() {
    let feed = TabNumberHintFeed.shared
    let text = TabNumberHintActions.label(actions, bindings: feed.bindings)
    var keyWindow = window?.isKeyWindow == true
    #if DEBUG
    keyWindow = keyWindow || feed.debugInput
    #endif
    let next = enabled && window != nil && window === feed.window && keyWindow && text != nil
    if let text {
      label.stringValue = compact && text.count == 2 && text.first == "⌘" ? String(text.suffix(1)) : text
    }
    place()
    if shown != next { fade(to: next) }
  }

  private func transition(animated: Bool = true) -> TabNumberHintTransition {
    TabNumberHintTransition(start: CACurrentMediaTime(), duration: shown ? 0.12 : 0.08, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }

  private func fade(to next: Bool) {
    generation += 1
    let token = generation
    shown = next
    let motion = transition()
    if next {
      isHidden = false
      blocksClose = true
      visibilityChanged?()
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == token, !self.shown else { return }
        self.settleHidden()
      }
    }
    if let layer { motion.apply(layer, keyPath: "opacity", to: next ? Float(1) : Float(0), key: "tabNumberHintOpacity") }
    updatePresentation(transition: motion)
    CATransaction.commit()
    if !motion.animated && !next { settleHidden() }
  }

  private func settleHidden() {
    isHidden = true
    blocksClose = false
    visibilityChanged?()
  }

  private func reset() {
    generation += 1
    shown = false
    layer?.removeAnimation(forKey: "tabNumberHintOpacity")
    if let layer { transition(animated: false).apply(layer, keyPath: "opacity", to: Float(0), key: "tabNumberHintOpacity") }
    updatePresentation(transition: transition(animated: false))
    settleHidden()
  }

  private func updatePresentation(transition: TabNumberHintTransition) {
    if let title {
      let end = shown ? title.convert(CGPoint(x: frame.minX - 6, y: 0), from: superview).x : nil
      title.keycapFade(end: end, transition: transition)
    }
    if let icon {
      icon.wantsLayer = true
      if let layer = icon.layer {
        transition.apply(layer, keyPath: "transform.translation.x", to: shown && style == .rail ? CGFloat(-5) : CGFloat(0), key: "tabNumberHintNudge")
        transition.apply(layer, keyPath: "opacity", to: shown && style == .corner ? Float(0.35) : Float(1), key: "tabNumberHintIconOpacity")
      }
    }
    label.textColor = color
    needsLayout = true
  }

  func place() {
    guard let parent = superview else { return }
    let measured = label.cell?.cellSize ?? .zero
    let width = ceil(measured.width) + 6
    let edge = compact ? CGFloat(1) : inset
    let y = style == .tile || style == .corner ? parent.bounds.maxY - 18 - 4 : parent.bounds.midY - 9
    let target = CGRect(x: parent.bounds.maxX - edge - width, y: y, width: width, height: 18)
    if frame != target { frame = target }
    if let title {
      let end = shown ? title.convert(CGPoint(x: frame.minX - 6, y: 0), from: parent).x : nil
      title.keycapFade(end: end)
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    plate.isHidden = compact
    plate.borderWidth = 0.5
    plate.borderColor = color.withAlphaComponent(color.alphaComponent * 0.22).cgColor
    plate.backgroundColor = color.withAlphaComponent(color.alphaComponent * 0.06).cgColor
    CATransaction.commit()
    let height = label.cell?.cellSize.height ?? 13
    label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
  }
}

#if DEBUG
@MainActor
public enum TabNumberHintInspection {
  public static func views(in root: NSView) -> [[String: Any]] {
    guard ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" else { return [] }
    var rows: [[String: Any]] = []
    func visit(_ view: NSView) {
      if let hint = view as? TabNumberHintView { rows.append(hint.debugState) }
      for child in view.subviews { visit(child) }
    }
    visit(root)
    return rows
  }
}

extension TabNumberHintView {
  fileprivate var debugState: [String: Any] {
    let rect = convert(bounds, to: nil)
    var ancestors: [String] = []
    var rowKey = ""
    var next = superview
    while let view = next {
      ancestors.append(String(describing: type(of: view)))
      if let row = view as? SidebarRowView { rowKey = row.item?.key ?? "" }
      next = view.superview
    }
    return [
      "actions": actions, "label": label.stringValue, "shown": shown,
      "visible": shown && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty,
      "opacity": layer?.opacity ?? 0, "presentationOpacity": layer?.presentation()?.opacity ?? layer?.opacity ?? 0,
      "frame": [rect.minX, rect.minY, rect.width, rect.height],
      "fontSize": label.font?.pointSize ?? 0, "compact": compact, "ancestors": ancestors, "rowKey": rowKey,
      "style": String(describing: style), "blocksClose": blocksClose,
      "cellWidth": label.cell?.cellSize.width ?? 0,
      "labelFrame": [label.frame.minX, label.frame.minY, label.frame.width, label.frame.height],
      "iconTranslationX": icon?.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0,
      "presentationIconTranslationX": (icon?.layer?.presentation() ?? icon?.layer)?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0,
      "titleMaskWidth": title?.layer?.mask?.bounds.width ?? title?.bounds.width ?? 0,
      "presentationTitleMaskWidth": title?.layer?.mask?.presentation()?.bounds.width ?? title?.layer?.mask?.bounds.width ?? title?.bounds.width ?? 0,
      "transitionStart": layer?.animation(forKey: "tabNumberHintOpacity")?.beginTime ?? 0,
      "transitionDuration": layer?.animation(forKey: "tabNumberHintOpacity")?.duration ?? 0,
    ]
  }
}
#endif
