import Foundation
import Testing
@testable import SolaraUI

@MainActor
struct ImportModelTests {
  func started(_ configure: (FakeImportServices) -> Void = { _ in }) async -> (ImportModel, FakeImportServices) {
    let services = FakeImportServices()
    configure(services)
    let model = ImportModel(services: services, appName: "Solara")
    model.doneDelay = .zero
    model.diaPollInterval = .milliseconds(5)
    await model.start()
    return (model, services)
  }

  @Test func startPicksFirstDirectBrowserAndItsDefaults() async {
    let (model, _) = await started()
    #expect(model.step == .choose)
    #expect(model.source?.id == "chrome")
    #expect(model.sourceProfiles == ["Default"])
    #expect(model.kinds == Set(ImportFixtures.chromeKinds))
    #expect(model.target == "default")
    #expect(model.offeredKinds == [.bookmarks, .history, .passwords, .cookies, .autofill, .tabs])
  }

  @Test func preferredSourceWins() async {
    let (model, _) = await started { $0.opening = ImportOpening(available: true, preferredSource: "safari", targets: [], defaultTarget: "default") }
    #expect(model.source?.id == "safari")
    #expect(model.kinds == [.bookmarks, .history, .passwords])
    #expect(!model.showsKinds)
  }

  @Test func unavailableShowsChooseWithNoBrowsers() async {
    let (model, _) = await started { $0.opening = ImportOpening(available: false, preferredSource: nil, targets: [], defaultTarget: "default") }
    #expect(model.step == .choose)
    #expect(model.browsers.isEmpty)
    #expect(!model.canContinueChoose)
  }

  @Test func listFailureLeavesChooseEmpty() async {
    let (model, _) = await started { $0.browsers = nil }
    #expect(model.step == .choose)
    #expect(model.source == nil)
  }

  @Test func detailLines() {
    #expect(ImportModel.detail(ImportFixtures.firefox) == "Needs Full Disk Access")
    #expect(ImportModel.detail(ImportFixtures.dia) == "Asks Dia while it's open")
    #expect(ImportModel.detail(ImportFixtures.safari) == "Direct or from an exported .zip")
    #expect(ImportModel.detail(ImportFixtures.arc) == "3 spaces")
    #expect(ImportModel.detail(ImportFixtures.chrome) == "2 profiles")
    #expect(ImportModel.detail(ImportFixtures.brave) == "")
  }

  @Test func labelsFollowTheSource() async {
    let (model, _) = await started()
    model.choose(ImportFixtures.arc)
    #expect(model.label(.tabs) == "Spaces and tabs")
    #expect(model.offeredKinds == [.bookmarks, .history, .passwords, .cookies, .tabs, .favorites])
    model.choose(ImportFixtures.dia)
    #expect(model.label(.tabs) == "Open tabs")
    #expect(model.offeredKinds == [.tabs, .pinnedTabs])
    #expect(model.kinds == [.tabs, .pinnedTabs])
    model.choose(ImportFixtures.zen)
    #expect(model.label(.favorites) == "Essentials")
    #expect(model.label(.tabs) == "Spaces and tabs")
  }

  @Test func arcSelectsEverySpaceAndZenOnlyTheDefaults() async {
    let (model, _) = await started()
    model.choose(ImportFixtures.arc)
    #expect(model.spaces == ["s1", "s2", "s3"])
    model.choose(ImportFixtures.zen)
    #expect(model.spaces == ["z1"])
    #expect(model.sourceProfiles == ["a"])
    #expect(model.spaceless.map(\.id) == ["b"])
  }

