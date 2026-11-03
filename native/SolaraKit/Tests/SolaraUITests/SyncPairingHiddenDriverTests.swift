#if DEBUG
import AppKit
import CoreFoundation
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
private enum PairingTestApplication {
  static var scheduled = false
  static var ready = false
  static var waiters: [CheckedContinuation<Void, Never>] = []

  static func configure() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    guard !ready else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
      guard !scheduled else { return }
      scheduled = true
      runAppAtTheOutermostRunLoop()
    }
  }

  private static func runAppAtTheOutermostRunLoop() {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated {
        guard !insideNestedRunLoop() else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { runAppAtTheOutermostRunLoop() }
          return
        }
        DispatchQueue.main.async {
          ready = true
          let pending = waiters
          waiters.removeAll()
          for waiter in pending { waiter.resume() }
        }
        NSApp.run()
      }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  private static func insideNestedRunLoop() -> Bool {
    let frames = Thread.callStackSymbols
    guard let loop = frames.firstIndex(where: { $0.contains("CFRunLoopRunSpecific") }), loop + 1 < frames.count else { return true }
    return !frames[loop + 1].contains(" CFRunLoopRun + ")
  }
}

@MainActor
func configurePairingTestApplication() async {
  await PairingTestApplication.configure()
}

@Suite(.serialized)
struct SyncPairingOffscreenTests {}

