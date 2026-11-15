import AppKit

@MainActor
final class SidebarViewBinding {
  private weak var reference: NSView?
  let token: Int

  init(_ view: NSView) {
    reference = view
    token = Self.token(view)
  }

  var view: NSView? {
    guard let reference, Self.token(reference) == token else { return nil }
    return reference
  }

  static func token(_ view: NSView) -> Int {
    (view as? SidebarRowView)?.bindingToken ?? (view as? GroupBoxView)?.bindingToken ?? 0
  }
}

@MainActor
final class SidebarRowReuse {
  private(set) var bins: [String: [NSView]] = [:]
  private(set) var highWater: [String: Int] = [:]

  func demand(_ counts: [String: Int], shrinking: Bool) {
    if shrinking { highWater = counts }
    else { for (kind, count) in counts { highWater[kind] = max(highWater[kind] ?? 0, count) } }
    for kind in bins.keys { bins[kind] = Array((bins[kind] ?? []).prefix(highWater[kind] ?? 0)) }
  }

  func take(_ kind: String, make: () -> NSView) -> NSView {
    bins[kind]?.popLast() ?? make()
  }

  func put(_ view: NSView, kind: String) {
    guard (bins[kind]?.count ?? 0) < (highWater[kind] ?? 0) else { return }
    bins[kind, default: []].append(view)
  }

  func clear() {
    bins.removeAll()
    highWater.removeAll()
  }

  static func kind(_ kind: SidebarItemKind, rail: Bool) -> String {
    let name: String
    if rail {
      switch kind {
      case .tab, .tile: return "rail.tab"
      case .folder: return "rail.folder"
      case .split: return "rail.split"
      case .groupHeader: return "rail.group"
      case .newTab: return "rail.newTab"
      case .divider: return "rail.divider"
      case .live(let key) where key.hasPrefix("livefolder|"): return "rail.liveFolder"
      default: break
      }
    }
    switch kind {
    case .tab: name = "tab"
    case .tile, .folder: name = "tile"
    case .split: name = "split"
    case .groupHeader: name = "groupHeader"
    case .groupBox: name = "groupBox"
    case .newTab: name = "newTab"
    case .divider: name = "divider"
    case .incognito: name = "incognito"
    case .upsell: name = "upsell"
    case .live(let key):
      if key.hasPrefix("lf:") { name = "liveBox" }
      else if key.hasPrefix("livefolder|") { name = "liveHeader" }
      else if key.hasPrefix("live|") { name = "liveItem" }
      else {
        let tail = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
        if tail.hasPrefix("k:") { name = "liveStack" }
        else if tail.hasPrefix("h:") { name = "liveSection" }
        else if tail.hasPrefix("m:") { name = "liveMore" }
        else if tail.hasPrefix("c:") { name = "liveCompleted" }
        else if tail == "done" { name = "liveFooter" }
        else { name = "liveNote" }
      }
    }
    return "\(rail ? "rail" : "full").\(name)"
  }

  static func reset(_ view: NSView) {
    func resetLayer(_ layer: CALayer) {
      layer.removeAllAnimations()
      layer.transform = CATransform3DIdentity
      layer.sublayerTransform = CATransform3DIdentity
      layer.sublayers?.forEach(resetLayer)
    }
    if let icon = view as? TabIconView { icon.clearBinding() }
    if let button = view as? SidebarIconButton { button.clearBinding() }
    if let button = view as? DividerButton { button.clearBinding() }
    if let button = view as? UpsellButton { button.clearBinding() }
    view.toolTip = nil
    view.alphaValue = 1
    if let layer = view.layer { resetLayer(layer) }
    view.subviews.forEach(reset)
  }
}
