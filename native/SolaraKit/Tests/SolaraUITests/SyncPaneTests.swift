import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeSyncServices: SyncServices {
  func invalidatePairing(_ reason: String) {}
  var state: SyncState
  var folders: [String: SyncFolderInfo]
  var defaultFolder = "/Users/owner/Library/Mobile Documents/com~apple~CloudDocs/Solara Sync"
  var pickedFolder: String? = "/Users/owner/Dropbox/Sync"
  var turnOnError: String?
  var phraseResult: SyncPhraseResult = .ok
  var words = ["abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire", "across", "act", "action", "actor", "actress", "actual"]
  var unavailable: String?
  var calls: [String] = []
  var folderInfoRequests: [String?] = []
  private var continuation: AsyncStream<SyncState>.Continuation?

  init(state: SyncState, folders: [String: SyncFolderInfo] = [:]) {
    self.state = state
    self.folders = folders
  }

  func push(_ next: SyncState) {
    state = next
    continuation?.yield(next)
  }

  func currentSyncState() async -> SyncState { state }

  func syncStateUpdates() -> AsyncStream<SyncState> {
    let (stream, continuation) = AsyncStream<SyncState>.makeStream()
    self.continuation = continuation
    return stream
  }

  func chooseSyncFolder() async -> String? {
    calls.append("chooseSyncFolder")
    if let pickedFolder { state.folder = pickedFolder }
    return pickedFolder
  }

  func turnOnSync(folder: String) async -> String? {
    calls.append("turnOnSync \(folder)")
    return turnOnError
  }

  func enterRecoveryPhrase(folder: String, text: String) async -> SyncPhraseResult {
    calls.append("enterRecoveryPhrase \(folder) \(SyncPhrase.countWords(text))")
    return phraseResult
  }

  func stopSync(deleteData: Bool) async { calls.append("stopSync deleteData=\(deleteData)") }
  func syncNow() async { calls.append("syncNow") }
  func setTypeSynced(_ type: SyncDataType, _ on: Bool) { calls.append("setTypeSynced \(type.rawValue) \(on)") }
  func setProfileSynced(_ profileId: String, _ on: Bool) { calls.append("setProfileSynced \(profileId) \(on)") }
  func addRemoteProfile(_ syncId: String) { calls.append("addRemoteProfile \(syncId)") }

  func folderInfo(path: String?) async -> SyncFolderInfo? {
    folderInfoRequests.append(path)
    let key = path ?? defaultFolder
    return folders[key] ?? SyncFolderInfo(path: key, defaultPath: defaultFolder, iCloudAvailable: true, inICloud: key.contains("com~apple~CloudDocs"), exists: true, writable: true, hasSyncData: false)
  }

  func recoveryWords() async -> [String]? { words }
  func phraseUnavailable() async -> String? { unavailable }
  func recoveryQRCode() async -> Data? { SyncTestImages.qrCode(words.joined(separator: " ")) }
  func recoveryKitPreview(width: Double) async -> Data? { SyncTestImages.kitPreview() }
  func saveRecoveryKit(_ format: SyncKitFormat) async -> String? {
    calls.append("saveRecoveryKit \(format.rawValue)")
    return "/Users/owner/Documents/Solara Recovery Kit.pdf"
  }
  func copyRecoveryKit() async { calls.append("copyRecoveryKit") }
  func shareRecoveryKit() async { calls.append("shareRecoveryKit") }
  func copyRecoveryPhrase() async { calls.append("copyRecoveryPhrase") }
  func revealFolder(_ path: String) async { calls.append("revealFolder \(path)") }
  func openICloudSettings() { calls.append("openICloudSettings") }
}

enum SyncTestImages {
  static func qrCode(_ text: String) -> Data? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)) else { return nil }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return png(image)
  }

  static func kitPreview() -> Data? {
    let size = NSSize(width: 336, height: 434)
    let image = NSImage(size: size, flipped: true) { rect in
      NSColor.white.setFill()
      rect.fill()
      let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black]
      NSString(string: "Recovery Kit").draw(at: NSPoint(x: 24, y: 28), withAttributes: title)
      NSColor(white: 0.85, alpha: 1).setFill()
      for line in 0..<12 {
        NSRect(x: 24, y: 80 + CGFloat(line) * 22, width: line % 3 == 2 ? 180 : 288, height: 8).fill()
      }
      return true
    }
    return png(image)
  }

  static func png(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }
}

