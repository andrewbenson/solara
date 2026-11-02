import AppKit
import Foundation
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct SyncPairingControlTests {
  @Test func T07_T08_nameIsCanonicalFullAndAlwaysInspectable() {
    for name in ["Studio Mac", "paypaI", "раураl", "Mac 😺", "مرحبا", String(repeating: "é", count: 64)] {
      #expect(SyncPairingName.isValid(name))
      #expect(SyncPairingName.characters(name).split(separator: " ").count == name.unicodeScalars.count)
      #expect(SyncPairingName.escaped(name).contains("\\u{"))
    }
    for name in ["", String(repeating: "😺", count: 33), "bad\nname", "\u{202e}bad", "e\u{301}"] {
      #expect(!SyncPairingName.isValid(name))
    }
    #expect(SyncPairingName.characters("😺é") == "U+1F63A U+00E9")
    #expect(SyncPairingName.escaped("😺é") == "\\u{1F63A}\\u{00E9}")
    #expect(SyncPairingName.warning("раураl", knownNames: ["paypal"]) == true)
    #expect(SyncPairingName.warning("Studio Mac", knownNames: []) == false)
  }

  @Test func T09_nativeAllowConsumesReturnAndKeypadEnterButSpaceIsExplicit() {
    let button = SyncAllowNativeButton(frame: .zero)
    var allowed = 0
    var denied = 0
    button.invoke = { allowed += 1 }
    button.deny = { denied += 1 }
    button.isEnabled = true
    for code: UInt16 in [36, 76] {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
      button.keyDown(with: event)
      #expect(button.performKeyEquivalent(with: event))
    }
    #expect(allowed == 0)
    #expect(denied == 4)
    #expect(button.keyEquivalent.isEmpty)
    button.performClick(nil)
    #expect(allowed == 1)
    button.isEnabled = false
    button.performClick(nil)
    #expect(allowed == 1)
  }
  @Test func T09_inheritedWindowDefaultCannotReceiveReturnThroughAppKit() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let probe = SyncPairingProbeView(frame: window.contentView!.bounds)
    probe.sensitive = true
    var denied = 0
    var inheritedDefault = 0
    probe.deny = { denied += 1 }
    window.contentView = probe
    defer { probe.stopObserving() }
    let allow = SyncAllowNativeButton(frame: NSRect(x: 10, y: 10, width: 80, height: 24))
    let inherited = NSButton(title: "Inherited default", target: nil, action: nil)
    probe.addSubview(allow)
    probe.addSubview(inherited)
    let target = NativeDefaultTarget { inheritedDefault += 1 }
    inherited.target = target
    inherited.action = #selector(NativeDefaultTarget.pressed)
    inherited.keyEquivalent = "\r"
    window.defaultButtonCell = inherited.cell as? NSButtonCell
    window.makeFirstResponder(allow)
    for code: UInt16 in [36, 76] {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
      #expect(window.performKeyEquivalent(with: event))
    }
    #expect(denied == 2)
    #expect(inheritedDefault == 0)
  }

  @Test func T03_nativeRequestControlRetainsItsCapturedDescriptor() {
    let first = TrustedRequest(chainSuffix: "A", requestSuffix: "B", sessionSuffix: "C", firstObserved: 10)
    let replacement = TrustedRequest(chainSuffix: "D", requestSuffix: "E", sessionSuffix: "F", firstObserved: 10)
    var selected: [TrustedRequest] = []
    var latest = first
    let button = SyncRequestNativeButton(request: first) { selected.append($0) }
    latest = replacement
    button.performClick(nil)
    #expect(selected.count == 1)
    #expect(selected.first === first)
    #expect(selected.first !== latest)
  }

  @Test func V08_nativeClockUsesContinuousBootEpoch() {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let scale = Double(info.numer) / Double(info.denom) / 1_000_000_000
    let before = Double(mach_continuous_time()) * scale
    let actual = TrustedPairingClock.now()
    let after = Double(mach_continuous_time()) * scale
    #expect(actual >= before)
    #expect(actual <= after)
  }

}


@MainActor
private final class NativeDefaultTarget: NSObject {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func pressed() { action() }
}
