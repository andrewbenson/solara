import Foundation

public enum WindowEdgeGeometry {
  public static func inside(_ point: CGPoint, window: CGRect, hold: CGFloat, right: Bool) -> Bool {
    let distance = right ? window.maxX - point.x : point.x - window.minX
    return point.y >= window.minY && point.y < window.maxY && distance >= 0 && distance < hold
  }

  public static func outside(_ point: CGPoint, window: CGRect, screen: CGRect, reach: CGFloat, right: Bool) -> Bool {
    let distance = right ? point.x - window.maxX : window.minX - point.x
    let room = right ? screen.maxX - window.maxX : window.minX - screen.minX
    return point.y >= window.minY && point.y < window.maxY && distance > 0 && distance <= min(reach, room)
  }
}