@MainActor
enum SyncFixture {
  static let now = Date(timeIntervalSince1970: 1_792_000_000)
  static let iCloudFolder = "/Users/owner/Library/Mobile Documents/com~apple~CloudDocs/Solara Sync"

  static func folder(_ path: String = iCloudFolder, iCloud: Bool = true, hasData: Bool = false, exists: Bool = true) -> SyncFolderInfo {
    SyncFolderInfo(path: path, defaultPath: iCloudFolder, iCloudAvailable: iCloud, inICloud: path.contains("com~apple~CloudDocs"), exists: exists, writable: exists, hasSyncData: hasData)
  }

  static func offState(status: SyncStatus = .off, error: String? = nil) -> SyncState {
    SyncState(status: status, enabled: false, folder: nil, error: error)
  }

  static func onState(status: SyncStatus = .updated, error: String? = nil, pending: Int = 0) -> SyncState {
    var types = Dictionary(uniqueKeysWithValues: SyncDataType.allCases.map { ($0, true) })
    types[.history] = false
    return SyncState(
      status: status,
      enabled: true,
      folder: iCloudFolder,
      types: types,
      lastSyncedAt: Date().addingTimeInterval(-5 * 60),
      error: error,
      pending: pending,
      devices: [
        SyncDevice(id: "d1", name: "Owner’s MacBook Pro", lastSeen: Date(), current: true),
        SyncDevice(id: "d2", name: "Studio", lastSeen: Date().addingTimeInterval(-3 * 3600), current: false),
        SyncDevice(id: "d3", name: "Mac mini", lastSeen: nil, current: false),
      ],
      localProfiles: [
        SyncLocalProfile(id: "default", badge: SyncProfileBadge(name: "Personal", accentHex: "#C07A98", icon: nil), synced: true),
        SyncLocalProfile(id: "work", badge: SyncProfileBadge(name: "Work", accentHex: "#4691C3", icon: "symbol:briefcase.fill"), synced: false),
        SyncLocalProfile(id: "side", badge: SyncProfileBadge(name: "Side Project", accentHex: "#7873AF", icon: "🚀"), sharesDataWith: "Work", synced: nil),
      ],
      remoteProfiles: [
        SyncRemoteProfile(syncId: "r1", badge: SyncProfileBadge(name: "School", accentHex: "#D37B8B", icon: "symbol:graduationcap.fill")),
        SyncRemoteProfile(syncId: "r2", badge: SyncProfileBadge(name: "Lab", accentHex: "#5E9E6E", icon: nil), sharesWith: .init(name: "School", added: false)),
        SyncRemoteProfile(syncId: "r3", badge: SyncProfileBadge(name: "Archive", accentHex: "#8E8E93", icon: nil), waiting: true),
      ]
    )
  }

  struct Timeout: Error {}

  static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else { throw Timeout() }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  static func model(_ state: SyncState, folder: SyncFolderInfo = folder()) async -> (SyncPaneModel, FakeSyncServices) {
    let services = FakeSyncServices(state: state, folders: [folder.path: folder])
    let model = SyncPaneModel(services: services)
    await model.prepare(SettingsPlace(pane: .sync))
    return (model, services)
  }

  static func context(_ state: SyncState, folder: SyncFolderInfo = folder()) async -> (SettingsContext, SyncPaneModel, FakeSyncServices) {
    let (context, _) = await SettingsFixture.loaded()
    let (model, services) = await model(state, folder: folder)
    context.panes[.sync] = model
    return (context, model, services)
  }
}

@MainActor
struct SyncPaneModelTests {
  @Test func preparesStateAndFolderAndReportsLoaded() async {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    #expect(model.isLoaded(SettingsPlace(pane: .sync)))
    #expect(model.state?.status == .off)
    #expect(model.info?.path == SyncFixture.iCloudFolder)
    #expect(services.folderInfoRequests == [nil])
  }

  @Test func loadedEvenWhenFolderInfoIsMissing() async {
    let services = FakeSyncServices(state: SyncFixture.offState(status: .unavailable))
    let model = SyncPaneModel(services: services)
    #expect(!model.isLoaded(SettingsPlace(pane: .sync)))
    await model.prepare(SettingsPlace(pane: .sync))
    #expect(model.isLoaded(SettingsPlace(pane: .sync)))
  }

