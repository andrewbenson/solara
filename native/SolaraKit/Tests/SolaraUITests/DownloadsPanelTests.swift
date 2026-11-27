import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct DownloadsPanelTests {
  private func list(rows: Int = 0) -> DownloadsListState {
    DownloadsListState(
      rows: (0..<rows).map { DownloadRowState(id: "d\($0)", filename: "file\($0).zip", path: "/tmp/file\($0).zip", state: "finished", received: 10, total: 10, speed: 0, paused: false) },
      clearable: rows > 0, listMax: 400, dark: false, theme: [:])
  }

  private func panel(_ placement: DownloadsPanelPlacement, closing: Bool = false) async throws -> DownloadsPanelView {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    let v = DownloadsPanelView(frame: host.bounds)
    host.addSubview(v)
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: closing))
    for _ in 0..<20 where v.cardFrame == nil {
      try await Task.sleep(for: .milliseconds(10))
      v.layoutSubtreeIfNeeded()
    }
    return v
  }

  private func serviceRunLoop(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  @Test func itHangsBelowItsButtonWithTheArrowOnTop() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .top, arrowX: 30))
    let card = try #require(v.cardFrame)
    #expect(card.minX == 40 && card.minY == 60 && card.width == 300)
    #expect(v.list.frame.minY == DownloadsPanelMetrics.arrowHeight)
    #expect(card.height == v.list.frame.height + DownloadsPanelMetrics.arrowHeight)
  }

  @Test func itStandsOnItsBottomOffsetWhenItOpensUpward() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 10, bottom: 50, arrow: .bottom, arrowX: 20))
    let card = try #require(v.cardFrame)
    #expect(abs(card.maxY - (700 - 50)) < 0.01)
    #expect(v.list.frame.minY == 0)
  }

  @Test func outsideClicksAreCaughtAndInsideClicksReachTheList() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .none, arrowX: 150))
    let card = try #require(v.cardFrame)
    #expect(v.hitTest(NSPoint(x: 900, y: 50)) === v)
    let inside = v.hitTest(NSPoint(x: card.midX, y: 700 - card.midY))
    #expect(inside != nil && inside !== v)
    v.close()
    #expect(v.isClosing && v.hitTest(NSPoint(x: 900, y: 50)) == nil)
  }

  @Test func closingReportsClosedAndReopeningCancelsIt() async throws {
    let placement = DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .top, arrowX: 30)
    let v = try await panel(placement)
    var closed = 0
    v.onClosed = { closed += 1 }
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: true))
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: false))
    serviceRunLoop(for: 0.2)
    #expect(closed == 0 && !v.isClosing)
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: true))
    serviceRunLoop(for: 0.2)
    #expect(closed == 1)
  }
}

@MainActor
struct DownloadsNativeInputTests {
  @Test func downloadButtonRetainsItsLabelAndRequiresAnActiveClick() throws {
    let button = DownloadButtonView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    button.update(open: true, tooltip: nil, theme: ["icon": "#111111", "toolbarHover": "#222222", "toolbarPressed": "#333333"])
    let control = try #require(button.subviews.first as? PostcardControl)
    var clicks = 0
    button.onPress = { clicks += 1 }
    #expect(control.accessibilityLabel() == "Downloads")
    #expect(!control.acceptsFirstMouse(for: nil))
    #expect(control.accessibilityPerformPress())
    #expect(clicks == 1)
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    control.keyDown(with: space)
    #expect(clicks == 2)
    button.end()
    #expect(!control.accessibilityPerformPress())
  }

  @Test func downloadsControlsSupportKeyboardAndAccessibilityWithoutFirstClick() throws {
    let button = DownloadsTextButton(title: "Keep")
    var clicks = 0
    button.onPress = { clicks += 1 }
    #expect(button.acceptsFirstResponder)
    #expect(!button.acceptsFirstMouse(for: nil))
    #expect(button.accessibilityPerformPress())
    #expect(clicks == 1)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    button.keyDown(with: enter)
    #expect(clicks == 2)
  }

  @Test func endingAPanelCancelsItsPendingClosedReceipt() async throws {
    let panel = DownloadsPanelView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    var closed = 0
    panel.onClosed = { closed += 1 }
    panel.close()
    panel.end()
    try await Task.sleep(for: .milliseconds(30))
    #expect(closed == 0)
    #expect(panel.hitTest(CGPoint(x: 400, y: 400)) == nil)
  }
}

extension DownloadsPanelTests {
  @Test func placementUsesLiveButtonAndFallsBackWhenItLeavesTheWindow() {
    let viewport = CGSize(width: 800, height: 600)
    let upper = DownloadsPanelPlacement.resolve(in: viewport, anchor: CGRect(x: 756, y: 4, width: 36, height: 34), topStrip: true, footer: false)
    #expect(upper.placement == DownloadsPanelPlacement(width: 300, left: 492, top: 39, arrow: .top, arrowX: 282))
    let lower = DownloadsPanelPlacement.resolve(in: viewport, anchor: CGRect(x: 10, y: 540, width: 36, height: 34), topStrip: false, footer: true)
    #expect(lower.placement == DownloadsPanelPlacement(width: 300, left: 8, bottom: 61, arrow: .bottom, arrowX: 20))
    #expect(lower.listMax == 320)
    let fallback = DownloadsPanelPlacement.resolve(in: viewport, anchor: CGRect(x: -2, y: 540, width: 36, height: 34), topStrip: false, footer: true)
    #expect(fallback.placement.arrow == .none)
    #expect(fallback.placement.bottom == 43)
    let narrow = DownloadsPanelPlacement.resolve(in: CGSize(width: 260, height: 200),
      anchor: CGRect(x: 200, y: 4, width: 34, height: 34), topStrip: true, footer: false)
    #expect(narrow.placement == DownloadsPanelPlacement(width: 244, left: 8, top: 39, arrow: .top, arrowX: 209))
    #expect(narrow.listMax == 63)
    let short = DownloadsPanelPlacement.resolve(in: CGSize(width: 260, height: 80), anchor: nil, topStrip: false, footer: false)
    #expect(short.placement.top == 44)
    #expect(short.listMax == 40)
  }
}
