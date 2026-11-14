import AppKit
import Foundation
import SolaraUI

@main
struct SwipeHostTests {
  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    HostedSwipeCapsule.register()
    var failures: [String] = []
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
      if !value() { failures.append(message) }
    }
    var windows: [NSWindow] = []
    func mount(_ windowId: String, _ tabId: String) -> HostedContent {
      let content = HostedViews.make("swipeCapsule", windowId: windowId, state: "{\"tabId\":\"\(tabId)\"}")!
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
      content.view.frame = window.contentView!.bounds
      window.contentView!.addSubview(content.view)
      windows.append(window)
      return content
    }
    let first = mount("small", "a")
    let other = mount("other", "a")
    let capsule = first.view as! SwipeCapsuleView
    let otherCapsule = other.view as! SwipeCapsuleView
    expect(!first.takesFocus, "an overlay must not take page focus")
    HostedSwipeCapsule.send("small", "a", ["op": "show", "direction": "forward", "theme": ["dark": true, "textPrimary": "#ffffff", "textSecondary": "#aaaaaa"], "profileId": "work"])
    expect(capsule.shown && capsule.active && capsule.direction == .forward, "show must target the requested window and direction")
    expect(!otherCapsule.shown, "the same tab id in another window must remain untouched")
    HostedSwipeCapsule.send("small", "a", ["op": "confirm", "confirmed": true])
    expect(capsule.confirmed, "confirm must reach the native capsule")
    HostedSwipeCapsule.send("small", "a", ["op": "move", "x": 14])
    expect(abs(capsule.sample().frame.maxX - 786) < 0.01, "forward movement must use the native capsule's trailing edge")
    HostedSwipeCapsule.send("small", "a", ["op": "list", "items": [["title": "Two", "url": "https://two.invalid", "favicon": "data:image/png;base64,AA==", "newTab": false], ["title": "New Tab", "url": "", "newTab": true]]])
    expect(capsule.items?.count == 2 && capsule.items?[0].favicon == "data:image/png;base64,AA==" && capsule.items?[1].newTab == true, "list data must preserve icons and new-tab destinations")
    HostedSwipeCapsule.send("small", "a", ["op": "select", "index": 1, "nudge": 7])
    expect(capsule.selected == 1, "selection must reach the native list")
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    representation.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: 8, y: 8)
    let markURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOLARA_HOST_TEST_BUILD"]!).appendingPathComponent("swipe-host-mark.png")
    try! representation.representation(using: .png, properties: [:])!.write(to: markURL)
    HostedSwipeCapsule.loadMark(markURL.absoluteString, into: capsule)
    expect(capsule.favicons?.newTabMark != nil, "the host must load the real new-tab asset into native icon rendering")
    expect(capsule.selected == 1 && capsule.items?.last?.newTab == true, "loading a late mark must retain list destination identity and selection")
    try! FileManager.default.removeItem(at: markURL)
    let latest = mount("small", "a")
    first.onUnmount?()
    HostedSwipeCapsule.send("small", "a", ["op": "show", "direction": "back"])
    let latestCapsule = latest.view as! SwipeCapsuleView
    expect(latestCapsule.active && latestCapsule.direction == .back, "a stale unmount must not unregister a replacement")
    HostedSwipeCapsule.send("small", "a", ["op": "dismiss", "delay": 0])
    expect(!latestCapsule.active, "dismiss must end the gesture immediately")
    HostedSwipeCapsule.send("small", "a", ["op": "show", "direction": "forward"])
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    expect(latestCapsule.shown && latestCapsule.active, "a new gesture must cancel the old dismissal")
    latest.onState?("{\"tabId\":\"b\"}")
    HostedSwipeCapsule.send("small", "a", ["op": "confirm", "confirmed": true])
    expect(!latestCapsule.confirmed, "a rekeyed host must stop receiving the old tab's gestures")
    HostedSwipeCapsule.send("small", "b", ["op": "show", "direction": "back"])
    expect(latestCapsule.direction == .back, "state changes must route the new tab's gestures")
    latest.view.removeFromSuperview()
    HostedSwipeCapsule.send("small", "b", ["op": "confirm", "confirmed": true])
    expect(!latestCapsule.confirmed, "detached views must not receive messages while waiting for unmount cleanup")
    latest.onUnmount?()
    other.onUnmount?()
    expect(HostedSwipeCapsule.describe("small") == nil && HostedSwipeCapsule.describe("other") == nil, "unmount must release all routing entries")
    if failures.isEmpty { print("PASS swipe host routing, mapping, replacement and dismissal") }
    else { failures.forEach { print("FAIL \($0)") }; exit(1) }
  }
}
