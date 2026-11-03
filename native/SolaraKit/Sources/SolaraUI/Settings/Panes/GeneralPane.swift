import AppKit
import Observation
import SwiftUI

public enum LoginItemStatus: String, Sendable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
}

public struct DownloadSettings: Sendable, Equatable {
  public var folder: String
  public var askWhereToSave: Bool
  public var managed: Bool

  public init(folder: String, askWhereToSave: Bool, managed: Bool) {
    self.folder = folder
    self.askWhereToSave = askWhereToSave
    self.managed = managed
  }
}

@MainActor
public protocol GeneralServices: AnyObject {
  func loginItemStatus() async -> LoginItemStatus
  func setLaunchAtLogin(_ on: Bool) async
  func isDefaultBrowser() async -> Bool
  func setAsDefaultBrowser() async -> Bool
  func downloadSettings(profile: String) async -> DownloadSettings?
  func setDownloadSettings(folder: String?, askWhereToSave: Bool?, profile: String) async -> DownloadSettings?
  func pickFolder(current: String, prompt: String) async -> String?
  func openImport()
}

@MainActor
@Observable
public final class GeneralPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: GeneralServices
  @ObservationIgnored let store: SettingsStoreSource
  var loginStatus: LoginItemStatus?
  var isDefault: Bool?
  var downloads: [String: DownloadSettings?] = [:]
  var downloadsProfileId: String

  public init(services: GeneralServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
    downloadsProfileId = store.string("defaultProfileId")
  }

  var downloadsProfile: String { store.engineProfile(downloadsProfileId) }

  public func isLoaded(_ place: SettingsPlace) -> Bool {
    loginStatus != nil && isDefault != nil && downloads.keys.contains(store.engineProfile(store.string("defaultProfileId")))
  }

  public func prepare(_ place: SettingsPlace) async {
    let profile = store.engineProfile(store.string("defaultProfileId"))
    let services = services
    let login = Task { await services.loginItemStatus() }
    let isDefault = Task { await services.isDefaultBrowser() }
    let downloads = Task { await services.downloadSettings(profile: profile) }
    loginStatus = await login.value
    self.isDefault = await isDefault.value
    self.downloads[profile] = .some(await downloads.value)
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(GeneralPane(model: self))
  }

  func refreshLogin() async { loginStatus = await services.loginItemStatus() }
  func refreshDefault() async { isDefault = await services.isDefaultBrowser() }

  func loadDownloads(_ profile: String) async {
    downloads[profile] = .some(await services.downloadSettings(profile: profile))
  }

  func applyDownloads(folder: String?, askWhereToSave: Bool?, to profiles: [String]) async {
    for profile in profiles {
      if let next = await services.setDownloadSettings(folder: folder, askWhereToSave: askWhereToSave, profile: profile) {
        downloads[profile] = .some(next)
      }
    }
  }
}

