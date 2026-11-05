import CoreGraphics
import Foundation

public enum ExtensionPopupGeometry {
  public static func size(preferred: CGSize, bounds: CGRect) -> CGSize {
    CGSize(
      width: min(max(0, bounds.width - 16), min(800, max(25, ceil(preferred.width))) + 1),
      height: min(max(0, bounds.height - 16), min(600, max(25, ceil(preferred.height))) + 1))
  }

  public static func frame(anchor: CGRect, preferred: CGSize, bounds: CGRect) -> CGRect {
    let size = size(preferred: preferred, bounds: bounds)
    let left = bounds.minX + min(8, max(0, bounds.width / 2))
    let top = bounds.minY + min(8, max(0, bounds.height / 2))
    return CGRect(
      x: max(left, min(anchor.maxX - size.width, bounds.maxX - 8 - size.width)),
      y: max(top, min(anchor.maxY + 6, bounds.maxY - 8 - size.height)),
      width: size.width, height: size.height)
  }
}
