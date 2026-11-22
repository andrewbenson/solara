import AppKit
import QuartzCore
import SolaraModel

@MainActor
enum NewTabOpening {
  static let scaleKey = "newTabOpenScale"
  static let fadeKey = "newTabOpenFade"

  static func settled(_ before: BrowserState?, _ after: BrowserState) -> Set<String> {
    guard let before else { return [] }
    let candidates = Set(before.windows.values.flatMap { $0.activeTabIds.values })
    return Set(candidates.filter { id in
      before.tabs[id]?.newTabPlaceholder == true && after.tabs[id] != nil && after.tabs[id]?.newTabPlaceholder != true
    })
  }

  static func apply(_ view: NSView, horizontal: Bool) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer else { return }
    let open = SidebarSpring.make(horizontal ? "transform.scale.x" : "transform.scale.y", from: 0.01, to: 1)
    layer.add(open, forKey: scaleKey)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = SidebarView.fadeDuration
    fade.timingFunction = SidebarView.fadeCurve
    layer.add(fade, forKey: fadeKey)
  }
}
