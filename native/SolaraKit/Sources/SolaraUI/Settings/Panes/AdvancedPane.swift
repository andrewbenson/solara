import AppKit
import Observation
import SolaraModel
import SwiftUI

public struct CliServerStatus: Equatable, Sendable {
  public var state: String
  public var reason: String?
  public var connections: Int?

  public init(state: String, reason: String? = nil, connections: Int? = nil) {
    self.state = state
    self.reason = reason
    self.connections = connections
  }
}

public struct CliInstallState: Equatable, Sendable {
  public var installing: Bool
  public var step: String?
  public var installedVersion: String?
  public var binPath: String?
  public var error: String?

  public init(installing: Bool = false, step: String? = nil, installedVersion: String? = nil, binPath: String? = nil, error: String? = nil) {
    self.installing = installing
    self.step = step
    self.installedVersion = installedVersion
    self.binPath = binPath
    self.error = error
  }
}

public struct AdvancedSystemInfo: Equatable, Sendable {
  public var releaseRepo: String?
  public var appVersion: String

  public init(releaseRepo: String?, appVersion: String) {
    self.releaseRepo = releaseRepo
    self.appVersion = appVersion
  }
}

@MainActor
public protocol AdvancedServices: AnyObject {
  func chromiumVersion() async -> String?
  func widevineVersion() async -> String??
  var cliServer: CliServerStatus? { get }
  var cliInstall: CliInstallState { get }
  func installCli()
  func hasDeveloperModeChanges(_ developerMode: JSONValue?) -> Bool
  func resetDeveloperModeSites()
  func openInternalPage(_ page: String)
  func openURL(_ url: String)
  var systemInfo: AdvancedSystemInfo { get }
}

@MainActor
@Observable
public final class AdvancedPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: AdvancedServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored let experiments: ExperimentsModel?
  @ObservationIgnored let hooks: HooksSectionModel?
  var chromium: String??
  var widevine: String???

  public init(services: AdvancedServices, store: SettingsStoreSource, experiments: ExperimentsModel? = nil, hooks: HooksSectionModel? = nil) {
    self.services = services
    self.store = store
    self.experiments = experiments
    self.hooks = hooks
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { chromium != nil && widevine != nil }

  public func prepare(_ place: SettingsPlace) async {
    let services = services
    let chromium = Task { await services.chromiumVersion() }
    let widevine = Task { await services.widevineVersion() }
    self.chromium = .some(await chromium.value)
    self.widevine = .some(await widevine.value)
  }

  public func view(_ place: SettingsPlace) -> AnyView { AnyView(AdvancedPane(model: self)) }

  static let batterySaverDescriptions = [
    "lowBattery": "At 20% or less, or in Low Power Mode, pauses busy background tabs and slows animations.",
    "unplugged": "On battery or in Low Power Mode, pauses busy background tabs and slows animations.",
    "never": "Background tabs and animations run at full speed on battery.",
  ]

  var widevineDescription: String {
    guard case .some(let loaded) = widevine else { return "Checking…" }
    if case .some(.some(let version)) = loaded, version != "0.0.0.0" { return "Version \(version)" }
    return "Not available in this build: video that needs it, like Netflix or Disney+, won't play."
  }

  static func serverNote(on: Bool, server: CliServerStatus?) -> String {
    if server?.state == "external" { return "This instance already has a command-line DevTools port." }
    if let reason = server?.reason { return reason }
    if on, server?.state == "on" {
      if let connections = server?.connections, connections > 0 {
        return "Connected now: \(connections == 1 ? "1 session" : "\(connections) sessions")."
      }
      return "On. Nothing is connected."
    }
    return "The command can read and act in pages you're signed in to. It stays on after you quit."
  }

  static func describeInstall(_ state: CliInstallState) -> String {
    if state.installing { return state.step.map { "Installing (\($0))…" } ?? "Installing…" }
    if let error = state.error { return error }
    if let version = state.installedVersion { return state.binPath.map { "Installed at \($0)" } ?? "Version \(version) is installed." }
    return "Not installed."
  }

}

struct AdvancedPane: View {
  @Environment(\.settingsContext) private var context
  let model: AdvancedPaneModel

  var body: some View {
    let store = model.store
    let services = model.services
    let batterySaver = store.string("batterySaverWhen")
    SettingsForm {
      SettingsSection("Browsing") {
        SettingToggle("advanced.showFullUrl", key: "showFullUrl")
        SettingToggle("advanced.warnMovingTabs", key: "warnBeforeMovingTabsToProfile")
        SettingToggle("advanced.bookmarksImport", key: "hideBookmarksBarImport", inverted: true)
        SettingRow("advanced.developerMode") {
          Button("Reset Developer Mode Sites") { services.resetDeveloperModeSites() }
            .disabled(!services.hasDeveloperModeChanges(store.settingValue("developerMode")))
        }
      }

      SettingsSection("Performance") {
        SettingRow("advanced.batterySaver", description: AdvancedPaneModel.batterySaverDescriptions[batterySaver].map(RowDescription.text) ?? .index) {
          SettingPicker(
            [SettingOption("lowBattery", "When battery is low"), SettingOption("unplugged", "When unplugged"), SettingOption("never", "Never")],
            selection: store.choice("batterySaverWhen")
          )
        }
      }

      SettingsSection("Data") {
        SettingRow("advanced.history") {
          Button("Show History") { services.openInternalPage("history") }
        }
        SettingRow("advanced.downloads") {
          Button("Show Downloads") { services.openInternalPage("downloads") }
        }
      }

      SettingsSection("Command line") {
        let on = store.bool("cliControl")
        SettingRow("advanced.cliControl", description: AdvancedPaneModel.serverNote(on: on, server: services.cliServer)) {
          Toggle("", isOn: store.toggle("cliControl"))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
        }
        let install = services.cliInstall
        SettingsAnchor("advanced.cliInstall") {
          LabeledContent {
            Button(install.installing ? "Installing…" : install.installedVersion != nil ? "Reinstall" : "Install") { services.installCli() }
              .disabled(install.installing)
          } label: {
            Text(context?.index.entry("advanced.cliInstall")?.title ?? "")
            Text(AdvancedPaneModel.describeInstall(install))
              .foregroundStyle(install.error != nil && !install.installing ? Color.red : Color.secondary)
              .textSelection(.enabled)
          }
        }
      }

      if let hooks = model.hooks {
        HooksSection(model: hooks)
      }

      SettingsSection("Web engine") {
        let chromium: String? = model.chromium ?? nil
        SettingRow("advanced.chromium", description: chromium != nil ? "SolaraCore" : nil) {
          Text(chromium ?? "…")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        SettingRow("advanced.widevine", description: .text(model.widevineDescription))
      }

      SettingsSection("Licenses") {
        SettingRow("advanced.licenses") {
          Button("Show Licenses") { services.openURL("chrome://credits") }
        }
      }

      if let experiments = model.experiments, experiments.revealed {
        ExperimentsSection(model: experiments)
      }
    }
    .onAppear { model.experiments?.reveal(optionHeld: NSEvent.modifierFlags.contains(.option)) }
  }
}
