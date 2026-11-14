import AppKit
import Foundation
import SolaraUI

@main
struct FrozenPageHostTests {
  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedFrozenPage.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    var events: [[String: Any]] = []
    HostedViews.emit = { events.append($0) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let uri = "data:image/png;base64," + bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    func state(_ token: Int, copyId: String = "copy", uri: String?, dark: Bool = false) -> String {
      let value: [String: Any] = ["token": token, "tabId": "frozen", "copyId": copyId, "uri": uri.map { $0 as Any } ?? NSNull(), "dark": dark]
      return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    let content = HostedViews.make("frozenPage", windowId: "w")!
    let view = content.view as! FrozenPageView
    view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    expect(!content.takesFocus, "the frozen cover must preserve page focus")
    expect(view.acceptsFirstMouse(for: nil), "a frozen page in the inactive source window must accept its pullback click")
    content.onState?(state(1, uri: uri))
    let firstImage = view.image
    expect(firstImage != nil && !view.isHidden, "the captured data URI must reach the existing native picture")
    expect(view.washColor == NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4), "light wash must match the React surface")
    expect(events.count == 1 && events[0]["name"] as? String == "painted", "first decoded image must acknowledge once")
    expect((events[0]["payload"] as? [String: Any])?["token"] as? Int == 1, "painted must carry the identity assigned before show")
    content.onState?(state(1, uri: uri, dark: true))
    expect(view.image === firstImage && events.count == 1, "theme updates must retain the bitmap and avoid repeated acknowledgements")
    expect(view.washColor == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25), "dark wash must match the React surface")
    content.onState?(state(2, uri: uri, dark: true))
    expect(view.image === firstImage && events.count == 2, "a new bridge using the installed bitmap must acknowledge its new receipt once")
    expect((events.last?["payload"] as? [String: Any])?["token"] as? Int == 2, "a reused bitmap must acknowledge the latest receipt")
    _ = view.accessibilityPerformPress()
    expect(events.last?["name"] as? String == "press" && events.last?["windowId"] as? String == "w", "press must preserve its window and event kind")
    expect((events.last?["payload"] as? [String: Any])?["copyId"] as? String == "copy", "press must preserve the frozen-copy identity")
    let count = events.count
    content.onState?(state(3, copyId: "replacement", uri: uri))
    expect(view.image !== firstImage && events.count == count + 1, "a different copy must establish its own picture identity even with identical bytes")
    expect((events.last?["payload"] as? [String: Any])?["copyId"] as? String == "replacement", "replacement painting must never acknowledge the previous copy")
    content.onState?(state(4, uri: nil))
    expect(view.image == nil && !view.isHidden, "a frozen page with no capture must retain its native wash and hit surface")
    let beforeMissing = events.count
    content.onState?(state(5, uri: "https://example.invalid/image.png"))
    expect(view.image == nil && events.count == beforeMissing, "the host must not load network images or acknowledge an undecoded capture")
    content.onState?("invalid")
    _ = view.accessibilityPerformPress()
    expect(view.isHidden && events.count == beforeMissing, "invalid state must hide and disarm the cover")
    content.onState?(state(6, uri: uri))
    let replacement = HostedViews.make("frozenPage", windowId: "w")!
    replacement.onState?(state(7, uri: uri))
    content.onUnmount?()
    let beforeEnded = events.count
    content.onState?(state(8, uri: uri))
    _ = view.accessibilityPerformPress()
    expect(view.image == nil && events.count == beforeEnded, "an ended host must ignore stale state and actions")
    expect(HostedFrozenPage.describe("w") != nil, "a stale unmount must preserve another mounted cover")
    replacement.onUnmount?()
    expect(HostedFrozenPage.describe("w") == nil, "unmount must release inspection entries")
    if failures.isEmpty { print("PASS frozen host snapshot, wash, receipt, replacement and cleanup") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }
}
