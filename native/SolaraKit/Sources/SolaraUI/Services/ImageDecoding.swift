import AppKit
import ImageIO

public enum ImageDecoding {
  public static let faviconPixels = 128
  public static let drawnPixels = 32
  private static let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "solara.images.decode"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()

  public static func decoded(_ data: Data, maxPixels: Int = faviconPixels) async -> NSImage? {
    await withCheckedContinuation { continuation in
      queue.addOperation { continuation.resume(returning: decodedNow(data, maxPixels: maxPixels)) }
    }
  }

  static func frame(widths: [Int], drawn: Int = drawnPixels) -> Int? {
    let sized = widths.enumerated().filter { $0.element > 0 }
    if let fitting = sized.filter({ $0.element >= drawn }).min(by: { $0.element < $1.element }) { return fitting.offset }
    return sized.max(by: { $0.element < $1.element })?.offset
  }

  public static func isImage(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0, CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
    {
      return true
    }
    return NSImage(data: data) != nil
  }

  public static func decodedNow(_ data: Data, maxPixels: Int = faviconPixels) -> NSImage? {
    guard !data.isEmpty else { return nil }
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0
    else { return NSImage(data: data) }
    var widths: [Int] = []
    var sizes: [NSSize] = []
    for index in 0..<CGImageSourceGetCount(source) {
      guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0
      else {
        widths.append(0)
        sizes.append(.zero)
        continue
      }
      let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
      widths.append(width)
      sizes.append(NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi))
    }
    guard let best = frame(widths: widths) else { return NSImage(data: data) }
    let bestSize = sizes[best]
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return NSImage(data: data) }
    return NSImage(cgImage: image, size: bestSize)
  }
}
