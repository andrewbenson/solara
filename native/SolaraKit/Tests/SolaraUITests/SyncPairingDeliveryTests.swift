import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncPairingDeliveryTests {
  private func content(_ root: NSObject) -> (text: [String], accessibility: [String]) {
    var visited = Set<ObjectIdentifier>()
    func collect(_ object: NSObject) -> (text: [String], accessibility: [String]) {
      guard visited.insert(ObjectIdentifier(object)).inserted else { return ([], []) }
      var text = [(object as? NSTextView)?.string, (object as? NSTextField)?.stringValue].compactMap { $0 }
      var accessibility: [String] = []
      for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityIdentifier"] {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String { accessibility.append(value) }
      }
      var children = (object as? NSView)?.subviews.map { $0 as NSObject } ?? []
      let selector = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: selector), let values = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children += values }
      for child in children {
        let values = collect(child)
        text += values.text
        accessibility += values.accessibility
      }
      return (text, accessibility)
    }
    return collect(root)
  }

  @Test(arguments: [TrustedPhase.sentUnconfirmed, .confirmed])
  func deliveryStatusSurvivesNonforegroundSnapshotAndForegroundRegain(phase: TrustedPhase) async throws {
    await configurePairingTestApplication()
    let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let original = NSApp.accessibilityAttributeValue(attribute)
    NSApp.accessibilitySetValue(true, forAttribute: attribute)
    defer { NSApp.accessibilitySetValue(original ?? false, forAttribute: attribute) }
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { model.teardown() }
    model.attach(to: window)
    model.connect()
    let arm = try #require(model.arm)
    let comparison = service.ready(model)
    let root = NSHostingView(rootView: SyncTrustedPairingSheet(model: model))
    root.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
    root.layoutSubtreeIfNeeded()
    defer { withExtendedLifetime(root) {} }
    let comparing = content(root)
    try #require(comparing.text.contains { $0.contains(comparison.claimedName) })
    try #require(comparing.accessibility.contains(comparison.code))
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    service.holdAllow = true
    defer { service.heldAllow?.resume(); service.heldAllow = nil }
    model.captureAllow()()
    for _ in 0..<100 where service.heldAllow == nil { await Task.yield() }
    try #require(service.heldAllow != nil)
    service.heldAllow?.resume()
    service.heldAllow = nil
    for _ in 0..<100 where service.granted.isEmpty { await Task.yield() }
    try #require(service.granted.count == 1)
    let status = phase == .sentUnconfirmed ? "Approval sent; installation not confirmed" : "Approval received. Sync data is still downloading on your other Mac."
    let formattedCode = String(comparison.code.prefix(3)) + " " + comparison.code.suffix(3)
    for point in ["nonforeground", "foregroundRegained", "visibilityLost", "foregroundRegainedAfterLoss"] {
      if point == "visibilityLost" {
        model.surfaceChanged(.visibilityChanged)
      } else {
        service.publish(phase: phase, arm: arm, foreground: point != "nonforeground")
      }
      for _ in 0..<50 {
        root.layoutSubtreeIfNeeded()
        let values = content(root)
        if (values.text + values.accessibility).contains(status) { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      #expect(model.phase == phase)
      #expect(model.isPresented)
      #expect(!model.requiresExplicitPresentation)
      #expect(!model.canAllow)
      let delivered = content(root)
      #expect((delivered.text + delivered.accessibility).contains(status))
      for strings in [delivered.text, delivered.accessibility] {
        #expect(!strings.contains("Review request"))
        #expect(!strings.contains { $0.contains(comparison.claimedName) })
        #expect(!strings.contains { $0.contains(comparison.code) || $0.contains(formattedCode) })
        #expect(!strings.contains("Inspect name characters"))
        #expect(!strings.contains("sync-pairing-matched"))
      }
    }
  }
}
