import AppKit
import SolaraCore

final class NativeSwipeTarget: NSView, @preconcurrency ACSwipeTarget, @preconcurrency ACPagerSurface {
  var canSwipeBack = false
  var canSwipeForward = false
  var tracksUnavailableDirections = false
  var allowsVerticalMotion = false
  @objc var isPager = false
  @objc var coversPage = false
  var measuredWidth: (() -> CGFloat)?
  var onSwipe: (([String: Any]) -> Void)?
  var onPagerState: (([String: Any]) -> Void)?
  private(set) var pager: ACPager?

  @objc var hasNativePager: Bool { pager != nil }
  var pageWidth: Double {
    let width = measuredWidth?() ?? 0
    return Double(width > 0 ? width : bounds.width)
  }
  var surfaceWindow: NSWindow? { window }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { ACSwipe.addTarget(self) } else { ACSwipe.removeTarget(self) }
  }

  func swipeEvent(_ event: [String: Any]) {
    onSwipe?(event)
  }

  @objc(pagerInput:distance:direction:timestamp:)
  func pagerInput(_ phase: String, distance: CGFloat, direction: Int32, timestamp: TimeInterval) {
    pager?.input(from: self, phase: phase, distance: Double(distance), direction: Int(direction), timestamp: timestamp)
  }

  func use(_ next: ACPager?) {
    guard next !== pager else { return }
    let old = pager
    pager = next
    old?.detach(self)
    next?.attach(self)
  }

  func pagerMoved(_ position: Double) {}

  func pagerChanged(_ event: [String: Any]) {
    onPagerState?(event)
  }
}
