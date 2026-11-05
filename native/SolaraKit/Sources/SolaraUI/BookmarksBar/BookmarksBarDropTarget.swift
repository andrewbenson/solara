import Foundation

public enum BookmarksBarDropTarget: Equatable, Sendable {
  case reorder(index: Int, insertionX: CGFloat)
  case folder(String)
  case sidebar

  public static func resolve(id: String, items: [BookmarksBarItem], visible: [BookmarksBarLayout.Placement], deltaX: CGFloat, pointerX: CGFloat, sidebarEdge: CGFloat?) -> BookmarksBarDropTarget? {
    guard deltaX.isFinite, pointerX.isFinite,
      let source = items.firstIndex(where: { $0.id == id }),
      let placement = visible.first(where: { $0.index == source }) else { return nil }
    if items[source].kind == .folder, let sidebarEdge, sidebarEdge.isFinite, pointerX < sidebarEdge { return .sidebar }
    let x = placement.frame.midX + deltaX
    for placement in visible {
      guard items.indices.contains(placement.index) else { continue }
      let item = items[placement.index]
      let frame = placement.frame
      if item.id != id, item.kind == .folder, x > frame.minX + frame.width * 0.25, x < frame.minX + frame.width * 0.75 {
        return .folder(item.id)
      }
      if x < frame.midX {
        let index = placement.index > source ? placement.index - 1 : placement.index
        return .reorder(index: index, insertionX: frame.minX - 2)
      }
    }
    return .reorder(index: items.count - 1, insertionX: (visible.last?.frame.maxX ?? 6) + 2)
  }
}