  @Test func routing() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.firefox)
    await model.next()
    #expect(model.step == .access)
    model.goBack(to: .choose)
    model.choose(ImportFixtures.safari)
    await model.next()
    #expect(model.step == .safari)
    model.goBack(to: .choose)
    model.choose(ImportFixtures.chrome)
    await model.next()
    #expect(model.step == .profiles)
    model.goBack(to: .choose)
    model.choose(ImportFixtures.arc)
    await model.next()
    #expect(model.step == .profiles)
    #expect(services.requests.isEmpty)
  }

  @Test func singleProfileWithoutSecretsRunsAtOnce() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.brave)
    model.setKind(.passwords, false)
    await model.next()
    #expect(model.step == .done)
    #expect(services.requests.first?.kinds == [.bookmarks, .history])
    #expect(model.importedLine == "Imported 12 bookmarks, 340 history items.")
  }

  @Test func encryptedKindsAskToUnlock() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.brave)
    await model.next()
    #expect(model.step == .unlock)
    #expect(model.unlockBackStep == .choose)
    await model.unlock()
    #expect(services.calls.contains("unlock brave"))
    #expect(model.step == .done)
  }

  @Test func alreadyUnlockedSkipsTheUnlockStep() async {
    let (model, services) = await started { $0.unlocked = ["brave"] }
    model.choose(ImportFixtures.brave)
    await model.next()
    #expect(model.step == .done)
    #expect(services.requests.count == 1)
  }

  @Test func encryptedTabsAloneAskToUnlock() async {
    let (model, _) = await started()
    model.kinds = [.tabs]
    model.goBack(to: .profiles)
    await model.next()
    #expect(model.step == .unlock)
    #expect(model.unlockBackStep == .profiles)
    model.sourceProfiles = ["Profile 1"]
    model.goBack(to: .profiles)
    await model.next()
    #expect(model.step == .done)
  }

  @Test func refusedUnlockExplains() async {
    let (model, _) = await started { $0.unlockSucceeds = false }
    model.goBack(to: .profiles)
    await model.next()
    await model.unlock()
    #expect(model.step == .unlock)
    #expect(model.error == "macOS didn't allow access to Google Chrome's keychain item. Try again, or skip the encrypted data.")
    #expect(!model.unlocking)
  }

  @Test func skipEncryptedDropsPasswordsAndCookiesButKeepsAutofill() async {
    let (model, services) = await started()
    model.goBack(to: .profiles)
    await model.next()
    await model.skipEncrypted()
    let request = try! #require(services.requests.first)
    #expect(request.withoutKey)
    #expect(request.kinds == [.bookmarks, .history, .autofill, .tabs])
  }

  @Test func continueRules() async {
    let (model, _) = await started()
    model.kinds = []
    #expect(!model.canContinueChoose)
    model.choose(ImportFixtures.firefox)
    model.kinds = []
    #expect(model.canContinueChoose)
    model.choose(ImportFixtures.arc)
    model.spaces = []
    #expect(!model.canContinueProfiles)
    model.choose(ImportFixtures.zen)
    model.spaces = []
    model.sourceProfiles = ["b"]
    #expect(model.canContinueProfiles)
    model.choose(ImportFixtures.chrome)
    model.sourceProfiles = []
    #expect(!model.canContinueProfiles)
  }

  @Test func progressFollowsOnlyTheCurrentRun() async {
    let (model, services) = await started { $0.holdRun = true; $0.unlocked = ["chrome"] }
    model.goBack(to: .profiles)
    let running = Task { await model.next() }
    while services.requests.isEmpty { await Task.yield() }
    #expect(model.step == .progress)
    let runId = try! #require(model.runId)
    services.push(ImportProgressUpdate(runId: "stale", preparing: 5, status: [.history: .failed]))
    services.push(ImportProgressUpdate(runId: runId, preparing: 1, status: [.bookmarks: .active, .history: .pending]))
    while model.status.isEmpty { await Task.yield() }
    #expect(model.status == [.bookmarks: .active, .history: .pending])
    #expect(model.progressRows.map(\.kind) == [.bookmarks, .history])
    services.release(ImportRunOutcome(status: [.bookmarks: .done, .history: .failed], failures: [ImportFailure(kind: .history, profiles: ["Person 1"])], counts: ImportCounts(bookmarks: 3)))
    await running.value
    #expect(model.step == .done)
    #expect(model.summary == ["3 bookmarks"])
    #expect(ImportModel.failureLine(model.failures[0]) == "History import failed for profiles Person 1")
  }

  @Test func cancelledRunStaysPut() async {
    let (model, services) = await started { $0.outcome = .cancelledRun; $0.unlocked = ["chrome"] }
    model.goBack(to: .profiles)
    await model.next()
    #expect(model.step == .progress)
    model.cancelProgress()
    #expect(services.calls.suffix(2) == ["cancel", "close"])
  }

  @Test func refusedDestinationFinishesWithPartialCountsAndFailures() async {
    let (model, services) = await started { $0.unlocked = ["chrome"] }
    services.outcome = ImportRunOutcome(status: [.bookmarks: .failed], failures: [ImportFailure(kind: .bookmarks, profiles: ["Second"])], counts: ImportCounts(bookmarks: 3))
    model.sourceProfiles = ["Default", "Profile 1"]
    model.goBack(to: .profiles)
    await model.next()
    #expect(model.step == .done)
    #expect(model.counts.bookmarks == 3)
    #expect(model.status[.bookmarks] == .failed)
    #expect(model.failures == [ImportFailure(kind: .bookmarks, profiles: ["Second"])])
  }

  @Test func diaRefusedDestinationFinishesWithPartialCountsAndFailures() async {
    let (model, services) = await started()
    services.diaOutcome = ImportRunOutcome(status: [.tabs: .failed, .pinnedTabs: .failed], failures: [ImportFailure(kind: .tabs, profiles: ["Second"])], counts: ImportCounts(tabs: 4))
    model.choose(ImportFixtures.dia)
    await model.next()
    model.sourceProfiles = ["p1", "p2"]
    await model.next()
    #expect(model.step == .done)
    #expect(model.counts.tabs == 4)
    #expect(model.status[.tabs] == .failed)
    #expect(model.failures == [ImportFailure(kind: .tabs, profiles: ["Second"])])
  }

  @Test func summaryWording() async {
    let (model, services) = await started { $0.unlocked = ["brave"] }
    services.outcome = ImportRunOutcome(counts: ImportCounts(bookmarks: 1, history: 1, tabs: 2, passwords: 1, cookies: 30, addresses: 1, cards: 2))
    model.choose(ImportFixtures.brave)
    await model.next()
    #expect(model.importedLine == "Imported 1 bookmark, 1 history item, 1 password, 30 cookies, 1 address, 2 cards, 2 tabs.")
    services.outcome = ImportRunOutcome(counts: ImportCounts(addresses: 3))
    model.goBack(to: .choose)
    await model.next()
    #expect(model.summary == ["3 addresses"])
    #expect(ImportModel.failureLine(ImportFailure(kind: .cookies)) == "Cookies (stay signed in) import failed")
  }

  @Test func extensionLines() async {
    let (model, services) = await started { $0.unlocked = ["brave"]; $0.onboarding = true }
    services.outcome = ImportRunOutcome(extensionsProfile: "work", extensions: [ImportedExtension(id: "a", name: "uBlock Origin Lite", webStoreUrl: "https://chromewebstore.google.com/detail/a")])
    model.choose(ImportFixtures.brave)
    await model.next()
    #expect(model.extensionsIntro == "Brave has 1 extension from the Chrome Web Store. Add the ones you want there:")
    #expect(model.openExtensionsTitle == "Open in Chrome Web Store")
    model.openInWebStore()
    #expect(services.calls.last == "openInWebStore work 1")
    #expect(model.extensionsOpenedLine == "Its page is open in your sidebar, ready when you finish setting up. Click Add to Solara on each one you want.")
  }

  @Test func diaFlowWithTwoProfiles() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.dia)
    await model.next()
    #expect(model.step == .profiles)
    #expect(model.source?.profiles.map(\.id) == ["p1", "p2"])
    #expect(model.sourceProfiles == ["p1"])
    #expect(model.diaSummary("p1") == "4 pinned tabs · 11 open tabs")
    #expect(model.diaSummary("p2") == "1 pinned tab · 1 open tab")
    model.sourceProfiles = ["p1", "p2"]
    model.target = "work"
    await model.next()
    #expect(services.calls.last == "runDia p1,p2 work pinned=true open=true")
    #expect(model.step == .done)
    #expect(model.counts.tabs == 9)
    #expect(model.progressTitle == "Importing from Dia")
  }

  @Test func diaSingleProfileRunsAtOnce() async {
    let (model, services) = await started { $0.diaRead = .read(profiles: [ImportFixtures.diaProfiles[0]], windowCount: 1) }
    model.choose(ImportFixtures.dia)
    model.setKind(.pinnedTabs, false)
    await model.next()
    #expect(services.calls.last == "runDia p1 default pinned=false open=true")
    #expect(model.step == .done)
  }

  @Test func diaEmptyAndFailedReads() async {
    let (model, services) = await started { $0.diaRead = .read(profiles: [], windowCount: 0) }
    model.choose(ImportFixtures.dia)
    await model.next()
    #expect(model.error == "Dia has no open windows. Open one, then try again.")
    services.diaRead = .read(profiles: [], windowCount: 2)
    await model.readDia()
    #expect(model.error == "Dia has no open or pinned web pages to import.")
    services.diaRead = .failed(code: "unreadable", message: "Dia didn't answer")
    await model.readDia()
    #expect(model.diaStatus == .granted)
    #expect(model.error == "Dia didn't answer. Try again.")
    services.diaRead = .failed(code: "locked", message: "x")
    await model.readDia()
    #expect(model.diaStatus == .denied)
  }

  @Test func diaNotRunningPollsUntilGranted() async {
    let (model, services) = await started { $0.diaStatuses = [.notRunning, .notRunning, .granted] }
    model.choose(ImportFixtures.dia)
    await model.next()
    #expect(model.diaStatus == .notRunning)
    #expect(model.pollsDia)
    await model.pollDia()
    #expect(services.calls.filter { $0 == "diaStatus" }.count == 3)
    #expect(model.step == .profiles)
  }

  @Test func diaPermission() async {
    let (model, services) = await started { $0.diaStatuses = [.notDetermined] }
    model.choose(ImportFixtures.dia)
    await model.next()
    #expect(model.diaStatus == .notDetermined)
    await model.allowDia()
    #expect(services.calls.contains("requestDia"))
    #expect(model.step == .profiles)
  }

  @Test func openDiaFailure() async {
    let (model, _) = await started { $0.diaStatuses = [.notRunning]; $0.openDiaSucceeds = false }
    model.choose(ImportFixtures.dia)
    await model.next()
    await model.openDia()
    #expect(model.error == "Couldn't open Dia. Open it yourself, then click Check Again.")
  }

  @Test func safariExportOutcomes() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.safari)
    await model.next()
    await model.chooseSafariExport()
    #expect(services.calls.contains("safariExport /Users/owner/Downloads/Safari Export.zip default"))
    #expect(model.step == .done)
    model.goBack(to: .safari)
    services.fileOutcome = .failed(code: "unsupported")
    await model.importSafari(path: "/tmp/x.txt")
    #expect(model.step == .safari)
    #expect(model.error == "Please select a folder or zip file.")
    services.fileOutcome = .failed(code: "unreadable")
    await model.importSafari(path: "/tmp/x.zip")
    #expect(model.error == "The selected file is invalid. Please try again.")
    services.fileOutcome = .imported(ImportCounts(bookmarks: 2), failed: [.autofill])
    await model.importSafari(path: "/tmp/x.zip")
    #expect(model.status[.autofill] == .failed)
    #expect(model.failures == [ImportFailure(kind: .autofill)])
  }

  @Test func safariDirect() async {
    let (model, services) = await started { $0.fullDiskAccess = true }
    model.choose(ImportFixtures.safari)
    while !model.fullDiskAccess { await Task.yield() }
    await model.next()
    model.safariCookies = false
    services.fileOutcome = .failed(code: "locked")
    services.fullDiskAccess = false
    await model.importSafariDirect()
    #expect(services.calls.last == "safariDirect default cookies=false")
    #expect(model.step == .safari)
    #expect(model.error == "Solara still doesn't have Full Disk Access. Grant it above, or use the export file below.")
    #expect(!model.fullDiskAccess)
    services.fileOutcome = .imported(ImportCounts(history: 5), failed: [.cookies])
    model.safariCookies = true
    await model.importSafariDirect()
    #expect(model.status == [.bookmarks: .done, .history: .done, .tabs: .done, .cookies: .failed])
  }

  @Test func bookmarksHTML() async {
    let (model, services) = await started()
    services.fileOutcome = .cancelled
    await model.importHTML()
    #expect(model.step == .choose)
    services.fileOutcome = .failed(code: "unreadable")
    await model.importHTML()
    #expect(model.error == "The selected file is invalid. Please try again.")
    services.fileOutcome = .imported(ImportCounts(bookmarks: 7), failed: [])
    await model.importHTML()
    #expect(model.step == .done)
    #expect(model.source == nil)
    #expect(model.importedLine == "Imported 7 bookmarks.")
  }

  @Test func accessRecheckMovesOnOnceGranted() async {
    let (model, services) = await started()
    model.choose(ImportFixtures.firefox)
    await model.next()
    #expect(model.step == .access)
    var granted = ImportFixtures.firefox
    granted = ImportBrowser(id: granted.id, name: granted.name, family: granted.family, needsFullDiskAccess: false, profiles: granted.profiles)
    services.browsers = [granted]
    await model.appBecameActive()
    #expect(model.step == .choose)
    #expect(model.source?.needsFullDiskAccess == false)
  }

  @Test func arcRestoreAndTargets() async {
    let (model, services) = await started { $0.arcHolders = 2; $0.unlocked = ["brave"] }
    model.choose(ImportFixtures.brave)
    await model.next()
    #expect(model.arcHolders == 2)
    await model.restoreArcFolders()
    #expect(model.arcHolders == 0)
    services.push(targets: [ImportTarget(id: "default", name: "Personal")])
    while model.targets.count != 1 { await Task.yield() }
    model.dispose()
    #expect(services.calls.last == "dispose")
  }
}
