import Foundation
import Testing
@testable import SolaraUI

@Suite struct PanePromptSpecsTests {
  private func take(_ page: inout PanePromptPage, _ name: String, _ payload: [String: Any]) -> Bool { page.take(name, payload) }
  private let save: [String: Any] = ["state": "save", "origin": "https://www.example.com", "username": "ada", "passwordLength": 20, "federation": "", "usernames": ["ada"]]

  @Test func savedPromptsAreNotShown() {
    #expect(PanePasswordPrompt(["state": "saved", "origin": "https://a.test"]) == nil)
    #expect(PanePasswordPrompt(save)?.update == false)
  }

  @Test func aNewPageDropsThePrompt() {
    var page = PanePromptPage()
    _ = take(&page, "onNavigationChange", ["url": "https://www.example.com/login"])
    #expect(take(&page, "onPasswordPrompt", save))
    #expect(!take(&page, "onNavigationChange", ["url": "https://www.example.com/login#done"]))
    #expect(page.password != nil)
    #expect(take(&page, "onNavigationChange", ["url": "https://www.example.com/home"]))
    #expect(page.password == nil)
  }

  @Test func saveSpecMatchesRN() {
    let spec = PanePromptSpecs.password(PanePasswordPrompt(save)!, chosen: nil)
    #expect(spec["title"] as? String == "Save password for example.com?")
    #expect(spec["message"] as? String == "That way, it'll be auto-filled next time")
    #expect((spec["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["never", "dismiss", "save"])
    let lines = (((spec["details"] as? [[String: Any]])?.first?["sections"] as? [[String: Any]])?.first?["lines"] as? [[String: Any]]) ?? []
    #expect(lines.map { $0["text"] as? String } == ["ada", String(repeating: "•", count: 16)])
    #expect((spec["popover"] as? [String: Any])?["width"] as? Int == 350)
  }

  @Test func updateWithSeveralNamesOffersChoices() {
    var payload = save
    payload["state"] = "update"
    payload["usernames"] = ["ada", "grace"]
    let spec = PanePromptSpecs.password(PanePasswordPrompt(payload)!, chosen: "grace")
    let detail = (spec["details"] as? [[String: Any]])?.first
    #expect(detail?["kind"] as? String == "choices")
    #expect((detail?["choices"] as? [[String: Any]])?.filter { $0["selected"] as? Bool == true }.compactMap { $0["id"] as? String } == ["grace"])
    #expect((spec["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["nope", "update"])
    #expect(spec["title"] as? String == "Update saved password?")
  }

  private func allow(_ input: inout PromptInputGuard, _ now: TimeInterval, _ activatedAt: TimeInterval) -> Bool { input.allow(at: now, activatedAt: activatedAt) }

  @Test func guardWaitsForTheOpenAndForDoubleInput() {
    var input = PromptInputGuard()
    #expect(!allow(&input, 10, 0))
    input.shown(at: 10)
    #expect(!allow(&input, 10.4, 0))
    #expect(allow(&input, 11, 0))
    #expect(!allow(&input, 11.2, 0))
    #expect(!allow(&input, 12, 11.8))
  }
}

@Suite struct PaneMorePromptsTests {
  private func take(_ page: inout PanePromptPage, _ name: String, _ payload: [String: Any]) -> Bool { page.take(name, payload) }
  private let address: [String: Any] = ["id": 4, "kind": "saveAddress", "origin": "https://a.test", "title": "Save address?", "message": "", "accept": "Save", "decline": "No thanks", "footer": "", "lines": ["Jane Doe", "1 Meadow Lane"]]

  @Test func autofillClosesOnlyForItsOwnId() {
    var page = PanePromptPage()
    #expect(take(&page, "onAutofillPrompt", address))
    #expect(!take(&page, "onAutofillPrompt", ["id": 3, "closed": true]))
    #expect(take(&page, "onAutofillPrompt", ["id": 4, "closed": true]))
    #expect(page.autofill == nil)
  }

