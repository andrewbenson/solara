import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct ImportDiaRunTests {
  func setup() -> (ImportRuns, FakeImportEngine, Int) {
    let runs = ImportRuns()
    runs.writeDeadline = .seconds(300)
    runs.drainDeadline = .seconds(300)
    let session = runs.open()
    return (runs, FakeImportEngine(), session)
  }

  static func tab(_ url: String, pinned: Bool = false) -> ImportTabRow { ImportTabRow(url: url, title: url, pinned: pinned, customTitle: nil) }

  static let read = ImportDiaRead(
    profiles: [
      ImportDiaProfile(id: "0:Personal", name: "Personal", pinned: [tab("https://p1.test/", pinned: true)], tabs: [tab("https://o1.test/"), tab("https://o2.test/")]),
      ImportDiaProfile(id: "1:Work", name: "Work", pinned: [], tabs: [tab("https://w1.test/")]),
    ],
    windowCount: 2,
    favicons: [ImportFaviconRow(page: "https://p1.test/#top", icon: "https://p1.test/i.png", png: "AA=="), ImportFaviconRow(page: "https://elsewhere.test/", icon: "x", png: "BB==")]
  )

  func run(_ runs: ImportRuns, _ engine: FakeImportEngine, _ session: Int, ids: [String], pinned: Bool, open: Bool, target: String = "default") async -> ImportRunOutcome {
    await runs.importDia(profileIds: ids, target: target, pinned: pinned, open: open, session: session, engine: engine)
  }

  @Test func pinnedAndOpenTabsGoToOneWorkspaceImportLikeJS() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    let outcome = await run(runs, engine, session, ids: ["0:Personal"], pinned: true, open: true)
    #expect(outcome.status == [.tabs: .done, .pinnedTabs: .done])
    #expect(outcome.failures.isEmpty)
    #expect(outcome.counts.tabs == 2)
    #expect(engine.workspaces.count == 1)
    let windows = engine.workspaces.first?.1 ?? []
    #expect(engine.workspaces.first?.0 == "default")
    #expect(windows.count == 2)
    #expect(windows[0]["group"] == nil)
    #expect(windows[0]["skipExistingOpen"]?.bool == true)
    #expect(windows[0]["tabs"]?.array?.map { $0["pinned"]?.bool } == [true])
    #expect(windows[1]["group"]?.string == "Imported")
    #expect(windows[1]["skipExistingOpen"]?.bool == true)
    #expect(windows[1]["tabs"]?.array?.compactMap { $0["url"]?.string } == ["https://o1.test/", "https://o2.test/"])
    #expect(windows[1]["tabs"]?.array?.allSatisfy { $0["pinned"]?.bool == false } == true)
    #expect(engine.faviconAdoptions.map(\.0) == ["default"])
    #expect(engine.faviconAdoptions.first?.1.map(\.icon) == ["https://p1.test/i.png"])
  }

  @Test func onlyTheAskedKindIsImported() async {
    for (pinned, open, groups) in [(true, false, [String?.none]), (false, true, ["Imported"])] {
      let (runs, engine, session) = setup()
      runs.dia = Self.read
      let outcome = await run(runs, engine, session, ids: ["0:Personal"], pinned: pinned, open: open)
      #expect(Set(outcome.status.keys) == Set((pinned ? [ImportKind.pinnedTabs] : []) + (open ? [.tabs] : [])))
      #expect(engine.workspaces.first?.1.map { $0["group"]?.string } == groups)
    }
  }

  @Test func aSecondProfileGetsItsOwnDestination() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    engine.askAnswer = true
    let outcome = await run(runs, engine, session, ids: ["0:Personal", "1:Work"], pinned: true, open: true)
    #expect(outcome.counts.tabs == 4)
    #expect(engine.calls.contains("ask"))
    #expect(engine.created.map(\.0) == ["Work"])
    #expect(engine.created.map(\.1) == [nil])
    #expect(engine.workspaces.map(\.0) == ["default", "new-Work"])
  }

  @Test func replacingAClashingProfileImportsIntoIt() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    engine.askAnswer = false
    _ = await run(runs, engine, session, ids: ["0:Personal", "1:Work"], pinned: false, open: true)
    #expect(engine.created.isEmpty)
    #expect(engine.workspaces.map(\.0) == ["default", "work"])
  }

  @Test func safeModeFailsEveryKindWithTheJSNote() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    engine.safeMode = true
    let outcome = await run(runs, engine, session, ids: ["0:Personal", "1:Work"], pinned: true, open: true)
    #expect(engine.calls.contains("refused"))
    #expect(engine.workspaces.isEmpty)
    #expect(outcome.status == [.tabs: .failed, .pinnedTabs: .failed])
    #expect(outcome.failures.map(\.profiles) == [["Personal", "Work"], ["Personal", "Work"]])
    #expect(outcome.notes == ["Tab import is unavailable in safe mode."])
  }

  @Test func withoutARead() async {
    let (runs, engine, session) = setup()
    let outcome = await run(runs, engine, session, ids: ["0:Personal"], pinned: true, open: true)
    #expect(outcome.notes == ["Read Dia's tabs again before importing."])
    #expect(outcome.status == [.tabs: .failed, .pinnedTabs: .failed])
    #expect(engine.workspaces.isEmpty)
  }

  @Test func aFailedWorkspaceWriteFailsTheRemainingProfiles() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    engine.workspaceResult = nil
    let outcome = await run(runs, engine, session, ids: ["0:Personal", "1:Work"], pinned: false, open: true)
    #expect(outcome.failures.map(\.profiles) == [["Personal", "Work"]])
    #expect(engine.workspaces.count == 1)
  }

  @Test func aPrivateDestinationSkipsFavicons() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    _ = await run(runs, engine, session, ids: ["0:Personal"], pinned: true, open: false, target: "incognito:1")
    #expect(engine.faviconAdoptions.isEmpty)
    #expect(engine.workspaces.map(\.0) == ["incognito:1"])
  }

  @Test func aDrainedSessionImportsNothing() async {
    let (runs, engine, session) = setup()
    runs.dia = Self.read
    await runs.drain(engine: engine)
    let outcome = await run(runs, engine, session, ids: ["0:Personal"], pinned: true, open: true)
    #expect(outcome == .cancelledRun)
    #expect(engine.workspaces.isEmpty)
  }

  @Test func disposeForgetsTheRead() async {
    let (runs, engine, _) = setup()
    runs.dia = Self.read
    runs.dispose(engine: engine)
    #expect(runs.dia == nil)
  }
}
