import AppKit
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarRetirementCaptureTests {
  private func pictures(_ view: NSView) -> [NSImageView] {
    let direct = view is SidebarLayer ? view.subviews.compactMap { $0 as? NSImageView } : []
    return direct + view.subviews.flatMap(pictures)
  }

  private func ink(_ image: NSImage) throws -> (red: Int, green: Int) {
    let source = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
      bytesPerRow: source.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    var red = 0, green = 0
    for index in stride(from: 0, to: source.width * source.height * 4, by: 4) where bytes[index + 3] > 160 {
      if bytes[index] > 180 && bytes[index + 1] < 70 && bytes[index + 2] > 150 { red += 1 }
      if bytes[index + 1] > 180 && bytes[index] < 70 && bytes[index + 2] < 120 { green += 1 }
    }
    return (red, green)
  }

  private func mounted(_ state: BrowserState, virtualized: Bool, favicons: SidebarFavicons = SidebarFavicons()) -> (NSPanel, SidebarView) {
    let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 190, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let sidebar = SidebarView(windowId: "w", favicons: favicons, virtualizesRows: virtualized)
    sidebar.frame = panel.contentView!.bounds
    panel.contentView = sidebar
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    sidebar.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
    CATransaction.flush()
    return (panel, sidebar)
  }

  @Test func anActualRetirementPictureKeepsTheCachedFaviconInk() async throws {
    let image = try SidebarReusePixelsTests().icon()
    let original = try ink(image)
    #expect(original.red > 4 && original.green > 4)
    let favicons = SidebarFavicons()
    favicons.loader = { _ in image }
    let request = SidebarFaviconRequest(url: "https://reuse-pixels.test/", favicon: nil, profileId: "p", dark: true)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      favicons.load(request) { _ in
        do {
          try checkRetirementPicture(image: image, original: original, favicons: favicons, request: request)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func checkRetirementPicture(image: NSImage, original: (red: Int, green: Int), favicons: SidebarFavicons, request: SidebarFaviconRequest) throws {
    var state = try SidebarViewportTests.state(6)
    state.tabs["t0"]?.url = request.url
    let (panel, sidebar) = mounted(state, virtualized: true, favicons: favicons)
    defer { sidebar.stop(); panel.contentView = nil; panel.close() }
    #expect(pictures(sidebar).isEmpty)
    let row = try #require(sidebar.views["t:t0"] as? TabRowView)
    #expect(row.tabId == "t0")
    let cachedEntry = try #require(favicons.cached(request))
    let cached = try #require(cachedEntry)
    #expect(cached === image)
    state.tabs["t0"] = nil
    state.windows["w"]?.tabIds.removeAll { $0 == "t0" }
    state.windows["w"]?.activeTabIds["p"] = "t1"
    sidebar.motion.fade = 60
    sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
    let picture = try #require(pictures(sidebar).first)
    let actual = try #require(picture.image)
    let captured = try ink(actual)
    if let job = ProcessInfo.processInfo.environment["SOLARA_REUSE_PIXELS_JOB"], !job.isEmpty {
      let directory = URL(fileURLWithPath: job, isDirectory: true).appendingPathComponent("reuse-pixels", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let source = try #require(actual.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let png = try #require(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
      try png.write(to: directory.appendingPathComponent("retiring-full-tab.png"))
      let metrics = ["sourceRedPixels": original.red, "sourceGreenPixels": original.green, "capturedRedPixels": captured.red, "capturedGreenPixels": captured.green]
      try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("retirement-ink.json"))
    }
    #expect(captured.red > 4 && captured.green > 4)
    #expect(!panel.isVisible && !panel.isKeyWindow)
  }

  @Test func removingOneOfTwoFixedTilesMatchesTheLegacyImmediateRemoval() throws {
    for virtualized in [false, true] {
      var state = try SidebarViewportTests.state(3)
      state.tabs["t0"]?.pinned = true
      state.tabs["t1"]?.pinned = true
      state.windows["w"]?.activeTabIds["p"] = "t2"
      let (panel, sidebar) = mounted(state, virtualized: virtualized)
      defer { sidebar.stop(); panel.contentView = nil; panel.close() }
      let removed = try #require(sidebar.views["tile:t0"])
      #expect(sidebar.pageLayout.tilesFixed)
      #expect(sidebar.pageLayout.items.first { $0.key == "tile:t0" }?.region == .fixed)
      #expect(sidebar.pageLayout.items.first { $0.key == "tile:t1" }?.region == .fixed)
      #expect(pictures(sidebar).isEmpty)
      state.tabs["t0"] = nil
      state.windows["w"]?.tabIds.removeAll { $0 == "t0" }
      sidebar.update(state: state, host: SidebarHostState(profileId: "p"))
      #expect(removed.superview == nil && sidebar.views["tile:t0"] == nil)
      let remaining = try #require(sidebar.views["tile:t1"])
      #expect(remaining.superview != nil && !remaining.isHiddenOrHasHiddenAncestor && remaining.alphaValue == 1)
      #expect(pictures(sidebar).isEmpty, "virtualized=\(virtualized)")
      #expect(!panel.isVisible && !panel.isKeyWindow)
    }
  }
}
