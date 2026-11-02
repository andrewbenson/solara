#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class PairingOffscreenSettingsPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension SyncPairingOffscreenTests {
  @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SOLARA_PAIRING_OFFSCREEN_TESTS"] == "1"))
  @MainActor
  struct SyncPairingReusedWindowTests {
    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }

    private func turn() async {
      pump()
      for _ in 0..<20 { await Task.yield() }
    }

    private func pump() {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    @Test func hiddenDriverHistoryKeepsLongAndConfusableNamesFullyRendered() async throws {
      await configurePairingTestApplication()
      let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ac-pairing-reused-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
      let frames = data.appendingPathComponent("frames")
      try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
      let settings = PairingOffscreenSettingsPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
      settings.isReleasedWhenClosed = false
      settings.alphaValue = 0
      settings.contentViewController = NSHostingController(rootView: Text("Settings").frame(width: 800, height: 600))
      let host = SyncPairingFixtureHost(environment: ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": data.path, "SOLARA_SYNC_PAIRING_FIXTURE": "1"])
      defer { host.destroy(); settings.orderOut(nil); try? FileManager.default.removeItem(at: data) }
      var panel: NSWindow?
      func drive(_ action: String, _ argument: String? = nil) async -> [String: Any] {
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let result = host.drive(action, argument: argument, settingsWindow: settings)
        if action == "mount" {
          panel = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "sync-pairing-sensitive" }
          #expect(settings.attachedSheet === panel)
          #expect(panel?.sheetParent === settings)
          #expect(settings.sheets.contains { $0 === panel })
        }
        settings.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        await turn()
        settings.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        #expect(!settings.isKeyWindow)
        #expect(panel?.isKeyWindow != true)
        #expect(settings.frame.maxX < 0)
        return result
      }
      func waitFor(_ predicate: ([String: Any]) -> Bool) async -> [String: Any] {
        var state: [String: Any] = [:]
        for _ in 0..<100 {
          state = await drive("state")
          if predicate(state) { return state }
        }
        Issue.record("Fixture did not reach the expected structural state")
        return state
      }
      func mountReady(_ variant: String? = nil) async {
        _ = await drive("mount", variant)
        _ = await drive("select")
        _ = await waitFor { $0["preparing"] as? Bool == true }
        _ = await drive("ready")
        _ = await waitFor { $0["comparisonPresent"] as? Bool == true }
      }

      _ = await drive("mount")
      _ = await drive("ready")
      #expect(await drive("state")["comparisonPresent"] as? Bool == false)
      _ = await drive("select")
      _ = await waitFor { $0["preparing"] as? Bool == true }
      _ = await drive("ready")
      _ = await waitFor { $0["comparisonPresent"] as? Bool == true }
      #expect(await drive("snapshot", frames.appendingPathComponent("initial.png").path)["snapshotSaved"] as? Bool == true)
      for action in ["allow", "space", "check", "return", "enter", "destroy"] { _ = await drive(action) }

      await mountReady()
      for action in ["check", "saveTarget", "uncheck", "check", "pressSaved", "allow"] { _ = await drive(action) }
      _ = await waitFor { $0["allowRequests"] as? Int == 1 }
      _ = await drive("allow")
      _ = await drive("destroy")

      for action in ["space", "allow"] {
        await mountReady()
        _ = await drive("check")
        _ = await drive(action)
        _ = await waitFor { $0["allowRequests"] as? Int == 1 }
        _ = await drive("destroy")
      }

      for transition in ["hide", "remount"] {
        await mountReady()
        for action in ["check", "saveTarget", transition, "ready", "show", "pressSaved"] { _ = await drive(action) }
        #expect(await drive("state")["comparisonPresent"] as? Bool == false)
        _ = await drive("present")
        _ = await waitFor { $0["comparisonPresent"] as? Bool == true }
        _ = await drive("destroy")
      }

      for variant in ["longName", "confusable"] {
        await mountReady(variant)
        _ = await drive("inspect")
        _ = await waitFor { $0["inspectionComplete"] as? Bool == true }
        for appearance in ["light", "dark"] {
          _ = await drive(appearance)
          let state = await drive("state")
          let sheet = try #require(panel)
          let root = try #require(sheet.contentView)
          let name = variant == "longName" ? String(repeating: "é", count: 64) : "Fixture Studiо"
          let text = try #require(descendants(root).compactMap { $0 as? NSTextView }.first { $0.string.contains(name) })
          let layout = try #require(text.layoutManager)
          let container = try #require(text.textContainer)
          print("Reused hidden pairing: variant=\(variant), appearance=\(appearance), state=\(state), bounds=\(text.bounds), container=\(container.containerSize), used=\(layout.usedRect(for: container)), sheetParent=\(sheet.sheetParent === settings), sheets=\(settings.sheets.count), root=\(root.bounds)")
          #expect(state["nameFullyRendered"] as? Bool == true)
          #expect(state["inspectionComplete"] as? Bool == true)
          #expect(state["controlsVisible"] as? Bool == true)
          #expect(state["checked"] as? Bool == false)
          layout.ensureLayout(for: container)
          #expect(layout.usedRect(for: container).height <= text.bounds.height + 1)
          #expect(layout.usedRect(for: container).width <= text.bounds.width + 1)
          #expect(root.bounds.contains(text.convert(text.bounds, to: root)))
          #expect(!sheet.isKeyWindow)
          #expect(await drive("snapshot", frames.appendingPathComponent("\(variant)-\(appearance).png").path)["snapshotSaved"] as? Bool == true)
        }
        _ = await drive("destroy")
      }
    }
  }
}
#endif
