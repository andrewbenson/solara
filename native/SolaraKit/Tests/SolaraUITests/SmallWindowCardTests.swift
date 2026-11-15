import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SmallWindowCardTests {
  @Test func translucentFillKeepsItsAlphaAndFollowsResize() throws {
    let view = SmallWindowCardView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
    view.update(SmallWindowCardState(tabId: "little", fill: "rgba(255,255,255,0.7)", radius: 10))
    view.layoutSubtreeIfNeeded()
    let fill = try #require(view.layer?.sublayers?.first)
    let color = try #require(fill.backgroundColor)
    #expect(abs(color.alpha - 0.7) < 0.001)
    #expect(fill.frame == CGRect(x: 0, y: 0, width: 480, height: 360))
    #expect(fill.cornerRadius == 10)
    #expect(fill.masksToBounds)
    view.setFrameSize(CGSize(width: 610, height: 420))
    view.layoutSubtreeIfNeeded()
    #expect(fill.frame == CGRect(x: 0, y: 0, width: 610, height: 420))
    #expect(fill.animationKeys()?.isEmpty != false)
  }

  @Test func fullscreenAndUnmountRemoveTheFillWithoutLeavingRoundedPaint() throws {
    let view = SmallWindowCardView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
    view.update(SmallWindowCardState(tabId: "little", fill: "rgba(18,18,18,0.5)", radius: 10))
    let fill = try #require(view.layer?.sublayers?.first)
    #expect(fill.backgroundColor != nil)
    view.update(SmallWindowCardState(tabId: "little", fill: nil, radius: 0))
    #expect(fill.backgroundColor == nil)
    #expect(fill.cornerRadius == 0)
    view.update(nil)
    #expect(view.state == nil)
    #expect(fill.backgroundColor == nil)
    #expect(fill.animationKeys()?.isEmpty != false)
  }

  @Test func decorationLeavesPageHitsFocusAndAccessibilityOnTheExistingSibling() throws {
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
    let page = NSTextField(string: "Page control")
    page.frame = CGRect(x: 20, y: 20, width: 140, height: 24)
    page.setAccessibilityElement(true)
    root.addSubview(page)
    try #require(page.isAccessibilityElement())
    let view = SmallWindowCardView(frame: root.bounds)
    root.addSubview(view)
    view.update(SmallWindowCardState(tabId: "little", fill: "#ffffff", radius: 10))
    #expect(root.hitTest(CGPoint(x: 30, y: 30)) === page)
    #expect(view.hitTest(CGPoint(x: 240, y: 180)) == nil)
    #expect(!view.acceptsFirstResponder)
    #expect(!view.isAccessibilityElement())
    #expect(page.superview === root)
    #expect(page.isAccessibilityElement())
  }

  @Test func malformedStateClearsThePreviouslyPaintedCard() throws {
    let view = SmallWindowCardView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
    let valid = try #require(SmallWindowCardState.decode("{\"tabId\":\"little\",\"fill\":\"#ffffff\",\"radius\":10}"))
    view.update(valid)
    view.update(SmallWindowCardState.decode("{\"tabId\":\"little\"}"))
    #expect(view.state == nil)
    #expect(view.layer?.sublayers?.first?.backgroundColor == nil)
  }
}
