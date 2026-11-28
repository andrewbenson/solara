import Foundation
import Testing
@testable import SolaraUI

@Suite struct PanePermissionsTests {
  private func request(_ id: String, _ browserId: Int = 7, _ kinds: [String] = ["notifications"], origin: String = "https://a.test") -> PanePermissionRequest {
    PanePermissionRequest(["id": id, "browserId": browserId, "origin": origin, "permissions": kinds])!
  }
  private func take(_ page: inout PanePromptPage, _ name: String, _ payload: [String: Any]) -> Bool { page.take(name, payload) }
  private func drop(_ page: inout PanePromptPage, _ id: String) -> Bool { page.dropPermission(id) }
  private func chooser(_ page: inout PanePromptPage, _ payload: [String: Any]) -> Bool { page.chooserEvent(PaneDeviceChooser(payload)!) }
  private func route(_ browsers: inout PaneBrowsers, _ request: PanePermissionRequest) -> String? { browsers.route(request) }
  private func ready(_ browsers: inout PaneBrowsers, _ tabId: String, _ browserId: Int) -> [String] { browsers.ready(tabId, browserId: browserId).map { "\($0.tabId):\($0.request.id)" } }

  @Test func queueShowsOneAtATimeAndDropsById() {
    var page = PanePromptPage()
    page.enqueue(request("1"))
    page.enqueue(request("2"))
    #expect(page.permission?.id == "1")
    #expect(drop(&page, "2"))
    #expect(page.permission?.id == "1")
    #expect(drop(&page, "1"))
    #expect(page.permission == nil)
    #expect(!drop(&page, "1"))
  }

  @Test func aNewPageClearsTheQueue() {
    var page = PanePromptPage()
    _ = take(&page, "onNavigationChange", ["url": "https://a.test/one"])
    page.enqueue(request("1"))
    page.enqueue(request("2"))
    _ = take(&page, "onNavigationChange", ["url": "https://a.test/one#frag"])
    #expect(page.permissions.count == 2)
    #expect(take(&page, "onNavigationChange", ["url": "https://a.test/two"]))
    #expect(page.permissions.isEmpty)
  }

  @Test func orphansWaitForTheirBrowser() {
    var browsers = PaneBrowsers()
    #expect(route(&browsers, request("1", 9)) == nil)
    #expect(route(&browsers, request("2", 9)) == nil)
    browsers.dismissed("2")
    #expect(ready(&browsers, "a", 9) == ["a:1"])
    #expect(route(&browsers, request("3", 9)) == "a")
    _ = ready(&browsers, "a", 11)
    #expect(browsers.tab(9) == nil && browsers.tab(11) == "a")
    browsers.gone("a")
    #expect(browsers.tab(11) == nil)
  }

