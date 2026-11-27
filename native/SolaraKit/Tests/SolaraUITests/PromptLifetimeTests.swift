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
    #expect(page.externalApp?.id == "external")
    #expect(page.permission == nil)
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
  @Test func documentCommitLeavesChooserToItsEngineLifecycle() {
    var page = PanePromptPage()
    _ = page.chooserEvent(PaneDeviceChooser(["id": 1, "browserId": 2, "open": true])!)
    _ = page.take("onDocumentCommitted", [:])
    #expect(page.chooser?.id == 1)
    _ = page.chooserEvent(PaneDeviceChooser(["id": 1, "browserId": 2, "open": false])!)
    #expect(page.chooser == nil)
  }
}
