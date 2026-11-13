import AppKit
import QuartzCore

@MainActor
final class DeveloperStripes {
  static let period: CGFloat = 36
  static let bandWidth: CGFloat = 18
  static let widthStep: CGFloat = 512

  let layer = CALayer()
  private(set) var ink: CGColor?
  private var uri: String?
  private var task: Task<Void, Never>?
  private var area = CGRect.zero
  private var scale: CGFloat = 2
  private var drawn: (size: CGSize, scale: CGFloat, ink: CGColor)?

  init() {
    layer.actions = SurfaceLayer.noActions
    layer.anchorPoint = .zero
    layer.contentsGravity = .resize
    layer.isHidden = true
  }

  var shown: Bool { !layer.isHidden }

  func show(_ next: String?) {
    guard next != uri else { return }
    task?.cancel()
    uri = next
    let image = next.flatMap(ToolbarView.localStripesImage)
    setInk(image.flatMap(Self.ink))
    guard let next, image == nil else { return }
    task = Task { [weak self] in
      let image = await ToolbarView.stripesImage(next)
      guard let self, !Task.isCancelled, self.uri == next else { return }
      self.setInk(image.flatMap(Self.ink))
    }
  }

  func fit(_ rect: CGRect, scale: CGFloat) {
    area = rect
    self.scale = scale > 0 ? scale : 2
    render()
  }

  private func setInk(_ color: CGColor?) {
    ink = color
    render()
  }

  private func render() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let ink, area.width > 0, area.height > 0 else {
      layer.isHidden = true
      layer.contents = nil
      drawn = nil
      return
    }
    let size = CGSize(width: (area.width / Self.widthStep).rounded(.up) * Self.widthStep, height: area.height.rounded(.up))
    if drawn?.size != size || drawn?.scale != scale || drawn?.ink != ink {
      layer.contents = Self.image(size: size, scale: scale, ink: ink)
      drawn = (size, scale, ink)
    }
    layer.contentsScale = scale
    layer.frame = CGRect(origin: area.origin, size: size)
    layer.isHidden = layer.contents == nil
  }

  static func ink(of image: NSImage) -> CGColor? {
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)?.cgColor
  }

  static func image(size: CGSize, scale: CGFloat, ink: CGColor) -> CGImage? {
    let width = Int((size.width * scale).rounded(.up))
    let height = Int((size.height * scale).rounded(.up))
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.setFillColor(ink)
    context.setShouldAntialias(true)
    let h = size.height
    let first = Int(((-h - bandWidth / 2) / period).rounded(.down))
    let last = Int(((size.width + bandWidth / 2) / period).rounded(.up))
    for k in first...last {
      let x = CGFloat(k) * period - bandWidth / 2
      context.move(to: CGPoint(x: x, y: 0))
      context.addLine(to: CGPoint(x: x + bandWidth, y: 0))
      context.addLine(to: CGPoint(x: x + bandWidth + h, y: h))
      context.addLine(to: CGPoint(x: x + h, y: h))
      context.closePath()
    }
    context.fillPath()
    return context.makeImage()
  }
}
