import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct NewTabsLaunchOverrideTests {
  @Test(arguments: [PersistenceScope.everything, .settingsAndDownloads])
  func overridesExistingChoicesOnceAndKeepsALaterBottomChoice(scope: PersistenceScope) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try Launcher.open(folder, appVersion: "0.4.1", now: now, context: context(), scope: scope)
    let browserStore = store(for: launch)
    let writer = PersistenceWriter(store: browserStore, database: launch.database, folder: folder, persisted: launch.persisted, scope: scope)
    defer { writer.freeze() }
    try browserStore.dispatch(Command("updateSettings", [["newTabPosition": "bottom", "newTabButtonPosition": "top"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try NewTabsLaunchOverride.apply(store: browserStore, writer: writer, folder: folder.url, safeMode: false))
    #expect(browserStore.state.settings["newTabPosition"] == "top")
    #expect(browserStore.state.settings["newTabButtonPosition"] == "top")
    #expect(browserStore.state.settings.chosen?.contains("newTabPosition") == true)
    #expect(browserStore.state.settings.chosen?.contains("newTabButtonPosition") == true)
    #expect(try launch.database.load().settings?["newTabPosition"] == "top")
    #expect(try launch.database.load().settings?["newTabButtonPosition"] == "top")
    try browserStore.dispatch(Command("updateSettings", [["newTabPosition": "bottom", "newTabButtonPosition": "bottom"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    writer.freeze()
    let reopened = try Launcher.open(folder, appVersion: "0.4.1", now: now, context: context(), scope: scope)
    let restored = store(for: reopened)
    let nextWriter = PersistenceWriter(store: restored, database: reopened.database, folder: folder, persisted: reopened.persisted, scope: scope)
    defer { nextWriter.freeze() }
    let revision = restored.rev
    #expect(try !NewTabsLaunchOverride.apply(store: restored, writer: nextWriter, folder: folder.url, safeMode: false))
    #expect(restored.rev == revision)
    #expect(restored.state.settings["newTabPosition"] == "bottom")
    #expect(restored.state.settings["newTabButtonPosition"] == "bottom")
  }

  @Test func safeModeAndMissingWriterLeaveTheOverridePending() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let browserStore = store(for: launch)
    let writer = PersistenceWriter(store: browserStore, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    try browserStore.dispatch(Command("updateSettings", [["newTabPosition": "bottom", "newTabButtonPosition": "bottom"]]))
    #expect(try !NewTabsLaunchOverride.apply(store: browserStore, writer: writer, folder: folder.url, safeMode: true))
    #expect(try !NewTabsLaunchOverride.apply(store: browserStore, writer: nil, folder: folder.url, safeMode: false))
    #expect(browserStore.state.settings["newTabPosition"] == "bottom")
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: NewTabsLaunchOverride.markerName).path))
    #expect(try NewTabsLaunchOverride.apply(store: browserStore, writer: writer, folder: folder.url, safeMode: false))
  }

  @Test func aFailedFlushNeverRecordsTheMarker() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let browserStore = Store()
    #expect(throws: NewTabsLaunchOverride.Failure.self) {
      try NewTabsLaunchOverride.apply(store: browserStore, folder: folder.url, flush: { .failed("injected") })
    }
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: NewTabsLaunchOverride.markerName).path))
  }

  @Test func aMarkerWriteFailurePropagatesInsteadOfExposingAnUnrecordedOverride() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let browserStore = Store()
    #expect(throws: CocoaError.self) {
      try NewTabsLaunchOverride.apply(store: browserStore, folder: folder.url, flush: { .saved }, writeMarker: { _ in
        throw CocoaError(.fileWriteNoPermission)
      })
    }
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: NewTabsLaunchOverride.markerName).path))
  }
}