extension SyncPairingOffscreenTests {
  @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SOLARA_PAIRING_OFFSCREEN_TESTS"] == "1"))
  @MainActor
  struct SyncPairingHiddenDriverTests {
    private func prepare(_ variant: String? = nil) async throws -> (URL, NSPanel, NSWindow, SyncPairingFixtureHost) {
      let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-hidden-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
      let settings = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      settings.isReleasedWhenClosed = false
      settings.alphaValue = 0
      settings.contentViewController = NSHostingController(rootView: Text("Settings").frame(width: 800, height: 600))
      let host = SyncPairingFixtureHost(environment: ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": data.path, "SOLARA_SYNC_PAIRING_FIXTURE": "1"])
      let existingWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
      #expect(host.drive("mount", argument: variant, settingsWindow: settings)["mounted"] as? Bool == true)
      let panel = try #require(NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "sync-pairing-sensitive" })
      panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
      _ = host.drive("select", settingsWindow: settings)
      await settle()
      #expect(host.drive("state", settingsWindow: settings)["preparing"] as? Bool == true)
      let ready = host.drive("ready", settingsWindow: settings)
      #expect(ready["comparisonPresent"] as? Bool == true)
      await settle()
      try #require(settings.attachedSheet === panel)
      try #require(panel.sheetParent === settings)
      try #require(settings.sheets.contains { $0 === panel })
      let root = try #require(panel.contentView)
      root.layoutSubtreeIfNeeded()
      print("Pairing fixture topology: parent=\(settings.windowNumber), sheet=\(panel.windowNumber), attached=\(settings.attachedSheet === panel), sheetParent=\(panel.sheetParent === settings), sheets=\(settings.sheets.count), root=\(type(of: root)), state=\(host.drive("state", settingsWindow: settings))")
      return (data, settings, panel, host)
    }

    private func settle() async {
      pumpRunLoop()
      for _ in 0..<30 { await Task.yield() }
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async {
      for _ in 0..<100 {
        if predicate() { return }
        pumpRunLoop()
      }
    }

    private func pumpRunLoop() {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }

    private func verifyName(_ name: String, root: NSView) throws {
      root.layoutSubtreeIfNeeded()
      let text = try #require(descendants(root).compactMap { $0 as? NSTextView }.first { $0.string.contains(name) })
      let layout = try #require(text.layoutManager)
      let container = try #require(text.textContainer)
      layout.ensureLayout(for: container)
      let visibleGlyphs = layout.glyphRange(for: container)
      let renderedCharacters = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
      #expect(text.string == "Name the other Mac claims: “\u{2068}\(name)\u{2069}” — Unverified until the codes match.")
      #expect(renderedCharacters == NSRange(location: 0, length: text.string.utf16.count))
      #expect(layout.usedRect(for: container).height <= text.bounds.height + 1)
      #expect(text.bounds.width > 0)
      let storage = NSTextStorage(attributedString: text.attributedString())
      let actualWidthLayout = NSLayoutManager()
      let actualWidthContainer = NSTextContainer(size: NSSize(width: text.bounds.width, height: .greatestFiniteMagnitude))
      actualWidthContainer.lineFragmentPadding = container.lineFragmentPadding
      actualWidthLayout.addTextContainer(actualWidthContainer)
      storage.addLayoutManager(actualWidthLayout)
      actualWidthLayout.ensureLayout(for: actualWidthContainer)
      let actualUsed = actualWidthLayout.usedRect(for: actualWidthContainer)
      print("Hidden pairing name: width=\(text.bounds.width), height=\(text.bounds.height), liveWidth=\(container.containerSize.width), liveHeight=\(layout.usedRect(for: container).height), actualWidthHeight=\(actualUsed.height)")
      #expect(actualUsed.height <= text.bounds.height + 1)
      #expect(actualUsed.width <= text.bounds.width + 1)
      #expect(root.bounds.contains(text.convert(text.bounds, to: root)))
      var ancestor = text.superview
      while let view = ancestor {
        if let clip = view as? NSClipView {
          let nameFrame = text.convert(text.bounds, to: clip)
          print("Hidden pairing clip: bounds=\(clip.bounds), name=\(nameFrame)")
          #expect(clip.bounds.contains(nameFrame))
        }
        ancestor = view.superview
      }
      let allow = try #require(descendants(root).compactMap { $0 as? SyncAllowNativeButton }.first)
      #expect(root.bounds.contains(allow.convert(allow.bounds, to: root)))
      #expect(!allow.isHiddenOrHasHiddenAncestor)
    }

    @Test(arguments: ["longName", "confusable"], ["light", "dark"])
    func fullNameAndInspectionRemainBoundedInNonKeyPanel(_ variant: String, _ appearance: String) async throws {
      await configurePairingTestApplication()
      let (data, settings, panel, host) = try await prepare(variant)
      defer { host.destroy(); try? FileManager.default.removeItem(at: data) }
      settings.setFrameOrigin(NSPoint(x: -10000, y: -10000))
      #expect(settings.frame.maxX < 0)
      #expect(!settings.isKeyWindow)
      #expect(!panel.isKeyWindow)
      let name = variant == "longName" ? String(repeating: "é", count: 64) : "Fixture Studiо"
      let before = host.drive("state", settingsWindow: settings)
      #expect(before["nameFullyRendered"] as? Bool == true)
      try verifyName(name, root: #require(panel.contentView))
      _ = host.drive("inspect", settingsWindow: settings)
      await waitFor { host.drive("state", settingsWindow: settings)["inspectionComplete"] as? Bool == true }
      _ = host.drive(appearance, settingsWindow: settings)
      let after = host.drive("state", settingsWindow: settings)
      #expect(after["nameFullyRendered"] as? Bool == true)
      #expect(after["inspectionComplete"] as? Bool == true)
      #expect(after["controlsVisible"] as? Bool == true)
      #expect(after["checked"] as? Bool == false)
      try verifyName(name, root: #require(panel.contentView))
      #expect(!settings.isKeyWindow)
      #expect(!panel.isKeyWindow)
    }

    @Test func escapeDriverDeniesComparisonInNonKeyPanel() async throws {
      await configurePairingTestApplication()
      let (data, settings, panel, host) = try await prepare()
      defer { host.destroy(); try? FileManager.default.removeItem(at: data) }
      #expect(!panel.isKeyWindow)
      #expect(host.drive("check", settingsWindow: settings)["checked"] as? Bool == true)
      await settle()
      let escaped = host.drive("escape", settingsWindow: settings)
      #expect(escaped["error"] == nil, "\(escaped)")
      await waitFor { host.drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == false }
      let state = host.drive("state", settingsWindow: settings)
      #expect(state["comparisonPresent"] as? Bool == false)
      #expect(state["checked"] as? Bool == false)
      #expect(state["allowEnabled"] as? Bool == false)
      #expect(state["allowRequests"] as? Int == 0)
      #expect(!panel.isKeyWindow)
    }


    @Test func missingPairingControlsNeverSatisfyActionsOrState() async throws {
      await configurePairingTestApplication()
      let (data, settings, panel, host) = try await prepare()
      defer { host.destroy(); try? FileManager.default.removeItem(at: data) }
      let unrelated = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 540, height: 640), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      unrelated.isReleasedWhenClosed = false
      var unrelatedInvocations = 0
      let unrelatedAllow = SyncAllowNativeButton(frame: NSRect(x: 0, y: 0, width: 74, height: 24))
      unrelatedAllow.invoke = { unrelatedInvocations += 1 }
      unrelated.contentView = unrelatedAllow
      defer { unrelated.contentView = nil; unrelated.orderOut(nil) }
      panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 640))
      await settle()
      for action in ["uncheck", "check", "allow", "space", "return", "enter", "escape", "inspect", "saveTarget", "state", "ready", "light", "select", "present", "pressSaved", "hide", "show", "remount", "dark", "longName", "confusable"] {
        let result = host.drive(action, settingsWindow: settings)
        #expect(result["error"] as? String != nil, "\(action): \(result)")
        #expect(result["actionControlFound"] as? Bool == false, "\(action): \(result)")
      }
      let state = host.drive("state", settingsWindow: settings)
      let found = try #require(state["controlsFound"] as? [String: Bool])
      for control in ["allow", "checkbox", "deny", "inspect", "name"] { #expect(found[control] == false) }
      #expect(state["controlsVisible"] as? Bool == false)
      #expect(state["nameFullyRendered"] as? Bool == false)
      #expect(state["controlsVisibleReason"] as? String != nil)
      #expect(state["nameFullyRenderedReason"] as? String != nil)
      #expect(unrelatedInvocations == 0)
      #expect(!unrelated.isKeyWindow)
      #expect(!settings.isKeyWindow)
      #expect(!panel.isKeyWindow)
    }

    private func attach(_ child: NSWindow, to parent: NSWindow) {
      parent.beginSheet(child)
    }

    @Test func syntheticAttachedDescendantOwnsComparisonAndKeyDispatch() async throws {
      await configurePairingTestApplication()
      let (data, settings, panel, host) = try await prepare("longName")
      let child = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 540, height: 640), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      child.isReleasedWhenClosed = false
      child.alphaValue = 0
      defer {
        if child.sheetParent === panel { panel.endSheet(child) }
        child.orderOut(nil)
        child.contentView = nil
        host.destroy()
        try? FileManager.default.removeItem(at: data)
      }
      let content = try #require(panel.contentView)
      panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 640))
      child.contentView = content
      attach(child, to: panel)
      await settle()
      try #require(panel.attachedSheet === child)
      try #require(child.sheetParent === panel)
      try #require(panel.sheets.contains { $0 === child })
      #expect(host.drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == false)
      let presented = host.drive("present", settingsWindow: settings)
      #expect(presented["error"] == nil, "\(presented)")
      #expect(presented["actionControlFound"] as? Bool == true)
      await waitFor { host.drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == true }
      let state = host.drive("state", settingsWindow: settings)
      #expect(state["nameFullyRendered"] as? Bool == true, "\(state)")
      #expect(state["requiredControlsFound"] as? Bool == true, "\(state)")
      try verifyName(String(repeating: "é", count: 64), root: #require(child.contentView))
      for action in ["inspect", "check", "space"] {
        let result = host.drive(action, settingsWindow: settings)
        #expect(result["error"] == nil, "\(action): \(result)")
        #expect(result["actionControlFound"] as? Bool == true, "\(action): \(result)")
        await settle()
      }
      await waitFor { host.drive("state", settingsWindow: settings)["allowRequests"] as? Int == 1 }
      #expect(host.drive("state", settingsWindow: settings)["allowRequests"] as? Int == 1)
      #expect(!settings.isKeyWindow)
      #expect(!panel.isKeyWindow)
      #expect(!child.isKeyWindow)
    }