  @Test func orphansAreBoundedOldestFirst() {
    var browsers = PaneBrowsers()
    for i in 0..<(PaneBrowsers.orphanLimit + 3) { #expect(route(&browsers, request("\(i)", 9)) == nil) }
    let dropped = browsers.overflow()
    #expect(dropped.map(\.id) == ["0", "1", "2"])
    let none = browsers.overflow()
    #expect(none.isEmpty)
    #expect(ready(&browsers, "a", 9).count == PaneBrowsers.orphanLimit)
  }

  @Test func aChooserIsAnsweredOnce() {
    var page = PanePromptPage()
    let early = page.answerChooser()
    #expect(!early)
    let open: [String: Any] = ["id": 4, "browserId": 9, "open": true, "title": "t", "okLabel": "Pair"]
    _ = chooser(&page, open)
    let first = page.answerChooser()
    let second = page.answerChooser()
    #expect(first && !second)
    _ = chooser(&page, open)
    let afterUpdate = page.answerChooser()
    #expect(!afterUpdate)
    var closed = open
    closed["open"] = false
    _ = chooser(&page, closed)
    _ = chooser(&page, open)
    let reopened = page.answerChooser()
    #expect(!reopened)
  }

  @Test func describesLikeRN() {
    #expect(PanePromptSpecs.describePermission(request("1")).question == "Allow a.test to send you notifications?")
    let av = PanePromptSpecs.describePermission(request("1", 7, ["camera", "microphone", "location"], origin: "http://127.0.0.1:8080"))
    #expect(av.question == "Allow http://127.0.0.1:8080 to access your camera, microphone and location?")
    #expect(av.icons == ["video", "mic", "location"])
    let mixed = PanePromptSpecs.describePermission(request("1", 7, ["camera", "screen"]))
    #expect(mixed.question == "Allow a.test to use camera and screen?")
    #expect(PanePromptSpecs.describePermission(request("1", 7, ["mystery"])).icons == ["questionmark.circle"])
    let spec = PanePromptSpecs.permission(request("1"), left: 20)
    #expect((spec["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["deny", "accept"])
    #expect((spec["popover"] as? [String: Any])?["width"] as? Double == 300)
    #expect(PanePromptSpecs.promptLeft(urlLeft: 600, paneWidth: 700, width: 300) == 392)
    #expect(PanePromptKind.permission.leftWidth == 300 && PanePromptKind.password.leftWidth == nil)
  }

  @Test func chooserKeepsItsSelectionUntilANewChooser() {
    var page = PanePromptPage()
    let base: [String: Any] = ["id": 3, "browserId": 7, "open": true, "title": "Pick", "options": [["optionId": 1, "name": "Mouse", "paired": true, "signal": 2]]]
    #expect(chooser(&page, base))
    page.chooserSelected = 1
    var refreshed = base
    refreshed["refreshing"] = true
    #expect(chooser(&page, refreshed))
    #expect(page.chooserSelected == 1)
    var other = base
    other["id"] = 4
    _ = chooser(&page, other)
    #expect(page.chooserSelected == nil)
    var closedOld = base
    closedOld["open"] = false
    #expect(!chooser(&page, closedOld))
    closedOld["id"] = 4
    #expect(chooser(&page, closedOld))
    #expect(page.chooser == nil)
  }

  @Test func chooserSpecMatchesRN() {
    let c = PaneDeviceChooser(["id": 3, "browserId": 7, "open": true, "title": "Pick", "showSignal": true, "options": [["optionId": 1, "name": "Mouse", "paired": true, "signal": 2], ["optionId": 2, "name": "Pad", "connected": true, "signal": 4]]])!
    let spec = PanePromptSpecs.deviceChooser(c, selected: 2, product: "Solara", left: 8)
    #expect(spec["icon"] as? String == "dot.radiowaves.left.and.right")
    #expect((spec["options"] as? [[String: Any]])?.compactMap { $0["detail"] as? String } == ["Paired", "Connected"])
    #expect(spec["valid"] as? Bool == true && spec["okLabel"] as? String == "Connect")
    #expect(c.choice(nil, selected: 2) == 2)
    let locked = PaneDeviceChooser(["id": 5, "browserId": 7, "open": true, "unauthorized": true])!
    let lockedSpec = PanePromptSpecs.deviceChooser(locked, selected: nil, product: "Solara", left: 8)
    #expect(lockedSpec["notice"] as? String == "Solara needs access to Bluetooth to find devices.")
    #expect(lockedSpec["valid"] as? Bool == false && locked.blocked)
    let look: [String: Any] = ["dark": false, "theme": [String: String](), "goButton": "", "goButtonText": ""]
    let json = try! JSONSerialization.data(withJSONObject: spec.merging(look) { a, _ in a })
    #expect(DeviceChooserState.decode(String(data: json, encoding: .utf8)!)?.selected == 2)
  }

  @Test func selectionComesFromPageMessagesAndGoesWithThePage() {
    var page = PanePromptPage()
    _ = take(&page, "onNavigationChange", ["url": "https://a.test/one"])
    #expect(take(&page, "onPageMessage", ["kind": "selection", "data": ["text": "hello", "rect": ["x": 10, "y": 20.5, "width": 30, "height": 12]]]))
    #expect(page.selection?.text == "hello" && page.selection?.y == 20.5)
    #expect(!take(&page, "onPageMessage", ["kind": "scroll", "data": ["y": 3]]))
    #expect(take(&page, "onNavigationChange", ["url": "https://a.test/two"]))
    #expect(page.selection == nil)
    _ = take(&page, "onPageMessage", ["kind": "selection", "data": ["text": "x", "rect": ["x": 0, "y": 0, "width": 1, "height": 1]]])
    #expect(take(&page, "onPageMessage", ["kind": "selection", "data": NSNull()]))
    #expect(page.selection == nil)
  }

  @Test func selectionBarMatchesRN() {
    let selection = PaneSelection(["text": "a  quick\nbrown fox jumps over the lazy dog and keeps running", "rect": ["x": 10, "y": 20, "width": 30, "height": 12]])!
    let bar = PanePromptSpecs.selectionBar(selection, zoom: 2, engine: "Google", dark: true, icon: "#fff", textPrimary: "#eee")
    #expect(bar.key == "10,20" && bar.top == 40 && bar.bottom == 64 && bar.center == 50)
    #expect(bar.label == "Search Google")
    #expect(bar.tooltip == "Search Google for \u{201C}a quick brown fox jumps over the lazy d\u{2026}\u{201D}")
    #expect(PanePromptSpecs.searchTooltip(engine: "Kagi", text: "short") == "Search Kagi for \u{201C}short\u{201D}")
  }

  @Test func engineOfferMatchesRN() {
    let spec = PanePromptSpecs.engineOffer(host: "tv.test", canRemember: true, remember: true, product: "Solara", left: 30)
    #expect(spec["title"] as? String == "Play tv.test in WebKit?")
    #expect(((spec["details"] as? [[String: Any]])?.first?["value"] as? Bool) == true)
    #expect((spec["popover"] as? [String: Any])?["width"] as? Double == 320)
    #expect((PanePromptSpecs.engineOffer(host: "a", canRemember: false, remember: false, product: "S", left: 8)["details"] as? [Any])?.isEmpty == true)
    #expect(PanePromptKind.engineOffer.leftWidth == 340)
    let look: [String: Any] = ["dark": false, "theme": [String: String](), "control": "", "controlBorder": "", "goButton": "", "goButtonText": ""]
    let json = try! JSONSerialization.data(withJSONObject: spec.merging(look) { a, _ in a })
    #expect(PromptState.decode(String(data: json, encoding: .utf8)!)?.buttons.count == 2)
  }
}