  @Test func offDescriptionFollowsResetErrorThenSyncData() async {
    let (plain, _) = await SyncFixture.model(SyncFixture.offState())
    #expect(plain.offDescription == "Off")
    let (withData, _) = await SyncFixture.model(SyncFixture.offState(), folder: SyncFixture.folder(hasData: true))
    #expect(withData.offDescription == "Enter a recovery phrase from another device to use the synced data in this folder.")
    let (reset, _) = await SyncFixture.model(SyncFixture.offState(status: .reset, error: "Sync was reset on another Mac."), folder: SyncFixture.folder(hasData: true))
    #expect(reset.offDescription == "Sync was reset on another Mac.")
  }

  @Test func iCloudOffOnlyCountsForTheDefaultFolder() async {
    let (atDefault, _) = await SyncFixture.model(SyncFixture.offState(), folder: SyncFixture.folder(iCloud: false))
    #expect(atDefault.noICloud)
    let (elsewhere, _) = await SyncFixture.model(SyncFixture.offState(), folder: SyncFixture.folder("/Volumes/NAS/Sync", iCloud: false))
    #expect(!elsewhere.noICloud)
  }

  @Test func turningOnShowsTheRecoveryKitOrTheFailure() async {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    await model.turnOn()
    #expect(services.calls == ["turnOnSync \(SyncFixture.iCloudFolder)"])
    #expect(model.sheet == .recoveryKit)
    #expect(model.failure == nil)

    let (failing, failingServices) = await SyncFixture.model(SyncFixture.offState())
    failingServices.turnOnError = "Couldn’t use that folder: permission denied"
    await failing.turnOn()
    #expect(failing.sheet == nil)
    #expect(failing.failure == "Couldn’t use that folder: permission denied")
    #expect(!failing.turningOn)
  }

  @Test func choosingAFolderReloadsItsInfo() async {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    await model.chooseFolder()
    #expect(model.info?.path == "/Users/owner/Dropbox/Sync")
    #expect(model.folderDescription == "~/Dropbox/Sync")
    services.pickedFolder = nil
    await model.chooseFolder()
    #expect(model.info?.path == "/Users/owner/Dropbox/Sync")
  }

  @Test func changingTheFolderFromThePhraseSheetReopensItWithoutChange() async {
    let (model, _) = await SyncFixture.model(SyncFixture.offState())
    model.sheet = .phrase(canChangeFolder: true)
    await model.changeFolderForPhrase()
    #expect(model.sheet == .phrase(canChangeFolder: false))
    #expect(model.info?.path == "/Users/owner/Dropbox/Sync")
  }

  @Test func phraseResultsBecomeMessagesAndSuccessClosesTheSheet() async {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    model.sheet = .phrase(canChangeFolder: true)
    services.phraseResult = .unknownWord("abandn")
    #expect(await model.submitPhrase("abandn") == "“abandn” is not a valid recovery phrase word.")
    #expect(model.sheet == .phrase(canChangeFolder: true))
    services.phraseResult = .ok
    #expect(await model.submitPhrase(services.words.joined(separator: " ")) == nil)
    #expect(model.sheet == nil)
    #expect(services.calls.last == "enterRecoveryPhrase \(SyncFixture.iCloudFolder) 24")
    #expect(SyncPhraseResult.mismatch.message?.hasPrefix("This recovery phrase doesn’t match") == true)
    #expect(SyncPhraseResult.wordCount(3).message == "Recovery phrase must be exactly 24 words.")
    #expect(SyncPhraseResult.interrupted.message == "Sync was turned off or on again while this phrase was checked. Enter it again.")
  }

  @Test func stateUpdatesReloadFolderInfoOnlyWhenTheyMatter() async throws {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    #expect(services.folderInfoRequests.count == 1)
    var next = SyncFixture.offState()
    next.pending = 2
    services.push(next)
    try await SyncFixture.waitUntil { model.state?.pending == 2 }
    #expect(services.folderInfoRequests.count == 1)
    services.push(SyncFixture.onState(status: .starting))
    try await SyncFixture.waitUntil { services.folderInfoRequests.count == 2 }
    #expect(model.state?.enabled == true)
    #expect(services.folderInfoRequests.last == SyncFixture.iCloudFolder)
  }

  @Test func preparingTwiceListensOnce() async throws {
    let (model, services) = await SyncFixture.model(SyncFixture.offState())
    await model.prepare(SettingsPlace(pane: .sync))
    services.push(SyncFixture.onState())
    try await SyncFixture.waitUntil { model.state?.enabled == true }
  }

