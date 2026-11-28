import Testing
import SolaraUI

@Suite struct PromptLifetimeTests {
  @Test func sameURLDocumentCommitClearsPermissionsAndPopups() {
    var page = PanePromptPage()
    _ = page.take("onNavigationChange", ["url": "https://example.test/"])
    _ = page.take("onPopupBlocked", ["id": "popup", "origin": "https://example.test", "url": "https://example.test/popup"])
    #expect(page.popups.count == 1)
    _ = page.take("onPasswordPrompt", ["state": "save", "origin": "https://example.test/"])
    _ = page.take("onAutofillPrompt", ["id": 7, "kind": "saveCard"])
    _ = page.take("onExternalApp", ["id": "external", "title": "Open app?"])
    page.enqueue(PanePermissionRequest(["id": "permission", "browserId": 1])!)
    let committed = page.take("onDocumentCommitted", [:])
    #expect(committed)
    #expect(page.popups.isEmpty)
    #expect(page.password?.origin == "https://example.test/")
    #expect(page.autofill?.id == 7)
    #expect(page.externalApp == nil)
    #expect(page.permission == nil)
  }

  @Test func lateExternalAppEventsCannotReplaceOrReopenAnOffer() {
    var page = PanePromptPage()
    let first = ["id": "first", "title": "Open app?"]
    let second = ["id": "second", "title": "Open another app?"]
    _ = page.take("onExternalApp", first)
    page.alwaysOpen = true
    _ = page.take("onExternalApp", second)
    #expect(!page.alwaysOpen)
    _ = page.take("onExternalApp", ["id": "first", "closed": true])
    _ = page.take("onExternalApp", first)
    #expect(page.externalApp?.id == "second")
    page.clearExternalApp()
    _ = page.take("onExternalApp", second)
    #expect(page.externalApp == nil)
  }

  @Test func aRepeatedPermissionReceiptIsOnlyQueuedOnce() {
    var page = PanePromptPage()
    let request = PanePermissionRequest(["id": "permission", "browserId": 1])!
    page.enqueue(request)
    page.enqueue(request)
    #expect(page.permissions == [request])
    _ = page.dropPermission(request.id)
    #expect(page.permission == nil)
  }
}

@Suite struct DeviceChooserLifetimeTests {
  private func chooser(_ id: Int, open: Bool = true) -> PaneDeviceChooser {
    PaneDeviceChooser(["id": id, "browserId": 2, "open": open])!
  }

  @Test func documentCommitRetiresChooserAndIgnoresItsLateUpdates() {
    var page = PanePromptPage()
    _ = page.chooserEvent(chooser(1))
    _ = page.take("onDocumentCommitted", [:])
    #expect(page.chooser == nil)
    _ = page.chooserEvent(chooser(1))
    #expect(page.chooser == nil)
  }

  @Test func retiredChooserCannotDisplaceItsReplacement() {
    var page = PanePromptPage()
    _ = page.chooserEvent(chooser(1))
    _ = page.chooserEvent(chooser(2))
    _ = page.chooserEvent(chooser(1, open: false))
    _ = page.chooserEvent(chooser(1))
    #expect(page.chooser?.id == 2)
  }

  @Test func refreshedChooserRejectsTheOldOptionAndClearsItsSelection() {
    var page = PanePromptPage()
    func update(_ option: Int) {
      _ = page.chooserEvent(PaneDeviceChooser(["id": 1, "browserId": 2, "open": true,
        "options": [["optionId": option, "name": "Device"]]])!)
    }
    update(3)
    page.chooserSelected = 3
    update(7)
    #expect(page.chooserSelected == nil)
    #expect(page.chooser?.choice(3, selected: nil) == nil)
    #expect(page.chooser?.choice(7, selected: nil) == 7)
  }

  @Test func chooserOptionsRequireStableIds() {
    let chooser = PaneDeviceChooser(["id": 1, "browserId": 2, "open": true,
      "options": [["name": "missing identity"], ["optionId": 7, "name": "current"]]])
    #expect(chooser?.options.map(\.id) == [7])
  }
}
