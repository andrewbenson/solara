import AppKit
import QuartzCore
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarBackdropTests {
  @Test func backdropNeverInterceptsInputAndKeepsOnePointDivider() throws {
    let view = ToolbarBackdropView(frame: CGRect(x: 0, y: 0, width: 803, height: 41))
    view.update(ToolbarBackdropState(tabId: "a", background: "#2471A3", divider: "rgba(0,0,0,0.05)", hairline: true, stripes: nil))
    view.layoutSubtreeIfNeeded()
    #expect(view.hitTest(CGPoint(x: 100, y: 20)) == nil)
    #expect(!view.acceptsFirstResponder)
    #expect(!view.isAccessibilityElement())
    let layers = try #require(view.layer?.sublayers)
    #expect(layers[0].frame == view.bounds)
    #expect(layers[2].frame == CGRect(x: 0, y: 40.5, width: 803, height: 0.5))
    #expect(!layers[2].isHidden)
    view.setFrameSize(CGSize(width: 900, height: 42))
    view.layoutSubtreeIfNeeded()
    #expect(layers[0].frame == view.bounds)
    #expect(layers[2].frame == CGRect(x: 0, y: 41.5, width: 900, height: 0.5))
  }

  @Test func bandTransitionsFor180MillisecondsAndClearsWithoutAColorFlash() throws {
    let view = ToolbarBackdropView(frame: CGRect(x: 0, y: 0, width: 640, height: 41))
    var state = ToolbarBackdropState(tabId: "a", background: "#2471A3", divider: "rgba(0,0,0,0.05)", hairline: false, stripes: nil)
    view.update(state)
    let band = try #require(view.layer?.sublayers?.first)
    #expect(band.animation(forKey: "backgroundColor") == nil)
    state.background = "#C0392B"
    view.update(state)
    let animation = try #require(band.animation(forKey: "backgroundColor") as? CABasicAnimation)
    #expect(animation.duration == 0.18)
    #expect((animation.fromValue as! CGColor) == toolbarColor("#2471A3")?.cgColor)
    #expect((animation.toValue as! CGColor) == toolbarColor("#C0392B")?.cgColor)
    state.background = nil
    view.update(state)
    let clear = try #require(band.animation(forKey: "backgroundColor") as? CABasicAnimation)
    #expect((clear.toValue as! CGColor) == toolbarColor("#C0392B")?.cgColor.copy(alpha: 0))
    #expect(band.backgroundColor == nil)
    view.update(nil)
    #expect(band.animationKeys()?.isEmpty != false)
    #expect(view.state == nil)
  }

  @Test func stripesUseExistingNativePatternAndDisappearWithState() throws {
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../apps/browser/assets/developer-stripes-light.png").standardized
    let view = ToolbarBackdropView(frame: CGRect(x: 0, y: 0, width: 640, height: 41))
    view.update(ToolbarBackdropState(tabId: "a", background: nil, divider: "rgba(255,255,255,0.025)", hairline: true, stripes: asset.path))
    view.layoutSubtreeIfNeeded()
    let stripes = try #require(view.layer?.sublayers?[1])
    #expect(!stripes.isHidden)
    #expect(stripes.frame.width >= view.bounds.width)
    #expect(stripes.frame.height == view.bounds.height)
    view.update(nil)
    #expect(stripes.isHidden)
    #expect(stripes.contents == nil)
  }

  @Test func separatorIsOnePixelAcrossTheEntireBackdrop() throws {
    let view = ToolbarBackdropView(frame: CGRect(x: 0, y: 0, width: 600, height: 41))
    view.update(ToolbarBackdropState(tabId: "a", background: "#FFFFFF", divider: "#FF0000", hairline: true, stripes: nil))
    view.layoutSubtreeIfNeeded()
    let line = try #require(view.layer?.sublayers?.last)
    #expect(line.frame == CGRect(x: 0, y: 40.5, width: 600, height: 0.5))
    #expect(line.cornerRadius == 0 && line.mask == nil)
  }
}