  @Test func togglesCallTheEngineAndUpdateAtOnce() async {
    let (model, services) = await SyncFixture.model(SyncFixture.onState())
    model.setType(.history, true)
    #expect(model.state?.types[.history] == true)
    model.setProfile("work", true)
    #expect(model.state?.localProfiles.first { $0.id == "work" }?.synced == true)
    model.setProfile("side", true)
    #expect(model.state?.localProfiles.first { $0.id == "side" }?.synced == nil)
    #expect(services.calls == ["setTypeSynced history true", "setProfileSynced work true", "setProfileSynced side true"])
  }

  @Test func stoppingPassesTheDeleteChoiceAndClosesTheSheet() async {
    let (model, services) = await SyncFixture.model(SyncFixture.onState())
    model.sheet = .deleteData
    await model.stop(deleteData: true)
    #expect(model.sheet == nil)
    #expect(services.calls == ["stopSync deleteData=true"])
  }
}

struct SyncTextTests {
  let now = Date(timeIntervalSince1970: 1_792_000_000)

  @Test func agoMatchesTheRNBuckets() {
    #expect(SyncText.ago(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(SyncText.ago(now.addingTimeInterval(30), now: now) == "just now")
    #expect(SyncText.ago(now.addingTimeInterval(-60), now: now) == "1 minute ago")
    #expect(SyncText.ago(now.addingTimeInterval(-59 * 60), now: now) == "59 minutes ago")
    #expect(SyncText.ago(now.addingTimeInterval(-3600), now: now) == "1 hour ago")
    #expect(SyncText.ago(now.addingTimeInterval(-23 * 3600), now: now) == "23 hours ago")
    #expect(SyncText.ago(now.addingTimeInterval(-24 * 3600), now: now) == "yesterday")
    #expect(SyncText.ago(now.addingTimeInterval(-72 * 3600), now: now) == "3 days ago")
  }

  @Test func statusLines() {
    let fiveMinutes = now.addingTimeInterval(-300)
    #expect(SyncText.statusLine(.updated, lastSyncedAt: fiveMinutes, pending: 0, now: now) == "updated 5 minutes ago")
    #expect(SyncText.statusLine(.updated, lastSyncedAt: now, pending: 0, now: now) == "updated just now")
    #expect(SyncText.statusLine(.updated, lastSyncedAt: nil, pending: 0, now: now) == "updated just now")
    #expect(SyncText.statusLine(.starting, lastSyncedAt: fiveMinutes, pending: 0, now: now) == "starting up")
    #expect(SyncText.statusLine(.updating, lastSyncedAt: nil, pending: 1, now: now) == "updating · waiting for 1 file to download")
    #expect(SyncText.statusLine(.offline, lastSyncedAt: nil, pending: 3, now: now) == "offline · waiting for 3 files to download")
    #expect(SyncText.statusLine(.stalled, lastSyncedAt: fiveMinutes, pending: 0, now: now) == "not syncing · last synced 5 minutes ago")
    #expect(SyncText.statusLine(.locked, lastSyncedAt: nil, pending: 0, now: now) == "not syncing")
  }

  @Test func folderLabels() {
    #expect(SyncText.folderLabel(path: "/Users/owner/Library/Mobile Documents/com~apple~CloudDocs/Solara Sync", inICloud: true) == "iCloud Drive › Solara Sync")
    #expect(SyncText.folderLabel(path: "/Users/owner/Library/Mobile Documents/com~apple~CloudDocs", inICloud: true) == "iCloud Drive")
    #expect(SyncText.folderLabel(path: "/Users/owner/Dropbox/Sync", inICloud: false) == "~/Dropbox/Sync")
    #expect(SyncText.folderLabel(path: "/Volumes/NAS/Sync", inICloud: false) == "/Volumes/NAS/Sync")
  }

