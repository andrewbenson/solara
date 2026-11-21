import AppKit

@MainActor
final class PinnedScaleWindow: NSWindow {
  var pinnedScale: CGFloat = 2
  override var backingScaleFactor: CGFloat { pinnedScale }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class PinnedScalePanel: NSPanel {
  var pinnedScale: CGFloat = 2
  override var backingScaleFactor: CGFloat { pinnedScale }
}

@MainActor
enum PinnedScaleBitmap {
  static func render(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int((view.bounds.width * scale).rounded()), pixelsHigh: Int((view.bounds.height * scale).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
  }
}
