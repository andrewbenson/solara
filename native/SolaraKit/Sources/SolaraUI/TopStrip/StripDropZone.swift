import AppKit

@MainActor
final class StripDropZone: TabDropZone {
  private weak var strip: TopStripView?

  init(strip: TopStripView) { self.strip = strip }

  private var target: (TopStripView, StripPageView)? {
    guard let strip, strip.takesDrops, strip.window != nil, !strip.isHiddenOrHasHiddenAncestor,
      !strip.bounds.isEmpty, let page = strip.current else { return nil }
    return (strip, page)
  }

  func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim? {
    guard let (strip, page) = target, session.sourceWindow != strip.windowId,
      let content = strip.window?.contentView else { return nil }
    let local = strip.fullScreenPoint(CGPoint(x: windowPoint.x, y: content.bounds.height - windowPoint.y))
    guard strip.bounds.contains(local), case .some(let beforeId) = page.incoming(at: windowPoint) else { return nil }
    return .insert(beforeId: beforeId)
  }

  func clear() { _ = strip?.current?.incoming(at: nil) }

  func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool {
    guard let (strip, page) = target, session.sourceWindow != strip.windowId,
      case .insert(let beforeId) = aim, let bridge = strip.dragBridge else { return false }
    let landed = bridge.land(ids: session.tabIds, from: session.sourceWindow, in: strip.windowId, beforeId: beforeId)
    page.endIncoming()
    return landed
  }
}