  @Test func profileAndDeviceDescriptions() {
    let badge = SyncProfileBadge(name: "Lab", accentHex: "#000000", icon: nil)
    #expect(SyncText.remoteProfileDescription(SyncRemoteProfile(syncId: "a", badge: badge)) == "On your other devices")
    #expect(SyncText.remoteProfileDescription(SyncRemoteProfile(syncId: "a", badge: badge, waiting: true)) == "On your other devices. Waiting for the profile it shares data with to sync.")
    #expect(SyncText.remoteProfileDescription(SyncRemoteProfile(syncId: "a", badge: badge, sharesWith: .init(name: "School", added: true))) == "On your other devices. Shares data with School, which is added too.")
    #expect(SyncText.remoteProfileDescription(SyncRemoteProfile(syncId: "a", badge: badge, sharesWith: .init(name: "School", added: false))) == "On your other devices. Shares data with School.")
    #expect(SyncText.sharedDataDescription("Work") == "Shares data with Work: its tabs sync here, its data syncs with Work.")
    #expect(SyncText.sharedDataDescription(nil) == nil)
    let state = SyncState(status: .updated, enabled: true, folder: nil, lastSyncedAt: now.addingTimeInterval(-120), pending: 4)
    let current = SyncDevice(id: "a", name: "MacBook", lastSeen: nil, current: true)
    #expect(SyncText.deviceTitle(current) == "MacBook (This Mac)")
    #expect(SyncText.deviceDescription(current, state: state, now: now) == "updated 2 minutes ago")
    #expect(SyncText.deviceDescription(SyncDevice(id: "b", name: "Studio", lastSeen: nil, current: false), state: state, now: now) == "hasn’t synced yet")
    #expect(SyncText.deviceDescription(SyncDevice(id: "b", name: "Studio", lastSeen: now.addingTimeInterval(-7200), current: false), state: state, now: now) == "last synced 2 hours ago")
  }

  @Test func phraseWordCounting() {
    #expect(SyncPhrase.countWords("") == 0)
    #expect(SyncPhrase.countWords("  Abandon, ability\nable 1 about-above ") == 5)
    #expect(SyncPhrase.countLabel(12) == "12/24 words")
    #expect(SyncPhrase.countLabel(25) == "too many words")
    #expect(SyncWordGrid.number(0) == " 1")
    #expect(SyncWordGrid.number(23) == "24")
  }

  @Test func sheetIdentityDistinguishesThePhraseVariants() {
    #expect(SyncSheet.phrase(canChangeFolder: true).id != SyncSheet.phrase(canChangeFolder: false).id)
  }

  @Test func hexColors() {
    #expect(SyncColor.hex("#C07A98") != nil)
    #expect(SyncColor.hex("C07A98FF") != nil)
    #expect(SyncColor.hex("plum") == nil)
  }
}

@MainActor
struct SyncSnapshotTests {
  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPaneStates() async throws {
    let states: [(String, SyncState, SyncFolderInfo)] = [
      ("sync-off", SyncFixture.offState(), SyncFixture.folder()),
      ("sync-off-data", SyncFixture.offState(), SyncFixture.folder(hasData: true)),
      ("sync-off-noicloud", SyncFixture.offState(), SyncFixture.folder(iCloud: false)),
      ("sync-on", SyncFixture.onState(pending: 2), SyncFixture.folder()),
      ("sync-locked", SyncFixture.onState(status: .locked, error: "Enter your recovery phrase to keep syncing on this Mac."), SyncFixture.folder()),
      ("sync-unavailable", SyncFixture.offState(status: .unavailable), SyncFixture.folder()),
    ]
    for (name, state, folder) in states {
      let (context, _, _) = await SyncFixture.context(state, folder: folder)
      try await Snapshot.renderPanes(context, [.sync], named: { _ in name })
    }
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersSheets() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, model, _) = await SyncFixture.context(SyncFixture.onState())
    let sheets: [(String, SyncSheet)] = [
      ("recovery-kit", .recoveryKit),
      ("phrase", .phrase(canChangeFolder: true)),
      ("connect-device", .connectDevice),
      ("stop", .stop),
      ("delete-data", .deleteData),
    ]
    for (name, sheet) in sheets {
      for dark in [false, true] {
        let view = SyncSheetView(model: model, sheet: sheet)
          .environment(\.settingsContext, context)
          .fixedSize()
        try await Snapshot.render(view, size: NSSize(width: 500, height: 420), dark: dark, to: directory.appendingPathComponent("sync-sheet-\(name)-\(dark ? "dark" : "light").png"))
      }
    }
    let words = SyncWordGrid(words: FakeSyncServices(state: SyncFixture.onState()).words).frame(width: 440).padding(20)
    for dark in [false, true] {
      try await Snapshot.render(words, size: NSSize(width: 500, height: 260), dark: dark, to: directory.appendingPathComponent("sync-sheet-words-\(dark ? "dark" : "light").png"))
    }
  }
}

@Test func heldPasswordsTitleNamesTheCountAndTheProfile() {
  #expect(SyncText.heldPasswordsTitle(SyncHeldPasswords(profileId: "default", count: 8)) == "8 passwords were removed or changed on this Mac.")
  #expect(SyncText.heldPasswordsTitle(SyncHeldPasswords(profileId: "w", profileName: "Work", count: 1)) == "1 password was removed or changed on this Mac in Work.")
}
