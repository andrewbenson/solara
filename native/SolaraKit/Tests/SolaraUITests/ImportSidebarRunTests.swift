import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ImportSidebarRunTests {
  static func space(_ name: String = "First", theme: String? = nil) -> ImportSpaceRow {
    ImportSpaceRow(id: name, name: name, color: "#00FF00", emoji: "🌱", icon: "ignored", profileId: "Default", pinned: [
      ImportBookmarkNode(isFolder: false, title: "Renamed", url: "https://a.test/", dateAdded: nil, role: nil, pageTitle: "Page", children: nil),
      FakeImportEngine.folder("Outer", [FakeImportEngine.folder("Inner", [FakeImportEngine.link("Nested", "https://nested.test/")]),
        FakeImportEngine.folder("Live", [], role: "liveGitHubPullRequests")]),
      FakeImportEngine.folder("Again", [], role: "liveGitHubPullRequests")
    ], tabs: [ImportTabRow(url: "https://t.test/", title: "Open", pinned: true, customTitle: "Custom")], theme: theme)
  }

  func setup() -> (ImportRuns, FakeImportEngine, ImportRunner, ImportRunControl) {
    let runs = ImportRuns()
    let engine = FakeImportEngine()
    let runner = ImportRunner(runs: runs, engine: engine, session: runs.open())
    return (runs, engine, runner, ImportRunControl(engine: engine))
  }

  @Test func payloadPreservesRowsDraftsTruthinessAndOpenOrder() {
    let windows = ImportSidebarPlacement.windows(Self.space())
    #expect(windows.count == 2)
    let row = windows[0]["tabs"]?.array?[0]
    #expect(row?.object?.count == 5)
    #expect(row?["url"] == "https://a.test/")
    #expect(row?["title"] == "Page")
    #expect(row?["pinned"] == true)
    #expect(row?["row"] == true)
    #expect(row?["customTitle"] == "Renamed")
    #expect(windows[1]["tabs"]?.array?[0]["pinned"] == false)
    #expect(windows[1]["group"] == "Imported")
    #expect(windows[1]["drafts"]?.array?.count == 1)
    #expect(windows[1]["drafts"]?.array?[0]["children"]?.array?.count == 1)
    #expect(windows.allSatisfy { $0["skipExistingOpen"] == nil })
    let emptyTitle = ImportBookmarkNode(isFolder: false, title: "Label", url: "https://empty.test", dateAdded: nil, role: nil, pageTitle: "", children: nil)
    #expect(ImportSidebarPlacement.link(emptyTitle)["title"] == "")
    #expect(ImportSidebarPlacement.link(emptyTitle)["customTitle"] == nil)
  }

  @Test func missingPrivateAndSafeDestinationsHaveNoEffects() async {
    for target in ["missing", "incognito:private", "default"] {
      let (_, engine, runner, control) = setup()
      engine.profileList.append(ImportTarget(id: "incognito:private", name: "Private"))
      engine.safeMode = target == "default"
      let result = await runner.placeSidebarSpace(Self.space(), profile: target, favicons: FakeImportEngine.icons, control: control)
      #expect(result == nil)
      #expect(engine.faviconAdoptions.isEmpty)
      #expect(engine.faviconStores.isEmpty)
      #expect(engine.liveImports.isEmpty)
      #expect(engine.workspaces.isEmpty)
    }
  }

  @Test func deletionDuringAdoptionPreventsEveryLaterEffect() async {
    let (runs, engine, runner, control) = setup()
    engine.onFaviconAdopt = { engine.missingProfiles.insert("default") }
    let result = await runner.placeSidebarSpace(Self.space(), profile: "default", favicons: FakeImportEngine.icons, control: control)
    #expect(result == nil)
    #expect(engine.faviconAdoptions.count == 1)
    #expect(engine.faviconStores.isEmpty)
    #expect(engine.liveImports.isEmpty)
    #expect(engine.workspaces.isEmpty)
    #expect(runs.pendingWrites == 0)
  }

  @Test func liveAndFaviconWritesRemainVisibleToDrain() async {
    let (runs, engine, runner, control) = setup()
    var release: CheckedContinuation<Void, Never>?
    engine.onLive = { await withCheckedContinuation { release = $0 } }
    let result = await runner.placeSidebarSpace(Self.space(), profile: "default", favicons: FakeImportEngine.icons, control: control)
    #expect(result == ImportWorkspaceWritten(tabs: 2, skipped: 0))
    for _ in 0..<100 where release == nil { await Task.yield() }
    #expect(engine.liveImports.map { $0.1 } == ["github"])
    #expect(runs.pendingWrites > 0)
    let drain = Task { await runs.drain(engine: engine) }
    await Task.yield()
    #expect(runs.pendingWrites > 0)
    release?.resume()
    await drain.value
    #expect(runs.pendingWrites == 0)
  }

  @Test func cancellationAfterAdoptionPreventsPersistenceLiveAndWorkspace() async {
    let (_, engine, runner, control) = setup()
    engine.onFaviconAdopt = { control.stop() }
    #expect(await runner.placeSidebarSpace(Self.space(), profile: "default", favicons: FakeImportEngine.icons, control: control) == nil)
    #expect(engine.faviconStores.isEmpty)
    #expect(engine.liveImports.isEmpty)
    #expect(engine.workspaces.isEmpty)
  }

  @Test func destinationAdmissionRechecksClashAfterPromptAndCreation() async {
    let (_, engine, runner, _) = setup()
    #expect(await runner.destination("missing", 0, "First", nil, transient: true, stopped: { false }) == .unavailable)
    engine.askAnswer = false
    engine.beforeAnswer = { engine.missingProfiles.insert("work") }
    #expect(await runner.destination("default", 1, "Work", nil, transient: true, stopped: { false }) == .unavailable)
    engine.missingProfiles.insert("new-Created")
    #expect(await runner.destination("default", 1, "Created", nil, transient: true, stopped: { false }) == .unavailable)
  }
  @Test func productionFaviconPersistenceRevalidatesDeletionAndRemappingDuringLoad() async {
    for replacement in [Optional<String>.none, "other-engine"] {
      var binding: String? = "engine-default"
      var loads = 0
      var stores = 0
      await ImportFaviconWrites.persist(profile: "default", engineProfile: "engine-default", favicons: FakeImportEngine.icons, binding: { binding }, load: { _ in
        loads += 1
        await Task.yield()
        binding = replacement
        return true
      }, store: { _, _, _ in stores += 1 })
      #expect(loads == 1)
      #expect(stores == 0)
    }
  }

  @Test func productionFaviconPersistenceRefusesMissingBeforeLoading() async {
    var loads = 0
    var stores = 0
    await ImportFaviconWrites.persist(profile: "missing", engineProfile: "engine-missing", favicons: FakeImportEngine.icons, binding: { nil }, load: { _ in loads += 1; return true }, store: { _, _, _ in stores += 1 })
    #expect(loads == 0)
    #expect(stores == 0)
  }

  func request(target: String = "default", profiles: [String] = ["Default"], kinds: [ImportKind] = [.tabs]) -> ImportRunRequest {
    ImportRunRequest(runId: "sidebar", browserId: "arc", profileIds: profiles, spaceIds: ["First", "Second", "Third"], kinds: kinds, target: target, withoutKey: false)
  }

  func source() -> ImportBrowser {
    ImportBrowser(id: "arc", name: "Arc", family: .arc, profiles: [
      ImportSourceProfile(id: "Default", name: "Default", isDefault: true, available: [.tabs, .spaces, .pinnedTabs]),
      ImportSourceProfile(id: "Profile 1", name: "Other", isDefault: false, available: [.tabs, .spaces, .pinnedTabs])
    ], sidebar: .arc)
  }

  @Test func loopSharesWithinEachSourceAndAppliesCommonDataOnce() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    let favorite = ImportTabRow(url: "https://favorite.test/", title: "Favorite", pinned: true, customTitle: nil)
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: [], bookmarks: FakeImportEngine.tree, favorites: [favorite], spaces: [Self.space(), Self.space("Second")]))
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(credentials: [], bookmarks: FakeImportEngine.tree, spaces: [Self.space("Third")]))
    let result = await runner.run(request(profiles: ["Profile 1", "Default"], kinds: [.bookmarks, .tabs, .favorites]))
    #expect(result.failures.isEmpty)
    #expect(result.status == [.bookmarks: .done, .tabs: .done, .spaces: .done, .pinnedTabs: .done, .favorites: .done])
    #expect(engine.workspaces.map { $0.0 } == ["default", "new-Second", "default", "new-Third"])
    #expect(engine.created.map { $0.0 } == ["Second", "Third"])
    #expect(engine.createdOptions.map { $0.1 } == ["default", nil])
    #expect(engine.createdOptions.map { $0.0 } == ["🌱", "🌱"])
    #expect(engine.bookmarkSubmits.count == 2)
    #expect(engine.workspaces[2].1.first?["pinnedAgainst"] == "tiles")
    #expect(result.extensionsProfile == "default")
  }

  @Test func refusalHasExactFailedKindsAndNoteWithoutCommonWrites() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    engine.workspaceResult = nil
    engine.reads["Default"] = .success(FakeImportEngine.read(spaces: [Self.space("Refused")]))
    let result = await runner.run(request())
    #expect(result.counts.tabs == 0)
    #expect(result.status == [.tabs: .failed, .spaces: .failed, .pinnedTabs: .failed])
    #expect(result.failures.map(\.kind) == [.tabs, .spaces, .pinnedTabs])
    #expect(result.failures.allSatisfy { $0.profiles.isEmpty })
    #expect(result.notes == ["Nothing from Refused was imported, because Solara couldn't save its workspace."])
    #expect(engine.bookmarkSubmits.isEmpty)
    #expect(engine.saved.isEmpty)
    #expect(engine.discarded == ["vault-1"])
  }

  @Test func lostDestinationFailsSourceAndContinuesNextSource() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    engine.missingProfiles.insert("default")
    for profile in ["Default", "Profile 1"] {
      engine.reads[profile] = .success(FakeImportEngine.read(credentials: [], spaces: [Self.space(profile)], favicons: FakeImportEngine.icons))
    }
    let result = await runner.run(request(profiles: ["Default", "Profile 1"]))
    #expect(result.notes == [ImportRunner.noDestinationNote("Default")])
    #expect(engine.workspaces.map { $0.0 } == ["new-Profile 1"])
    #expect(result.failures.allSatisfy { $0.profiles == ["Default"] })
  }

  @Test func unavailablePromptKeepsEarlierCountsAndStopsRemainingSpaceEffects() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    engine.askAnswer = nil
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: [], spaces: [Self.space(), Self.space("Work"), Self.space("Third")]))
    let result = await runner.run(request())
    #expect(result.counts.tabs == 2)
    #expect(result.notes == [ImportRunner.noDestinationNote("Work")])
    #expect(engine.workspaces.count == 1)
    #expect(engine.created.isEmpty)
    #expect(result.status.values.allSatisfy { $0 == .failed })
  }

  @Test func safeModeCommonImportDoesNotAdoptOrPersistFavicons() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    engine.safeMode = true
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: [], bookmarks: FakeImportEngine.tree, favicons: FakeImportEngine.icons))
    let result = await runner.run(request(kinds: [.bookmarks]))
    #expect(result.counts.bookmarks == 4)
    #expect(engine.faviconAdoptions.isEmpty)
    #expect(engine.faviconStores.isEmpty)
    #expect(engine.workspaces.isEmpty)
  }

  @Test func stoppedAdoptionPreventsEveryLaterDestinationInTheFullRun() async {
    let (runs, engine, runner, _) = setup()
    runs.browsers = [source()]
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: [], spaces: [Self.space(), Self.space("Second")], favicons: FakeImportEngine.icons))
    engine.onFaviconAdopt = { runs.current?.stop() }
    let result = await runner.run(request())
    #expect(result.counts.tabs == 0)
    #expect(result.notes == [ImportRunner.stoppedNote])
    #expect(engine.faviconAdoptions.count == 1)
    #expect(engine.faviconStores.isEmpty)
    #expect(engine.liveImports.isEmpty)
    #expect(engine.workspaces.isEmpty)
    #expect(engine.created.isEmpty)
  }

}
