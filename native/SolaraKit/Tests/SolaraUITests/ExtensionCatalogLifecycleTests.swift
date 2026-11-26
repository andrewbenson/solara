import Testing
import SolaraModel
@testable import SolaraUI

@MainActor
struct ExtensionCatalogLifecycleTests {
  func row(_ id: String, enabled: Bool = true, incognito: Bool = false, split: Bool = false) -> JSONObject {
    ["id": .string(id), "name": .string(id), "enabled": .bool(enabled), "incognito": .bool(incognito), "incognitoSplit": .bool(split)]
  }

  @Test func initialLoadAndInactiveProfilesStayUnloaded() {
    var catalog = ExtensionCatalogLifecycle()
    #expect(catalog.loadProfiles(["work", "work"]) == ["work"])
    #expect(catalog.loadProfiles(["work"]) == [])
    #expect(catalog.lists["inactive"] == nil)
    #expect(catalog.loadProfiles(["work", "personal"]) == ["personal"])
  }

  @Test func changesDuringReadRequireExactlyOneTrailingRefresh() {
    var catalog = ExtensionCatalogLifecycle()
    let first = catalog.begin("work")!
    #expect(catalog.begin("work", afterChange: true) == nil)
    #expect(catalog.begin("work", afterChange: true) == nil)
    let needsTrailing = catalog.finish("work", request: first, rows: [row("a")])
    #expect(needsTrailing)
    let trailing = catalog.begin("work")!
    let repeats = catalog.finish("work", request: trailing, rows: [row("b")])
    #expect(!repeats)
    #expect(catalog.lists["work"]?.first?["id"] == "b")
  }

  @Test func disabledAndUninstalledRowsDisappearAndPrivateRequiresSplit() {
    var catalog = ExtensionCatalogLifecycle()
    let request = catalog.begin("work")!
    _ = catalog.finish("work", request: request, rows: [row("disabled", enabled: false), row("regular"), row("spanning", incognito: true), row("split", incognito: true, split: true)])
    #expect(catalog.visible("work", privateWindow: false).map { $0["id"] } == ["regular", "spanning", "split"])
    #expect(catalog.visible("work", privateWindow: true).map { $0["id"] } == ["split"])
    _ = catalog.finish("work", request: catalog.begin("work")!, rows: [])
    #expect(catalog.visible("work", privateWindow: false).isEmpty)
  }

  @Test func failedReadPreservesRowsAndOwnershipLossRejectsLateReply() {
    var catalog = ExtensionCatalogLifecycle()
    _ = catalog.finish("work", request: catalog.begin("work")!, rows: [row("a")])
    _ = catalog.finish("work", request: catalog.begin("work")!, rows: nil)
    #expect(catalog.lists["work"]?.count == 1)
    let stale = catalog.begin("work")!
    catalog.invalidate()
    _ = catalog.finish("work", request: stale, rows: [row("stale")])
    #expect(catalog.lists.isEmpty)
  }

  @Test func dirtyEventsWaitForActivationAndCoalesceAt150Milliseconds() {
    var catalog = ExtensionCatalogLifecycle()
    _ = catalog.loadProfiles(["work"])
    catalog.changed("inactive", registry: true)
    catalog.changed("work", registry: true)
    catalog.changed("work", registry: false)
    #expect(catalog.flush(active: false) == nil)
    let batch = catalog.flush(active: true)!
    #expect(batch.lists == ["work"])
    #expect(batch.actions == ["work"])
    #expect(catalog.flush(active: true) == nil)
    #expect(ExtensionCatalogLifecycle.coalesceDelay == 0.15)
    #expect(ExtensionCatalogLifecycle.pollInterval == 1.5)
    #expect(ExtensionCatalogLifecycle.forcePolling("on"))
    #expect(!ExtensionCatalogLifecycle.forcePolling("off"))
  }
}
