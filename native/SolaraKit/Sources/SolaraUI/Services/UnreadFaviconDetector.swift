import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public enum UnreadFaviconDetector {
  static let side = 32

  public static func hasDot(in data: Data) -> Bool {
    guard data.count <= 262_144,
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.intValue > 0, width.intValue <= 512, height.intValue > 0, height.intValue <= 512,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let pixels = pixels(in: image)
    else { return false }
    return hasDot(pixels: pixels)
  }

  static func pixels(in image: CGImage) -> [UInt8]? {
    guard image.width > 0, image.width <= 512, image.height > 0, image.height <= 512 else { return nil }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    return drawn ? pixels : nil
  }

  static func hasDot(pixels: [UInt8]) -> Bool {
    guard pixels.count == side * side * 4 else { return false }
    var saturated = [Bool](repeating: false, count: side * side)
    for index in saturated.indices {
      let offset = index * 4
      let alpha = Double(pixels[offset + 3]) / 255
      guard alpha >= 0.7 else { continue }
      let rgb = (0..<3).map { Double(pixels[offset + $0]) / (255 * alpha) }
      let high = rgb.max()!, low = rgb.min()!
      saturated[index] = high >= 0.65 && high - low >= 0.35
    }
    var seen = Set<Int>()
    for start in saturated.indices where saturated[start] && !seen.contains(start) {
      var component = [start]
      seen.insert(start)
      var cursor = 0
      while cursor < component.count {
        let index = component[cursor]
        cursor += 1
        let x = index % side, y = index / side
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
          let nx = x + dx, ny = y + dy
          guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
          let next = ny * side + nx
          if saturated[next] && seen.insert(next).inserted { component.append(next) }
        }
      }
      guard (8...100).contains(component.count) else { continue }
      let xs = component.map { $0 % side }, ys = component.map { $0 / side }
      let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
      let width = maxX - minX + 1, height = maxY - minY + 1
      let cornerX = maxX <= 13 || minX >= 18
      let cornerY = maxY <= 13 || minY >= 18
      guard cornerX, cornerY, (4...12).contains(width), (4...12).contains(height),
        Double(min(width, height)) / Double(max(width, height)) >= 0.7 else { continue }
      let fill = Double(component.count) / Double(width * height)
      guard fill >= 0.45, fill <= 0.9 else { continue }
      let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
      let radius = Double(max(width, height)) / 2
      let outside = component.filter {
        let dx = Double($0 % side) - cx, dy = Double($0 / side) - cy
        return dx * dx + dy * dy > radius * radius * 1.15
      }.count
      if Double(outside) / Double(component.count) <= 0.08 { return true }
    }
    return false
  }
}

struct UnreadFaviconImage: @unchecked Sendable {
  let image: CGImage
}

actor UnreadFaviconAnalyzer {
  private var cache: [String: Bool] = [:]
  private var order: [String] = []
#if DEBUG || SOLARA_PROBES
  private var requests = 0
  private var cacheHits = 0
  private var classifications = 0
  private var mainThreadAnalyses = 0

  func diagnostics() -> [String: Int] {
    ["requests": requests, "cacheHits": cacheHits, "classifications": classifications,
      "mainThreadAnalyses": mainThreadAnalyses, "cacheEntries": cache.count]
  }
#endif

  func hasDot(source: String, image: UnreadFaviconImage) -> Bool {
#if DEBUG || SOLARA_PROBES
    requests += 1
    if Thread.isMainThread { mainThreadAnalyses += 1 }
#endif
    guard !Task.isCancelled, let pixels = UnreadFaviconDetector.pixels(in: image.image) else { return false }
    let digest = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
    let key = source + "\u{0}" + digest
    if let cached = cache[key] {
#if DEBUG || SOLARA_PROBES
      cacheHits += 1
#endif
      return cached
    }
#if DEBUG || SOLARA_PROBES
    classifications += 1
#endif
    let result = UnreadFaviconDetector.hasDot(pixels: pixels)
    cache[key] = result
    order.append(key)
    if order.count > 512 { cache[order.removeFirst()] = nil }
    return result
  }
}
