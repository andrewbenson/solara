import Foundation
import SolaraModel
import Testing

@testable import SolaraStore

@Suite(.serialized) struct ImportTargetsTests {
  private func store() -> Store {
    Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "imports")), checksInvariants: true, clock: { 1_000 })
  }

  private func work(_ s: Store) throws -> String {
    try s.dispatch(SettingsWrites.createProfile(name: "Work", color: "blue", shareWith: nil)).result!.string!
  }

  @Test func targetsFollowProfileOrder() throws {
    let s = store()
    let work = try work(s)
    #expect(ImportTargets.list(s.state).map(\.id) == s.state.profileOrder)
    try s.dispatch(SettingsWrites.reorderProfiles([work, Settings.defaultProfileID]))
    #expect(ImportTargets.list(s.state).map(\.id) == [work, Settings.defaultProfileID])
    #expect(ImportTargets.list(s.state).first?.name == "Work")
  }

  @Test func defaultTargetIsTheFocusedRegularWindowsProfile() throws {
    let s = store()
    let work = try work(s)
    #expect(ImportTargets.defaultTarget(s.state) == Settings.defaultProfileID)
    let window = try s.dispatch(Command("createWindow", [["profileId": .string(work)]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(window)]))
    #expect(ImportTargets.defaultTarget(s.state) == work)
  }

  @Test func defaultTargetSkipsAFocusedPrivateWindow() throws {
    let s = store()
    let work = try work(s)
    let secret = try s.dispatch(Command("createWindow", [["profileId": .string(work), "incognito": true]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(secret)]))
    #expect(s.state.ui.focusedWindowId == secret)
    #expect(ImportTargets.defaultTarget(s.state) == Settings.defaultProfileID)
    try s.dispatch(Command("setDefaultProfile", [.string(work)]))
    #expect(ImportTargets.defaultTarget(s.state) == work)
  }

  @Test func focusingSettingsOrImportKeepsTheLastBrowserWindow() throws {
    let s = store()
    let work = try work(s)
    let window = try s.dispatch(Command("createWindow", [["profileId": .string(work)]])).result!.string!
    try s.dispatch(Command("setFocusedWindow", [.string(window)]))
    for utility in ["settings", "import"] {
      try s.dispatch(Command("setFocusedWindow", [.string(utility)]))
      #expect(s.state.ui.focusedWindowId == window)
      #expect(ImportTargets.defaultTarget(s.state) == work)
    }
  }

  @Test func feedSendsRenamesAndReordersButNotUnrelatedCommits() throws {
    let s = store()
    let work = try work(s)
    let feed = ImportTargetsFeed(s.state)
    let window = try s.dispatch(Command("createWindow", [["profileId": .string(work)]]))
    #expect(feed.next(window.state) == nil)
    let renamed = try s.dispatch(SettingsWrites.updateProfile(work, JSONObject([("name", .string("Office"))])))
    #expect(feed.next(renamed.state)?.first { $0.id == work }?.name == "Office")
    #expect(feed.next(renamed.state) == nil)
    let reordered = try s.dispatch(SettingsWrites.reorderProfiles([work, Settings.defaultProfileID]))
    #expect(feed.next(reordered.state)?.map(\.id) == [work, Settings.defaultProfileID])
  }

  @Test func preferredSourceIsTakenOnce() async {
    let source = ImportPreferredSource()
    #expect(source.take() == nil)
    await Task.detached { source.set("chrome") }.value
    #expect(source.take() == "chrome")
    #expect(source.take() == nil)
    source.set("arc")
    source.set(nil)
    #expect(source.take() == nil)
  }
}
