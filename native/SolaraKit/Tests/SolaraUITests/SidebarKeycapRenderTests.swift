import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct SidebarKeycapRenderTests {
  private func inkBounds(_ view: NSView) throws -> NSRect {
    let scale: CGFloat = 2
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int((view.bounds.width * scale).rounded()), pixelsHigh: Int((view.bounds.height * scale).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide == Int(view.bounds.width * scale))
    #expect(bitmap.pixelsHigh == Int(view.bounds.height * scale))
    var left = bitmap.pixelsWide
    var top = bitmap.pixelsHigh
    var right = -1
    var bottom = -1
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        left = min(left, x)
        top = min(top, y)
        right = max(right, x)
        bottom = max(bottom, y)
      }
    }
    try #require(right >= left && bottom >= top, "The keycap must render visible glyph pixels")
    return NSRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
      width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
  }

  @Test(arguments: [false, true], [false, true])
  func renderedTooltipGlyphsAreCenteredWithoutChangingCapsOrGaps(dark: Bool, rail: Bool) throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let root = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    panel.contentView = root
    defer { panel.contentView = nil; panel.close() }
    let sidebar = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: rail ? 42 : 240, height: 700))
    root.addSubview(sidebar)
    let tooltip = SidebarDotTooltip()
    sidebar.addSubview(tooltip)
    defer { tooltip.hide(); tooltip.removeFromSuperview() }
    tooltip.look(dark: dark, panel: dark ? .darkGray : .white, border: .gray)
    for index in 0..<3 {
      let names = ["Personal", "Work", "🍌"]
      var state = SidebarRailProfileTests().state(count: 3, rail: rail, icon: "🍌")
      state.dark = dark
      state.currentProfileId = "p\(index)"
      for i in state.dots.indices { state.dots[i].name = names[i] }
      sidebar.update(state)
      let anchor: NSView
      if rail {
        anchor = sidebar.profileSwitcher
      } else {
        anchor = try #require(sidebar.profileScroll.documentView?.subviews.compactMap { $0 as? SidebarProfileDot }
          .first { $0.profileId == "p\(index)" })
      }
      let keys = ["⌃", "\(index + 1)"]
      tooltip.show(names[index], shortcut: keys.joined(), above: anchor)
      tooltip.appear(names[index])
      tooltip.alphaValue = 1
      tooltip.layer?.removeAllAnimations()
      let caps = tooltip.keycapViews
      #expect(caps.count == keys.count)
      #expect(tooltip.frame.height == SidebarDotTooltipMetrics.height)
      for (key, cap) in zip(keys, caps) {
        let pixel = 1 / (tooltip.window?.backingScaleFactor ?? 2)
        #expect(abs(cap.frame.width - SidebarDotTooltipMetrics.keycapWidth(key)) <= pixel + 0.001)
        #expect(cap.frame.height == SidebarDotTooltipMetrics.keycapHeight)
        #expect(abs(cap.frame.minY - (SidebarDotTooltipMetrics.height - SidebarDotTooltipMetrics.keycapHeight) / 2) <= pixel / 2 + 0.001)
        for edge in [cap.frame.minX, cap.frame.maxX, cap.frame.minY] { #expect(abs((edge / pixel).rounded() * pixel - edge) < 0.001, "\(key) edge \(edge) is off the pixel grid") }
        #expect(cap.layer?.cornerRadius == SidebarDotTooltipMetrics.keycapRadius)
        #expect(cap.layer?.borderWidth == 0.5)
        let ink = try inkBounds(cap)
        #expect(abs(ink.midX - cap.bounds.midX) <= 0.5, "\(key) ink \(ink) in \(cap.bounds), dark=\(dark), rail=\(rail)")
        #expect(abs(ink.midY - cap.bounds.midY) <= 0.5, "\(key) ink \(ink) in \(cap.bounds), dark=\(dark), rail=\(rail)")
      }
      let pixel = 1 / (tooltip.window?.backingScaleFactor ?? 2)
      for pair in zip(caps, caps.dropFirst()) { #expect(abs(pair.1.frame.minX - pair.0.frame.maxX - SidebarDotTooltipMetrics.keycapGap) <= pixel + 0.001) }
      #expect(!panel.isVisible && !panel.isKeyWindow)
      tooltip.hide()
    }
  }
}
