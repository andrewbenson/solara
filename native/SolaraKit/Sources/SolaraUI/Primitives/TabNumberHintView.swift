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
    #if DEBUG
    debugInput = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" && notification.userInfo?["debugInput"] as? Bool == true
    #endif
    bindings = notification.userInfo?["bindings"] as? [String: String] ?? [:]
    publish()
  }

  func cancel(in target: NSWindow? = nil) {
    if let target {
      NotificationCenter.default.post(name: Notification.Name("SolaraTabNumberHintsCancelled"), object: target)
      if target !== window { return }
    }
    guard window != nil || !bindings.isEmpty else { return }
    window = nil
    bindings = [:]
    #if DEBUG
    debugInput = false
    #endif
    publish()
  }

  private func publish() {
    NotificationCenter.default.post(name: Self.changed, object: self)
  }
}

@MainActor
final class TabNumberHintView: NSView {
  private let label = NSTextField(labelWithString: "")
  private let plate = CALayer()
  private var actions: [String] = []
  private var enabled = true
  private var compact = false
  private var shown = false
  private var inset: CGFloat = 8
  private var measured: (text: String, width: CGFloat)?
  private var laidOut: (size: CGSize, compact: Bool)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.zPosition = 100
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = 5
    layer?.addSublayer(plate)
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byClipping
    label.maximumNumberOfLines = 1
    label.setAccessibilityElement(false)
    layer?.opacity = 0
    isHidden = true
    setAccessibilityElement(false)
    _ = TabNumberHintFeed.shared
    NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TabNumberHintFeed.changed, object: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func isAccessibilityElement() -> Bool { false }

  func configure(actions: [String], enabled: Bool, compact: Bool = false, inset: CGFloat = 8) {
    guard actions != self.actions || enabled != self.enabled || compact != self.compact || inset != self.inset || measured == nil else { return }
    self.actions = actions
    self.enabled = enabled
    self.compact = compact
    self.inset = inset
    refresh()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refresh()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    laidOut = nil
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
      if text != label.stringValue { label.stringValue = text }
      if label.superview == nil { addSubview(label) }
    }
    place()
    if shown != next { fade(to: next) }
    if !shown, layer?.animation(forKey: "tabNumberHintOpacity") == nil { settleHidden() }
  }

  private func fade(to next: Bool) {
    shown = next
    let opacity: Float = next ? 1 : 0
    let previous = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
    if next { isHidden = false }
    layer?.removeAnimation(forKey: "tabNumberHintOpacity")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.opacity = opacity
    CATransaction.commit()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = previous
    fade.toValue = opacity
    fade.duration = 0.12
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.shown else { return }
        self.settleHidden()
      }
    }
    layer?.add(fade, forKey: "tabNumberHintOpacity")
    CATransaction.commit()
  }

  private func settleHidden() {
    isHidden = true
    if TabNumberHintActions.label(actions, bindings: TabNumberHintFeed.shared.bindings) == nil { label.removeFromSuperview() }
  }

  func place() {
    guard let parent = superview else { return }
    let text = label.stringValue
    let textWidth: CGFloat
    if let measured, measured.text == text {
      textWidth = measured.width
    } else {
      textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width
      measured = (text, textWidth)
    }
    let padding: CGFloat = compact ? 1 : 4
    let width = min(max(0, parent.bounds.width - 2 * (compact ? 1 : inset)), max(25, ceil(textWidth) + 2 * padding + 2))
    let available = max(0, width - 2 * padding - 2)
    let size = max(1, min(10, 10 * available / max(1, textWidth)))
    if label.font?.pointSize != size { label.font = .systemFont(ofSize: size, weight: .medium) }
    let target = CGRect(x: parent.bounds.maxX - (compact ? 1 : inset) - width, y: parent.bounds.midY - 9, width: width, height: 18)
    if frame != target { frame = target }
    if laidOut?.size != target.size || laidOut?.compact != compact { needsLayout = true }
  }

  override func layout() {
    super.layout()
    laidOut = (bounds.size, compact)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plate.frame = bounds
    plate.borderWidth = 1
    plate.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.125).cgColor
    plate.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
    CATransaction.commit()
    let padding: CGFloat = compact ? 1 : 4
    label.frame = CGRect(x: padding, y: (bounds.height - 13) / 2, width: max(0, bounds.width - 2 * padding), height: 13)
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
    ]
  }
}
#endif
