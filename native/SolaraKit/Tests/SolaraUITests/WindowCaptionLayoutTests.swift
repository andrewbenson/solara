import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct WindowCaptionLayoutTests {
  @Test(arguments: [false, true], [CGFloat(190), CGFloat(SidebarRail.width)])
  func openingWindowCentersTheActualButtonsBeforeAnyResizeOrFullscreenToggle(_ legacyOrder: Bool, _ width: CGFloat) throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    WindowCaptionLayout.configure(window)
    let shell = WindowShellView(windowId: "caption-opening", reactOnTop: legacyOrder)
    shell.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
    shell.update { $0.sidebarWidth = width }
    let react = FlippedContainerView(frame: shell.bounds)
    shell.mount(.react, react)
    let owner = FlippedContainerView(frame: shell.frames.card)
    react.addSubview(owner)
    let toolbar = ToolbarView(frame: CGRect(x: 0, y: 0, width: owner.bounds.width, height: ShellMetrics.toolbarHeight))
    owner.addSubview(toolbar)
    toolbar.update(ToolbarFrameTests.state(windowToolbar: true))
    shell.registerToolbar(toolbar, owner: owner)
    let center = shell.frames.lights ?? ShellMetrics.lightsCenter
    WindowCaptionLayout.position(in: window, center: center)
    shell.onCaptionLayout = { [weak window] in
      guard let window else { return }
      WindowCaptionLayout.refresh(in: window)
    }
    defer {
      shell.onCaptionLayout = nil
      shell.unregisterToolbar(toolbar)
      window.contentView = nil
      window.close()
    }
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let button = try #require(window.standardWindowButton(kind))
      button.setFrameOrigin(CGPoint(x: button.frame.minX, y: button.frame.minY + 8))
    }
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    let row = toolbar.convert(toolbar.bounds, to: shell)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let button = try #require(window.standardWindowButton(kind))
      let actual = button.convert(button.bounds, to: shell)
      #expect(abs(actual.midY - row.midY) <= 0.5)
    }
  }

  @Test func refreshingTheSameTargetRepairsActualButtonGeometry() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    WindowCaptionLayout.configure(window)
    defer { window.close() }
    let target = CGPoint(x: 25, y: 16)
    WindowCaptionLayout.position(in: window, center: target)
    var origins: [CGPoint] = []
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let button = try #require(window.standardWindowButton(kind))
      origins.append(button.frame.origin)
      button.setFrameOrigin(CGPoint(x: button.frame.minX, y: button.frame.minY + 8))
    }
    WindowCaptionLayout.refresh(in: window)
    let frame = try #require(window.contentView?.superview)
    for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
      let button = try #require(window.standardWindowButton(kind))
      let actual = frame.convert(button.bounds, from: button)
      #expect(abs(frame.bounds.maxY - actual.midY - target.y) <= 0.01)
      #expect(abs(button.frame.minX - origins[index].x) <= 0.01)
      #expect(abs(actual.midX - target.x - origins[index].x + origins[0].x) <= 0.01)
    }
  }

  @Test(arguments: [false, true]) func standardButtonsShareTheActualToolbarCenter(_ legacyOrder: Bool) throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    WindowCaptionLayout.configure(window)
    let shell = WindowShellView(windowId: "caption", reactOnTop: legacyOrder)
    window.contentView = shell
    shell.onLightsLayout = { [weak window, weak shell] in
      guard let window, let shell else { return }
      WindowCaptionLayout.position(in: window, center: shell.frames.lights ?? ShellMetrics.lightsCenter)
    }
    let react = FlippedContainerView(frame: shell.bounds)
    shell.mount(.react, react)
    let owner = FlippedContainerView(frame: shell.frames.card)
    react.addSubview(owner)
    let toolbar = ToolbarView(frame: owner.bounds)
    owner.addSubview(toolbar)
    var toolbarState = ToolbarFrameTests.state(windowToolbar: true)
    toolbarState.geometry = ToolbarGeometryState(sidebarButton: 21, back: 56, forward: 92, reload: 127, urlLeft: 145, urlRight: 12)
    toolbarState.left = try JSONDecoder().decode([ToolbarButtonState].self, from: Data(#"""
      [
      {"id":"sidebar","icon":"sidebar.left"},{"id":"back","icon":"chevron.left"},
      {"id":"forward","icon":"chevron.right"},{"id":"reload","icon":"arrow.clockwise"}]
      """#.utf8))
    toolbar.update(toolbarState)
    defer {
      shell.onLightsLayout = nil
      shell.unregisterToolbar(toolbar)
      window.contentView = nil
      window.close()
    }
    for width: CGFloat in [190, CGFloat(SidebarRail.width)] {
      shell.setSidebarWidth(width, animated: false)
      for dock: CGFloat in [1, 0, 1] {
        shell.update { $0.dock = dock }
        owner.frame = react.convert(shell.frames.card, from: shell)
        toolbar.frame = CGRect(origin: .zero, size: CGSize(width: owner.bounds.width, height: ShellMetrics.toolbarHeight))
        shell.registerToolbar(toolbar, owner: owner)
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(CGSize(width: 920, height: 670))
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(CGSize(width: 900, height: 650))
        window.contentView?.layoutSubtreeIfNeeded()
        let control = try #require(toolbar.layoutAnchors["button:sidebar"])
        let controlFrame = toolbar.convert(control, to: shell)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          let button = try #require(window.standardWindowButton(kind))
          let buttonFrame = button.convert(button.bounds, to: shell)
          #expect(abs(buttonFrame.midY - controlFrame.midY) <= 0.5)
          var ancestor = button.superview
          while let view = ancestor, view !== shell.superview {
            if view.clipsToBounds || view.layer?.masksToBounds == true {
              let inside = view.convert(button.bounds, from: button)
              #expect(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inside))
            }
            ancestor = view.superview
          }
          for (name, rect) in toolbar.layoutAnchors where name.hasPrefix("button:") {
            #expect(!buttonFrame.intersects(toolbar.convert(rect, to: shell)))
          }
        }
        let surfaceTop = shell.cardClip.convert(shell.cardClip.bounds, to: shell).minY
        let row = toolbar.convert(toolbar.bounds, to: shell)
        let expected = shell.input.chromeToolbarRow ? row.maxY : row.minY
        #expect(abs(surfaceTop - expected) <= 0.5)
      }
    }
  }
}
