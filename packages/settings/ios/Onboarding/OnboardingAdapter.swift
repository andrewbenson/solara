import AppKit
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
final class OnboardingAdapter: OnboardingServices {
  static let topic = "onboarding.window"
  static let document = "onboarding.json"
  private static let joinedWriter = OnboardingJoinedWriter()
  var onboardingJoinedWriter: OnboardingJoinedWriter? { Self.joinedWriter }

  let windowId: String
  let settings: SettingsModel
  var onWindowChange: (() -> Void)?
  private var window: [String: Any]
  private var observer: UUID?
  private let previewWrites = OnboardingPreviewQueue()
  private var recoverySheet: NSWindow?
  private var recoveryGeneration = 0
  var onRecoveryPhraseConnected: ((Int) -> Void)?
  var onboardingSession: (() -> Int?)?
  var onboardingWindow: (() -> NSWindow?)?
  private let discovery = OnboardingDiscoveryAdapter(folder: OnboardingAdapter.defaultSyncFolder)

  static var defaultSyncFolder: URL {
    if let path = ProcessInfo.processInfo.environment["SOLARA_SYNC_DEFAULT_FOLDER"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    let name = Bundle.main.productName
    if let path = ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("\(name) Sync", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(name) Sync", isDirectory: true)
  }

  var onboardingDiscovery: OnboardingDiscovering? { discovery }
  var onboardingSyncFolder: String? {
    let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    if discovery.folder.deletingLastPathComponent().standardizedFileURL == cloud.standardizedFileURL {
      return "iCloud Drive › \(discovery.folder.lastPathComponent)"
    }
    return discovery.folder.path
  }
  var pairingJoining: PairingJoining? { OnboardingPairingServices.joining?(discovery.folder.path) }
  var committedOnboardingJoinToken: String? { OnboardingPairingServices.committedJoinToken?() }

  func writeJoinedOnboardingDocument(_ json: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      do {
        try DocumentStore.write(Self.document, json) { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  func drainOnboardingPreviews() async throws {
    try await previewWrites.drain()
  }

  private func enqueuePreview(_ name: String, _ arguments: [Any]) {
    previewWrites.enqueue {
      let deadline = ContinuousClock.now + Self.connectWait
      while !SettingsJS.shared.connected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      guard SettingsJS.shared.connected else { throw CocoaError(.fileWriteUnknown) }
      _ = try await SettingsJS.shared.invoke(name, arguments)
    }
  }

  func chooseOnboardingFolder(beforeChange: @MainActor () -> Bool) async -> Bool {
    guard let path = await SyncAdapter().chooseSyncFolder(), !Task.isCancelled else { return false }
    guard beforeChange() else { return false }
    discovery.folder = URL(fileURLWithPath: path, isDirectory: true)
    return true
  }

  func openOnboardingICloudSettings() { SyncAdapter().openICloudSettings() }

  func openOnboardingRecoveryPhrase() -> Bool {
    if recoverySheet != nil { return true }
    guard let parent = onboardingWindow?(), let session = onboardingSession?() else { return false }
    recoveryGeneration += 1
    let generation = recoveryGeneration
    let content = OnboardingRecoveryPhraseView(services: SyncAdapter(), folder: discovery.folder.path, onCancel: { [weak self] in
      guard let self, recoveryGeneration == generation else { return }
      recoveryGeneration += 1
      if let sheet = recoverySheet { parent.endSheet(sheet) }
    }) { [weak self] in
      guard let self, recoveryGeneration == generation, recoverySheet != nil else { return }
      recoveryGeneration += 1
      if let sheet = recoverySheet { parent.endSheet(sheet) }
      onRecoveryPhraseConnected?(session)
    }
    let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
    recoverySheet = sheet
    parent.beginSheet(sheet) { [weak self] _ in
      guard let self else { return }
      recoverySheet = nil
      recoveryGeneration += 1
    }
    return true
  }

  init(windowId: String, settings: SettingsModel) {
    self.windowId = windowId
    self.settings = settings
    window = Self.entry(SettingsJS.shared.latestValue(Self.topic), for: windowId) ?? [:]
    observer = SettingsJS.shared.observe(Self.topic) { [weak self] value in
      guard let self, let next = Self.entry(value, for: self.windowId) else { return }
      self.window = next
      self.onWindowChange?()
    }
  }

  func dispose() {
    if let observer { SettingsJS.shared.stopObserving(Self.topic, observer) }
    observer = nil
    onWindowChange = nil
    onRecoveryPhraseConnected = nil
    onboardingSession = nil
    recoveryGeneration += 1
    onboardingWindow = nil
    if let sheet = recoverySheet { sheet.sheetParent?.endSheet(sheet) }
    recoverySheet = nil
  }

  static func entry(_ value: Any?, for windowId: String) -> [String: Any]? {
    guard let dict = value as? [String: Any], dict.string("windowId") == windowId else { return nil }
    return dict
  }

  var savedDocument: [String: Any]? {
    guard let text = readDurableOnboardingDocument(), let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func readSavedDocument() -> String? { DocumentStore.readDurable(document) }

  func readDurableOnboardingDocument() -> String? { Self.readSavedDocument() }

  func readOnboardingDocument() -> String? { DocumentStore.read(Self.document) }

  func writeOnboardingDocument(_ json: String) {
    do {
      try DocumentStore.write(Self.document, json)
    } catch {
      NSLog("[onboarding] couldn't save onboarding state: %@", String(describing: error))
    }
  }

  func hasSessionDocument() -> Bool { DocumentStore.read("session.json") != nil }

  var startsOnFirstLaunch: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["SOLARA_ONBOARDING"] == "1"
    #else
    return true
    #endif
  }

  func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

  func resolveWindowId(_ windowId: String?) -> String? { windowId ?? self.windowId }

  func windowTabLayout(_ windowId: String?) -> String {
    if windowId ?? self.windowId == self.windowId, let layout = window.string("tabLayout") { return layout }
    return settings.value("tabLayout")?.string ?? "sidebar"
  }

  func setWindowTabLayout(_ windowId: String, _ layout: String) {
    if windowId == self.windowId { window["tabLayout"] = layout }
    enqueuePreview("onboarding.setWindowLayout", [windowId, layout])
  }

  func previewSettings(_ patch: JSONObject) { settings.update(patch, fromSync: true) }

  func profileColor(_ windowId: String) -> ProfileColorValue? {
    guard windowId == self.windowId else { return nil }
    return window.string("color").flatMap(ProfileColorValue.init(rawValue:))
  }

  func isIncognito(_ windowId: String) -> Bool { windowId == self.windowId && window.bool("incognito") == true }

  func setProfileColor(_ windowId: String, _ color: ProfileColorValue) {
    if windowId == self.windowId { window["color"] = color.rawValue }
    enqueuePreview("onboarding.setProfileColor", [windowId, color.rawValue])
  }

  func endToolTour() { Self.fire("onboarding.endToolTour") }

  func startToolTour(_ windowId: String) { Self.fire("onboarding.startToolTour", windowId) }

  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool) {
    let arg: [String: Double] = [
      "icon": cues.icon, "letters": cues.letters, "letterStep": cues.letterStep, "letterCount": Double(cues.letterCount),
      "tagline": cues.tagline, "exit": cues.exit, "end": cues.end,
    ]
    SystemServices.playIntroMusic(cues: arg, muted: muted)
  }

  func setIntroMusicMuted(_ muted: Bool) { SystemServices.setIntroMusicMuted(muted) }

  func stopIntroMusic(fade: Double) { SystemServices.stopIntroMusic(fade: fade) }

  func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  func fileIcon(_ path: String, size: Int) async -> NSImage? {
    let icon = FileManager.default.fileExists(atPath: path)
      ? NSWorkspace.shared.icon(forFile: path)
      : NSWorkspace.shared.icon(for: .init(filenameExtension: (path as NSString).pathExtension) ?? .data)
    icon.size = NSSize(width: size, height: size)
    return icon
  }

  var importAvailable: Bool { window.bool("importAvailable") ?? false }

  func openImport(_ browserId: String) { Self.fire("onboarding.openImport", browserId) }

  func cancelOnboardingImport() {
    NativeImportWindow.current?.dispose()
    ImportAdapter().close()
    enqueuePreview("import.cancelAndDrain", [])
  }

  var backgroundInstance: Bool { ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" }

  func isDefaultBrowser() async -> Bool { SystemServices.isDefaultBrowser() }

  func isInDock() async -> Bool { SystemServices.isInDock }

  func loginItemStatus() async -> LoginItemStatus {
    SettingsAdapters.loginItemStatus()
  }

  func setAsDefaultBrowser() async -> Bool { await SettingsAdapters.setAsDefaultBrowser() }

  func setLaunchAtLogin(_ on: Bool) async { SettingsAdapters.setLaunchAtLogin(on) }

  func addToDock() async { SystemServices.addToDock() }

  func appIcons(size: Int) async -> [OnboardingAppIcon] {
    SystemServices.appIconChoices.map { OnboardingAppIcon(id: $0.id, name: $0.name, preview: SystemServices.appIconPreview($0.id, size: CGFloat(size))) }
  }

  func currentAppIcon() async -> String? { SystemServices.currentAppIcon }

  func setAppIcon(_ id: String) async { SystemServices.setAppIcon(id) }

  func pinnedHosts(_ windowId: String) -> Set<String> {
    guard windowId == self.windowId else { return [] }
    return Set(window.strings("pinnedHosts"))
  }

  func history(_ windowId: String) -> [OnboardingHistoryVisit] {
    guard windowId == self.windowId else { return [] }
    return window.list("history").compactMap { entry in
      guard let url = entry.string("url") else { return nil }
      return OnboardingHistoryVisit(url: url, visits: entry.int("visits") ?? 0)
    }
  }

  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite]) {
    Self.fire("onboarding.pinSites", windowId, sites.map(\.id))
  }

  func favicon(_ url: String) async -> NSImage? {
    await NativeHistoryCatalog.favicon(page: url, profileId: window.string("profileId") ?? "default", dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
  }

  static let connectWait = Duration.seconds(5)

  static func fire(_ name: String, _ args: Any...) {
    Task { _ = await invoke(name, args) }
  }

  @discardableResult
  static func call(_ name: String, _ args: Any...) async -> Any? {
    await invoke(name, args)
  }

  private static func invoke(_ name: String, _ args: [Any]) async -> Any? {
    let deadline = ContinuousClock.now + connectWait
    while !SettingsJS.shared.connected, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    do {
      return try await SettingsJS.shared.invoke(name, args)
    } catch {
      NSLog("[onboarding] %@ failed: %@", name, String(describing: error))
      return nil
    }
  }
}
