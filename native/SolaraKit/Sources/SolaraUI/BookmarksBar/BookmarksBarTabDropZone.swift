import AppKit

@MainActor
final class BookmarksBarTabDropZone: TabDropZone {
  private weak var view: BookmarksBarView?
  private var copying = false

  init(view: BookmarksBarView) { self.view = view }

  func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim? {
    guard let view, let window = view.window, let content = window.contentView, !view.isHiddenOrHasHiddenAncestor else { clear(); return nil }
    let point = view.convert(CGPoint(x: windowPoint.x, y: content.bounds.height - windowPoint.y), from: nil)
    guard view.visibleRect.contains(point),
      let hit = content.hitTest(view.convert(point, to: content.superview)),
      hit === view || hit.isDescendant(of: view) else { clear(); return nil }
    let links = BookmarksBarLinkDrop.tabs(session.tabIds, resolve: view.resolveTab)
    let accepted = view.showLinkDrop(at: point, links: links)
    if accepted && !copying { NSCursor.dragCopy.push(); copying = true }
    if !accepted && copying { NSCursor.pop(); copying = false }
    return .bookmarks
  }

  func clear() {
    view?.clearLinkDrop()
    if copying { NSCursor.pop(); copying = false }
  }

  isolated deinit { if copying { NSCursor.pop() } }

  func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool {
    guard aim == .bookmarks, let view else { return false }
    return view.performLinkDrop(BookmarksBarLinkDrop.tabs(session.tabIds, resolve: view.resolveTab))
  }
}