    @Test func overlappingFixturesRetainAccessibilityUntilLastDestroy() async throws {
      await configurePairingTestApplication()
      let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
      let original = NSApp.accessibilityAttributeValue(attribute) as? Bool ?? false
      let (firstData, firstSettings, firstPanel, first) = try await prepare()
      defer { first.destroy(); try? FileManager.default.removeItem(at: firstData) }
      let (secondData, secondSettings, secondPanel, second) = try await prepare()
      defer { second.destroy(); try? FileManager.default.removeItem(at: secondData) }
      first.destroy()
      let inspected = second.drive("inspect", settingsWindow: secondSettings)
      #expect(inspected["error"] == nil, "\(inspected)")
      #expect(inspected["actionControlFound"] as? Bool == true)
      await waitFor { second.drive("state", settingsWindow: secondSettings)["inspectionComplete"] as? Bool == true }
      #expect(second.drive("state", settingsWindow: secondSettings)["inspectionComplete"] as? Bool == true)
      second.destroy()
      #expect((NSApp.accessibilityAttributeValue(attribute) as? Bool ?? false) == original)
      #expect(!firstSettings.isKeyWindow)
      #expect(!secondSettings.isKeyWindow)
      #expect(!firstPanel.isKeyWindow)
      #expect(!secondPanel.isKeyWindow)
    }

    @Test func realSheetDenyActionCancelsInNonKeyPanel() async throws {
      await configurePairingTestApplication()
      let (data, settings, panel, host) = try await prepare()
      defer { host.destroy(); try? FileManager.default.removeItem(at: data) }
      #expect(host.drive("check", settingsWindow: settings)["checked"] as? Bool == true)
      await settle()
      var queue: [Any] = [try #require(panel.contentView)]
      var seen = Set<ObjectIdentifier>()
      var pressed = false
      while !queue.isEmpty, seen.count < 2000 {
        let item = queue.removeFirst()
        guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
        func value(_ name: String) -> Any? {
          let selector = NSSelectorFromString(name)
          return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        if value("accessibilityLabel") as? String == "Deny" {
          let selector = NSSelectorFromString("accessibilityPerformPress")
          guard object.responds(to: selector) else { continue }
          typealias Press = @convention(c) (AnyObject, Selector) -> Bool
          pressed = unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
          break
        }
        queue += value("accessibilityChildren") as? [Any] ?? []
      }
      #expect(pressed)
      await waitFor { host.drive("state", settingsWindow: settings)["comparisonPresent"] as? Bool == false }
      let state = host.drive("state", settingsWindow: settings)
      #expect(state["comparisonPresent"] as? Bool == false)
      #expect(state["checked"] as? Bool == false)
      #expect(state["allowEnabled"] as? Bool == false)
      #expect(state["allowRequests"] as? Int == 0)
      #expect(!panel.isKeyWindow)
    }
  }
}
#endif