  @Test func autofillSpecs() {
    let save = PanePromptSpecs.autofill(PaneAutofillPrompt(address)!)
    #expect(save["message"] is NSNull)
    #expect((save["icons"] as? [String]) == ["mappin.and.ellipse"])
    #expect((save["buttons"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["No thanks", "Save"])
    var update = address
    update["kind"] = "updateAddress"
    update["newLabel"] = "New"
    update["oldLabel"] = "Old"
    update["changes"] = [["field": "email", "from": "", "to": "a@b.c"], ["field": "name", "from": "J", "to": "Jane"]]
    let sections = ((PanePromptSpecs.autofill(PaneAutofillPrompt(update)!)["details"] as? [[String: Any]])?.first?["sections"] as? [[String: Any]]) ?? []
    #expect(sections.map { $0["label"] as? String } == ["New", "Old"])
    #expect(((sections.last?["lines"] as? [[String: Any]]) ?? []).map { $0["text"] as? String } == ["J"])
  }

  @Test func externalAppFollowsDocumentCommits() {
    var page = PanePromptPage()
    _ = take(&page, "onNavigationChange", ["url": "https://a.test/one"])
    #expect(take(&page, "onExternalApp", ["id": "x1", "title": "Open Zoom?", "app": "Zoom", "remember": "Always allow"]))
    page.alwaysOpen = true
    _ = take(&page, "onNavigationChange", ["url": "https://a.test/two"])
    #expect(page.externalApp != nil)
    _ = take(&page, "onNavigationChange", ["url": "https://b.test/"])
    #expect(page.externalApp != nil)
    _ = page.take("onDocumentCommitted", [:])
    #expect(page.externalApp == nil)
    #expect(!page.alwaysOpen)
  }

  @Test func externalAppSpecs() {
    let open = PanePromptSpecs.externalApp(PaneExternalApp(["id": "x", "title": "Open Zoom?", "app": "Zoom", "remember": "Always"])!, always: true, left: 120)
    #expect((open["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["cancel", "open"])
    #expect(((open["details"] as? [[String: Any]])?.first?["value"] as? Bool) == true)
    #expect((open["popover"] as? [String: Any])?["left"] as? Double == 120)
    let unknown = PanePromptSpecs.externalApp(PaneExternalApp(["id": "y", "title": "No app"])!, always: false, left: 8)
    #expect((unknown["icons"] as? [String]) == ["questionmark.app.dashed"])
    #expect((unknown["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["ok"])
    #expect(PanePromptSpecs.externalAppLeft(urlLeft: 600, paneWidth: 700) == 352)
    #expect(PanePromptSpecs.externalAppLeft(urlLeft: 0, paneWidth: 700) == 8)
  }

  @Test func popupsSpecs() {
    let list = (1...7).map { ["id": "p\($0)", "url": "https://www.ads.test/\($0)", "origin": "https://www.ads.test"] }
    let found = PanePromptSpecs.popups(["side": "left", "list": list])!
    #expect(found.key == "https://www.ads.test\u{1}p1")
    #expect(found.spec["title"] as? String == "Always allow pop-ups from ads.test?")
    #expect((found.spec["rows"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["p3", "p4", "p5", "p6", "p7"])
    #expect((found.spec["rows"] as? [[String: Any]])?.first?["title"] as? String == "www.ads.test/3")
    #expect(found.spec["rowsMore"] as? String == "and 2 more")
    let popover = found.spec["popover"] as? [String: Any]
    #expect(popover?["left"] as? Double == 8 && popover?["right"] == nil && popover?["width"] as? Double == 360)
    #expect(PanePromptSpecs.popups(["side": "right", "list": []]) == nil)
    let blank = PanePromptSpecs.popups(["list": [["id": "a", "url": "", "origin": "https://b.test"]]])!
    #expect((blank.spec["popover"] as? [String: Any])?["right"] as? Double == 8)
    #expect((blank.spec["rows"] as? [[String: Any]])?.first?["title"] as? String == "about:blank")
    #expect(blank.spec["rowsMore"] is NSNull)
    let look: [String: Any] = ["dark": false, "theme": [String: String](), "control": "", "controlBorder": "", "goButton": "", "goButtonText": ""]
    let json = try! JSONSerialization.data(withJSONObject: found.spec.merging(look) { a, _ in a })
    #expect(PromptState.decode(String(data: json, encoding: .utf8)!)?.rows?.count == 5)
  }
}

