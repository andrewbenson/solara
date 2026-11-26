import AppKit
import SolaraCore
import Foundation
import Observation
import os
import SolaraUI
import SolaraStore

@MainActor
@Observable
final class ExtensionsAdapter: ExtensionsServices {
  private(set) var focusedWindowProfileId: String?
  @ObservationIgnored private var observer: Int?
  @ObservationIgnored private var observed: Store?
  @ObservationIgnored private var subscription: Int?

  init() {
    observer = NativeStoreHandle.subscribeLifecycle { [weak self] in self?.attach() }
  }

  private func attach() {
    let next = NativeStoreHandle.ownsWorkspace ? NativeStoreHandle.store : nil
    if observed !== next {
      if let subscription { observed?.unsubscribe(subscription) }
      observed = next
      if let next {
        subscription = next.sequence {
          let revision = next.rev
          let profile = OSAllocatedUnfairLock(initialState: Optional(ExtensionPresentation.focusedProfile(in: next.state)))
          return next.subscribe { [weak self, weak next] commit in
            guard commit.rev > revision else { return }
            let changed = profile.withLock { previous in
              guard let current = ExtensionPresentation.focusedProfileChange(commit, from: previous) else { return false }
              previous = current
              return true
            }
            guard changed else { return }
            Task { @MainActor in
              guard let self, let next, self.observed === next, NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === next else { return }
              self.updateFocusedProfile()
            }
          }
        }
      } else {
        subscription = nil
      }
    }
    updateFocusedProfile()
  }

  private func updateFocusedProfile() {
    let profile = NativeExtensionCommands.focusedProfile
    if focusedWindowProfileId != profile { focusedWindowProfileId = profile }
  }

  isolated deinit {
    if let observer { NativeStoreHandle.unsubscribeLifecycle(observer) }
    if let subscription { observed?.unsubscribe(subscription) }
  }

  func listExtensions(profile: String) async throws -> [InstalledExtension] {
    let listed = await EngineCalls.result({ done in SolaraCoreServices.listExtensions(profile: profile) { done($0) } }) {
      (error: Self.engineError($0), list: Self.sorted($0.list("extensions").compactMap(Self.installed)))
    }
    if let error = listed.error { throw ExtensionServiceError(error) }
    return listed.list
  }

  func setExtensionEnabled(_ id: String, enabled: Bool, profile: String) async throws {
    try await changing(profile) { done in SolaraCoreServices.setExtension(id, enabled: enabled, profile: profile) { done($0) } }
  }

  func uninstallExtension(_ id: String, profile: String) async throws {
    try await changing(profile) { done in SolaraCoreServices.uninstallExtension(id, profile: profile) { done($0) } }
  }

  func reloadExtension(_ id: String, profile: String) async throws {
    try await changing(profile) { done in SolaraCoreServices.reloadExtension(id, profile: profile) { done($0) } }
  }

  func configureExtension(_ id: String, profile: String, options: ExtensionConfiguration) async throws {
    var patch: [String: Any] = [:]
    if let pinned = options.pinned { patch["pinned"] = pinned }
    if let incognito = options.incognito { patch["incognito"] = incognito }
    if let siteAccess = options.siteAccess { patch["siteAccess"] = siteAccess.rawValue }
    let options = patch
    try await changing(profile) { done in SolaraCoreServices.configureExtension(id, profile: profile, options: options) { done($0) } }
  }

  func chooseExtensionFolder() async -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    panel.message = "Choose an extension folder (with a manifest.json)"
    let response = await panel.begin()
    return response == .OK ? panel.url?.path : nil
  }

  func inspectUnpackedExtension(path: String) async throws -> ExtensionPackage {
    let dict = SolaraCoreServices.inspectUnpacked(path)
    if let error = Self.engineError(dict) { throw ExtensionServiceError(error) }
    return ExtensionPackage(
      name: dict.string("name") ?? "Extension",
      version: dict.string("version") ?? "",
      icon: dict.string("icon"),
      permissions: dict.strings("permissions"),
      hostPermissions: dict.strings("hostPermissions"),
      path: dict.string("path") ?? path
    )
  }

  func installExtension(path: String, profile: String) async throws {
    try await changing(profile) { done in SolaraCoreServices.installExtension(path: path, profile: profile) { done($0) } }
  }

  func extensionChanges() -> AsyncStream<ExtensionsChange> {
    AsyncStream { continuation in
      let token = NotificationCenter.default.addObserver(forName: Notification.Name("SolaraExtensionsChanged"), object: nil, queue: .main) { note in
        guard let profile = note.userInfo?["profile"] as? String, let id = note.userInfo?["id"] as? String,
          let raw = note.userInfo?["event"] as? String, let event = ExtensionsChange.Event(rawValue: raw) else { return }
        continuation.yield(ExtensionsChange(profile: profile, id: id, event: event))
      }
      let receipt = ExtensionChangeObserver(token)
      continuation.onTermination = { _ in receipt.cancel() }
    }
  }

  func closeExtensionSurfaces(_ id: String) { SettingsJS.shared.fire("extensions.closeSurfaces", id) }

  func openWebStoreDetail(_ url: String, profile: String) { NativeExtensionCommands.run(["command": "webStoreDetail", "url": .string(url), "profile": .string(profile), "windowId": "settings"]) }

  func openInNewTab(_ url: String) {
    guard let opening = SettingsDirectWrites.opening else {
      SettingsJS.shared.fire("extensions.openInNewTab", url)
      return
    }
    opening.openInNewTab(url)
  }

  private func changing(_ profile: String, _ start: (@escaping @Sendable ([String: Any]) -> Void) -> Void) async throws {
    let error = await EngineCalls.result(start) { Self.engineError($0) }
    NativeExtensionCatalog.refresh(profile)
    if let error { throw ExtensionServiceError(error) }
  }

  nonisolated static func engineError(_ result: [String: Any]) -> String? {
    result["error"].map { $0 as? String ?? String(describing: $0) }
  }

  nonisolated static func sorted(_ list: [InstalledExtension]) -> [InstalledExtension] {
    list.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedAscending }
  }

  nonisolated static func installed(_ dict: [String: Any]) -> InstalledExtension? {
    guard let id = dict.string("id") else { return nil }
    let enabled = dict.bool("enabled") ?? false
    return InstalledExtension(
      id: id,
      name: dict.string("name") ?? id,
      version: dict.string("version") ?? "",
      description: dict.string("description") ?? "",
      enabled: enabled,
      state: dict.string("state"),
      icon: dict.string("icon") ?? "",
      permissions: dict.strings("permissions"),
      siteAccess: dict.string("siteAccess").map(ExtensionSiteAccess.init(engineValue:)),
      optionsUrl: dict.string("optionsUrl"),
      pinned: dict.bool("pinned") ?? false,
      incognito: dict.bool("incognito") ?? false,
      mayModify: dict.bool("mayModify") ?? true,
      errors: dict.strings("errors"),
      path: dict.string("path"),
      fromWebStore: dict.bool("fromWebStore") ?? false,
      webStoreUrl: dict.string("webStoreUrl")
    )
  }
}

private final class ExtensionChangeObserver: @unchecked Sendable {
  let token: NSObjectProtocol
  init(_ token: NSObjectProtocol) { self.token = token }
  func cancel() { NotificationCenter.default.removeObserver(token) }
}
