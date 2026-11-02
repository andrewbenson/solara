import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncPairingPrivacyTests {
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

  private func inspector(_ root: NSObject) -> NSObject? {
    var queue = [root]
    var visited = Set<ObjectIdentifier>()
    while !queue.isEmpty {
      let object = queue.removeFirst()
      guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
      for name in ["accessibilityLabel", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String, value == "Inspect name characters" { return object }
      }
      queue += (object as? NSView)?.subviews.map { $0 as NSObject } ?? []
      let selector = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: selector), let values = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { queue += values }
    }
    return nil
  }

  @Test func authenticationRemovesPreviouslyExpandedInspectorFromSameHostedSheet() async throws {
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
    let comparison = service.ready(model)
    let root = NSHostingView(rootView: SyncTrustedPairingSheet(model: model))
    root.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
    root.layoutSubtreeIfNeeded()
    let button = try #require(inspector(root))
    if let accessible = button as? any NSAccessibilityProtocol {
      try #require(accessible.accessibilityPerformPress())
    } else {
      let selector = NSSelectorFromString("accessibilityPerformPress")
      try #require(button.responds(to: selector))
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      try #require(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
    }
    let characters = SyncPairingName.characters(comparison.claimedName)
    let escaped = SyncPairingName.escaped(comparison.claimedName)
    for _ in 0..<50 {
      root.layoutSubtreeIfNeeded()
      let values = content(root)
      if (values.text + values.accessibility).contains(characters) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let expanded = content(root)
    try #require((expanded.text + expanded.accessibility).contains(characters))
    try #require((expanded.text + expanded.accessibility).contains(escaped))
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    service.holdAllow = true
    model.captureAllow()()
    for _ in 0..<100 where service.heldAllow == nil { await Task.yield() }
    try #require(service.heldAllow != nil)
    defer { service.heldAllow?.resume(); service.heldAllow = nil }
    for _ in 0..<50 {
      root.layoutSubtreeIfNeeded()
      let values = content(root)
      if (values.text + values.accessibility).contains("Authorizing this connection…") { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.phase == .authenticating)
    #expect(model.comparison === comparison)
    #expect(model.presentedComparison == nil)
    let authenticating = content(root)
    for strings in [authenticating.text, authenticating.accessibility] {
      #expect(!strings.contains { $0.contains(comparison.claimedName) })
      #expect(!strings.contains { $0.contains(comparison.code) || $0.contains("ABC 234") })
      #expect(!strings.contains { $0.contains(characters) || $0.contains(escaped) })
      #expect(!strings.contains("Inspect name characters"))
      #expect(!strings.contains("sync-pairing-name-characters"))
    }
    #expect((authenticating.text + authenticating.accessibility).contains("Authorizing this connection…"))
  }

  @Test(arguments: ["panel", "replyTail", "foregroundRegained"])
  func authenticatingSheetHidesComparisonTextAndAccessibility(point: String) async throws {
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
    let comparingRoot = NSHostingView(rootView: SyncTrustedPairingSheet(model: model))
    comparingRoot.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
    comparingRoot.layoutSubtreeIfNeeded()
    defer { withExtendedLifetime(comparingRoot) {} }
    let comparing = content(comparingRoot)
    #expect(model.presentedComparison === comparison)
    #expect(comparing.text.contains { $0.contains(comparison.claimedName) })
    #expect(comparing.accessibility.contains(comparison.code))
    #expect(comparing.accessibility.contains("Inspect name characters"))
    model.setMatched(true, comparison: comparison, render: model.renderGeneration)
    service.holdAllow = true
    model.captureAllow()()
    for _ in 0..<100 where service.heldAllow == nil { await Task.yield() }
    try #require(service.heldAllow != nil)
    defer { service.heldAllow?.resume(); service.heldAllow = nil }
    if point != "panel" {
      service.livePanelArm = nil
      service.toleratingSoftLoss = true
      model.surfaceChanged(.visibilityChanged)
      service.publish(phase: .comparing, arm: arm, comparison: comparison, foreground: false)
    }
    if point == "foregroundRegained" {
      model.surfaceChanged(.foreground)
      service.publish(phase: .comparing, arm: arm, comparison: comparison)
    }
    #expect(model.phase == .authenticating)
    #expect(model.comparison === comparison)
    #expect(model.presentedComparison == nil)
    #expect(model.arm === arm)
    #expect(model.isPresented)
    #expect(!model.canAllow)
    #expect(service.panelLive(arm) == (point == "panel"))
    let authenticatingRoot = NSHostingView(rootView: SyncTrustedPairingSheet(model: model))
    authenticatingRoot.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
    authenticatingRoot.layoutSubtreeIfNeeded()
    defer { withExtendedLifetime(authenticatingRoot) {} }
    let authenticating = content(authenticatingRoot)
    let formattedCode = String(comparison.code.prefix(3)) + " " + comparison.code.suffix(3)
    for strings in [authenticating.text, authenticating.accessibility] {
      #expect(!strings.contains { $0.contains(comparison.claimedName) })
      #expect(!strings.contains { $0.contains(comparison.code) || $0.contains(formattedCode) })
      #expect(!strings.contains { $0.contains(SyncPairingName.characters(comparison.claimedName)) || $0.contains(SyncPairingName.escaped(comparison.claimedName)) })
      #expect(!strings.contains("Inspect name characters"))
      #expect(!strings.contains("sync-pairing-name-characters"))
      #expect(!strings.contains("sync-pairing-matched"))
    }
    #expect((authenticating.text + authenticating.accessibility).contains("Authorizing this connection…"))
  }
}
