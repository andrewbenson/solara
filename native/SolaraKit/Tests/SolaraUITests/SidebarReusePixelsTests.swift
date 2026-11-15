import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarReusePixelsTests {
  private struct Pixels {
    let bitmap: NSBitmapImageRep
    let rgba: [UInt8]
    let width: Int
    let height: Int

    var opaque: Int { stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 16 }.count }
    var colors: Int { Set(stride(from: 0, to: rgba.count, by: 4).map { Array(rgba[$0..<($0 + 4)]) }).count }

    func iconRange(_ rect: CGRect, channel: Int) -> Int {
      let left = max(0, Int((rect.minX * 2).rounded(.up)))
      let right = min(width, Int((rect.maxX * 2).rounded(.down)))
      let top = max(0, Int((rect.minY * 2).rounded(.up)))
      let bottom = min(height, Int((rect.maxY * 2).rounded(.down)))
      let values = (top..<bottom).flatMap { y in (left..<right).map { x in Int(rgba[(y * width + x) * 4 + channel]) } }
      return (values.max() ?? 0) - (values.min() ?? 0)
    }
  }

  func icon() throws -> NSImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
    let bytes = try #require(bitmap.bitmapData)
    for y in 0..<16 {
      for x in 0..<16 {
        let offset = y * bitmap.bytesPerRow + x * 4
        bytes[offset] = UInt8(x * 17)
        bytes[offset + 1] = UInt8(y * 17)
        bytes[offset + 2] = x < 8 ? 51 : 217
        bytes[offset + 3] = 255
      }
    }
    return NSImage(cgImage: try #require(bitmap.cgImage), size: NSSize(width: 16, height: 16))
  }

  private func capture(_ view: NSView, scale: CGFloat) throws -> Pixels {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    view.layer?.layoutIfNeeded()
    view.layer?.displayIfNeeded()
    CATransaction.flush()
    let width = Int((view.bounds.width * scale).rounded())
    let height = Int((view.bounds.height * scale).rounded())
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: scale, y: scale)
    try #require(view.layer).render(in: context)
    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return Pixels(bitmap: bitmap, rgba: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)), width: width, height: height)
  }

  private func save(_ pixels: Pixels, name: String, directory: URL?) throws {
    guard let directory else { return }
    let png = try #require(pixels.bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent(name + ".png"))
  }

  @Test(.enabled(if: !(ProcessInfo.processInfo.environment["SOLARA_REUSE_PIXELS_JOB"] ?? "").isEmpty))
  func freshAndReboundSelectedRowsRenderIdenticalMeaningfulPixels() async throws {
    let directory: URL?
    if let job = ProcessInfo.processInfo.environment["SOLARA_REUSE_PIXELS_JOB"], !job.isEmpty {
      let root = URL(fileURLWithPath: job, isDirectory: true).standardizedFileURL
      directory = root.appendingPathComponent("reuse-pixels", isDirectory: true)
      try FileManager.default.createDirectory(at: try #require(directory), withIntermediateDirectories: true)
    } else { directory = nil }
    var metrics: [[String: Any]] = []
    for dark in [false, true] {
      let image = try icon()
      let favicons = SidebarFavicons()
      favicons.loader = { _ in image }
      let request = SidebarFaviconRequest(url: "https://reuse-pixels.test/", favicon: nil, profileId: "p", dark: dark)
      await withCheckedContinuation { continuation in favicons.load(request) { _ in continuation.resume() } }
      let entry = try #require(favicons.cached(request))
      let cached = try #require(entry)
      #expect(cached === image)
      for mode in ["full", "tile", "rail"] {
        var state = try SidebarViewportTests.state(2)
        for id in ["t0", "t1"] {
          state.tabs[id]?.url = request.url
          state.tabs[id]?.title = "Repeatable Row"
          state.tabs[id]?.pinned = mode == "tile"
        }
        state.windows["w"]?.activeTabIds["p"] = "t1"
        var host = SidebarHostState(profileId: "p", dark: dark)
        host.border = ["#D3B5FF99", "#68527FFF"]
        host.glow = SidebarGlow(color: "#B48AFF99", opacity: 0.45, radius: 6)
        let context = SidebarContext(state: state, host: host, windowId: "w", favicons: favicons)
        context.virtualizesRows = true
        let size: NSSize = mode == "tile" ? NSSize(width: 86, height: 41) : mode == "rail" ? NSSize(width: 30, height: 30) : NSSize(width: 178, height: 34)
        let crop = NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16)
        let panel = NSPanel(contentRect: crop, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = SidebarLayer(frame: crop)
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor
        panel.contentView = root
        defer { panel.contentView = nil; panel.close() }
        func make() -> SidebarRowView {
          switch mode {
          case "tile": TileView()
          case "rail": RailTabView()
          default: TabRowView()
          }
        }
        func item(_ id: String) -> SidebarItem {
          SidebarItem(kind: mode == "tile" ? .tile(id) : .tab(id), frame: NSRect(origin: CGPoint(x: 8, y: 8), size: size),
            region: mode == "tile" ? .fixed : .scroll, groups: [], section: mode == "tile" ? .tiles : .list)
        }
        func iconFrame(_ view: NSView) -> CGRect? {
          if view is TabIconView { return root.convert(view.bounds, from: view) }
          return view.subviews.lazy.compactMap(iconFrame).first
        }
        let fresh = make()
        fresh.frame = item("t1").frame
        root.addSubview(fresh)
        fresh.update(item("t1"), context)
        root.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let before = try capture(root, scale: 2)
        let beforeIcon = try #require(iconFrame(fresh))
        fresh.removeFromSuperview()
        let reused = make()
        reused.frame = item("t0").frame
        root.addSubview(reused)
        reused.update(item("t0"), context)
        root.layoutSubtreeIfNeeded()
        reused.hovered = true
        reused.pressed = true
        reused.prepareForReuse()
        reused.frame = item("t1").frame
        root.addSubview(reused)
        reused.update(item("t1"), context)
        root.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let after = try capture(root, scale: 2)
        let afterIcon = try #require(iconFrame(reused))
        #expect(beforeIcon == afterIcon)
        #expect(before.iconRange(beforeIcon, channel: 0) > 180 && before.iconRange(beforeIcon, channel: 1) > 180)
        #expect(after.iconRange(afterIcon, channel: 0) > 180 && after.iconRange(afterIcon, channel: 1) > 180)
        #expect(!panel.isVisible && !panel.isKeyWindow)
        #expect(before.width == after.width && before.height == after.height)
        #expect(before.opaque > before.width * before.height / 4 && after.opaque > after.width * after.height / 4)
        #expect(before.colors > 32 && after.colors > 32)
        var changed = 0
        var total = 0
        var maximum = 0
        for (left, right) in zip(before.rgba, after.rgba) {
          let delta = abs(Int(left) - Int(right))
          if delta != 0 { changed += 1 }
          total += delta
          maximum = max(maximum, delta)
        }
        let name = "\(mode)-\(dark ? "dark" : "light")"
        metrics.append(["name": name, "width": before.width, "height": before.height, "scale": 2,
          "beforeOpaquePixels": before.opaque, "afterOpaquePixels": after.opaque, "beforeUniqueColors": before.colors,
          "afterUniqueColors": after.colors, "beforeIconRedRange": before.iconRange(beforeIcon, channel: 0),
          "beforeIconGreenRange": before.iconRange(beforeIcon, channel: 1), "afterIconRedRange": after.iconRange(afterIcon, channel: 0),
          "afterIconGreenRange": after.iconRange(afterIcon, channel: 1), "changedChannels": changed, "maximumChannelDelta": maximum,
          "meanAbsoluteChannelDelta": Double(total) / Double(before.rgba.count), "sameCachedImage": cached === image])
        try save(before, name: name + "-fresh", directory: directory)
        try save(after, name: name + "-rebound", directory: directory)
        if let directory {
          let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
          try data.write(to: directory.appendingPathComponent("metrics.json"))
        }
        #expect(changed == 0, "\(name): \(changed) changed channels, maximum delta \(maximum)")
        reused.prepareForReuse()
      }
    }
  }
}
