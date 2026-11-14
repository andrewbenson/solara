import AppKit
import Testing

@testable import SolaraUI

@MainActor @Suite struct LittleSolaraShellTests {
  final class Flipped: NSView {
    override var isFlipped: Bool { true }
  }

  func shell() -> (LittleSolaraShellView, NSView, NSView) {
    let host = Flipped(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    let shell = LittleSolaraShellView(windowId: "w")
    host.addSubview(shell)
    shell.frame = host.bounds
    let react = Flipped()
    react.identifier = LittleSolaraShellView.passThroughIdentifier
    let panel = Flipped(frame: NSRect(x: 84, y: 5, width: 300, height: 200))
    react.addSubview(panel)
    shell.mount(.react, react)
    shell.mount(.backdrop, Flipped())
    shell.bar.update(SmallBarState.decode(#"{"tabId":"t","icon":"favicon","url":"https://a.test/","favicon":null,"profileId":"p","host":"a.test","title":"A","loading":false,"progress":0,"hidden":false,"buttons":[{"id":"copy","icon":"link","size":14,"tooltip":"Copy Link"},{"id":"open","icon":"arrow.up.left.and.arrow.down.right","size":13,"tooltip":"Open"}],"profile":null,"theme":{"dark":true,"colors":{},"panelShadowOpacity":0.2}}"#)!)
    shell.layoutSubtreeIfNeeded()
    return (shell, react, panel)
  }

  @Test func layoutMatchesTheEarlyWindow() {
    let (shell, react, _) = shell()
    #expect(shell.barFrame == CGRect(x: 0, y: 0, width: 900, height: 38))
    #expect(shell.cardFrame == CGRect(x: 6, y: 38, width: 888, height: 596))
    #expect(react.frame == shell.bounds)
    #expect(shell.bar.frame.size == CGSize(width: 900, height: 38))
    #expect(LittleSolaraMetrics.lightsCenter == CGPoint(x: 20, y: 19))
    #expect(shell.subviews.map { shell.view(in: .backdrop) === $0 ? "backdrop" : shell.view(in: .react) === $0 ? "react" : "bar" } == ["backdrop", "bar", "react"])
  }

  @Test func aNativePopupInTheReactSlotReceivesHitsAboveThePage() {
    let (shell, react, panel) = shell()
    panel.isHidden = true
    let popup = Flipped(frame: CGRect(x: 650, y: 39, width: 201, height: 81))
    react.addSubview(popup)
    #expect(shell.hitTest(NSPoint(x: 700, y: 60)) === popup)
    let blank = shell.hitTest(NSPoint(x: 60, y: 19))
    #expect(blank != nil && !(blank!.isDescendant(of: react)))
  }

  @Test func reactViewsWinOverTheBarAndBlankReactFallsThrough() {
    let (shell, _, panel) = shell()
    #expect(shell.hitTest(NSPoint(x: 100, y: 20)) === panel)
    panel.isHidden = true
    let button = shell.hitTest(NSPoint(x: 900 - 6 - 14, y: 19))
    #expect(button != nil && button!.isDescendant(of: shell.bar))
    let blank = shell.hitTest(NSPoint(x: 60, y: 19))
    #expect(blank != nil && !(blank!.isDescendant(of: shell.bar)) && blank !== shell.view(in: .react))
  }
}