struct GeneralPane: View {
  @Environment(\.settingsContext) private var context
  let model: GeneralPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    let store = model.store
    SettingsForm {
      DefaultBrowserCard(model: model)

      SettingsSection("General") {
        SettingRow(
          "general.openAtLogin",
          description: model.loginStatus == .requiresApproval ? "Allow it in System Settings › General › Login Items." : nil
        ) {
          Toggle("", isOn: Binding(
            get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
            set: { on in Task { await model.services.setLaunchAtLogin(on); await model.refreshLogin() } }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
        }
        SettingToggle("general.warnBeforeQuitting", key: "warnBeforeQuitting")
        SettingToggle("general.warnBeforeClosingWindow", key: "warnBeforeClosingWindow")
        SettingRow(
          "general.openLinksFrom",
          description: .text(store.bool("openLinksInLittleSolara")
            ? "Links from other apps open in a small Little \(app) window."
            : "Links from other apps open in the \(app) window you used last.")
        ) {
          SettingPicker(
            [SettingOption("small", "Little \(app)"), SettingOption("tab", "A new tab")],
            selection: Binding(get: { store.bool("openLinksInLittleSolara") ? "small" : "tab" }, set: { store.set("openLinksInLittleSolara", $0 == "small") })
          )
        }
        SettingRow(
          "general.littleSolaraNewTabLinks",
          description: .text(store.bool("littleSolaraKeepsNewTabLinks")
            ? "A link that opens a new tab opens in another Little \(app) window; ⌘-click still opens it behind, in the main window."
            : "A link that opens a new tab opens behind, as a tab of the main window.")
        ) {
          SettingPicker(
            [SettingOption("main", "Main Window"), SettingOption("small", "Little \(app)")],
            selection: Binding(get: { store.bool("littleSolaraKeepsNewTabLinks") ? "small" : "main" }, set: { store.set("littleSolaraKeepsNewTabLinks", $0 == "small") })
          )
        }
      }

      SettingsSection("When quitting \(app):") {
        SettingRow("general.windowsAndTabs") {
          SettingPicker(
            [SettingOption("keep", "Preserve tabs and windows"), SettingOption("close", "Start fresh")],
            selection: Binding(get: { store.bool("restoreSession") ? "keep" : "close" }, set: { store.set("restoreSession", $0 == "keep") })
          )
        }
      }

      SettingsSection("Command bar", description: "What happens when what you type could be a website or a search.") {
        SettingRow("general.commandBarPreference") {
          SettingPicker(
            [SettingOption("website", "Use Website First"), SettingOption("search", "Prefer Search Engine")],
            selection: store.choice("commandBarPreference")
          )
        }
      }

      DownloadsSection(model: model)

      SettingsSection("Import") {
        SettingRow("general.importBrowser") {
          Button("Import…") { model.services.openImport() }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refreshDefault() }
    }
  }
}

struct DefaultBrowserCard: View {
  @Environment(\.settingsContext) private var context
  let model: GeneralPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    let isDefault = model.isDefault ?? false
    Section {
      SettingsAnchor("general.defaultBrowser") {
        HStack(spacing: 12) {
          Image(systemName: isDefault ? "checkmark.seal.fill" : "safari")
            .font(.system(size: 20))
            .foregroundStyle(isDefault ? Color.green : Color.secondary)
            .frame(width: 28, height: 28)
          Text(isDefault ? "\(app) is your default browser" : "\(app) works best as your default browser")
            .frame(maxWidth: .infinity, alignment: .leading)
          if !isDefault {
            Button("Set \(app) as Default") {
              Task { model.isDefault = await model.services.setAsDefaultBrowser() }
            }
            .buttonStyle(.borderedProminent)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }
}

struct DownloadsSection: View {
  let model: GeneralPaneModel

  static func homeRelative(_ path: String) -> String {
    guard let match = path.range(of: "^/Users/[^/]+(?=/|$)", options: .regularExpression) else { return path }
    return path.replacingCharacters(in: match, with: "~")
  }

  var body: some View {
    let store = model.store
    let profiles = store.profiles
    let profile = model.downloadsProfile
    let current = model.downloads[profile] ?? nil
    let others = profiles.map(\.engineProfile).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.filter { $0 != profile }
    let locked = current == nil || current?.managed == true
    SettingsSection(
      "Downloads",
      description: profiles.count > 1 ? "Each profile saves to its own folder." : nil
    ) {
      if profiles.count > 1 {
        SettingPicker(profiles.map { SettingOption($0.id, $0.name) }, selection: Binding(get: { model.downloadsProfileId }, set: { model.downloadsProfileId = $0 }))
      }
    } content: {
      SettingRow(
        "general.downloadsFolder",
        description: current.map { $0.managed ? "\(Self.homeRelative($0.folder)), set by your organization." : Self.homeRelative($0.folder) }
      ) {
        Button("Change…") {
          guard let current else { return }
          Task {
            if let folder = await model.services.pickFolder(current: current.folder, prompt: "Use Folder") {
              await model.applyDownloads(folder: folder, askWhereToSave: nil, to: [profile])
            }
          }
        }
        .disabled(locked)
      }
      SettingRow("general.askWhereToSave") {
        Toggle("", isOn: Binding(
          get: { current?.askWhereToSave ?? false },
          set: { on in Task { await model.applyDownloads(folder: nil, askWhereToSave: on, to: [profile]) } }
        ))
        .labelsHidden()
        .toggleStyle(.settingsSwitch)
        .disabled(locked)
      }
      if !others.isEmpty {
        SettingRow("general.downloadsAllProfiles") {
          Button("Use for All Profiles") {
            guard let current else { return }
            Task { await model.applyDownloads(folder: current.folder, askWhereToSave: current.askWhereToSave, to: others) }
          }
          .disabled(locked)
        }
      }
    }
    .task(id: profile) {
      if model.downloads[profile] == nil { await model.loadDownloads(profile) }
    }
  }
}
