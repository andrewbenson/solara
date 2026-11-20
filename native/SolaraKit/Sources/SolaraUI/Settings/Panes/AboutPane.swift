import AppKit
import Darwin
import Observation
import SwiftUI

public struct UpdaterState: Sendable, Equatable {
  public var configured: Bool
  public var automaticChecks: Bool
  public var automaticDownloads: Bool
  public var canCheck: Bool
  public var sessionInProgress: Bool
  public var lastCheck: Date?
  public var version: String
  public var displayVersion: String?
  public var channel: String?

  public init(configured: Bool, automaticChecks: Bool, automaticDownloads: Bool, canCheck: Bool, sessionInProgress: Bool, lastCheck: Date?, version: String, displayVersion: String? = nil, channel: String? = nil) {
    self.configured = configured
    self.automaticChecks = automaticChecks
    self.automaticDownloads = automaticDownloads
    self.canCheck = canCheck
    self.sessionInProgress = sessionInProgress
    self.lastCheck = lastCheck
    self.version = version
    self.displayVersion = displayVersion
    self.channel = channel
  }
}

public struct AboutInfo: Equatable, Sendable {
  public var appVersion: String
  public var build: String
  public var chromiumVersion: String?
  public var osVersion: String
  public var architecture: String
  public var copyright: String?
  public var upstreamCredit: String?
  public var releaseRepo: String?

  public init(appVersion: String, build: String, chromiumVersion: String?, osVersion: String, architecture: String, copyright: String?, upstreamCredit: String?, releaseRepo: String?) {
    self.appVersion = appVersion
    self.build = build
    self.chromiumVersion = chromiumVersion
    self.osVersion = osVersion
    self.architecture = architecture
    self.copyright = copyright
    self.upstreamCredit = upstreamCredit
    self.releaseRepo = releaseRepo
  }

  public static func read(app bundle: Bundle = .main, releaseRepo: String? = nil) -> AboutInfo {
    let engineBundle = bundle.privateFrameworksURL.flatMap { Bundle(url: $0.appendingPathComponent("Chromium Framework.framework")) }
    return AboutInfo(
      appVersion: infoString(bundle, "CFBundleShortVersionString") ?? "",
      build: infoString(bundle, "CFBundleVersion") ?? "",
      chromiumVersion: engineBundle.flatMap { infoString($0, "CFBundleShortVersionString") },
      osVersion: osVersion(),
      architecture: architecture(),
      copyright: infoString(bundle, "ACCopyright"),
      upstreamCredit: infoString(bundle, "ACUpstreamCredit"),
      releaseRepo: releaseRepo
    )
  }

  static func infoString(_ bundle: Bundle, _ key: String) -> String? {
    let value = (bundle.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
    return value.isEmpty || value.hasPrefix("$(") ? nil : value
  }

  static func osVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let number = version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)" : "\(version.majorVersion).\(version.minorVersion)"
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
    let build = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    return build.isEmpty ? number : "\(number) (\(build))"
  }

  static func architecture() -> String {
    #if arch(arm64)
      "Apple silicon (arm64)"
    #else
      "Intel (x86_64)"
    #endif
  }
}

@MainActor
public protocol AboutServices: AnyObject {
  var aboutInfo: AboutInfo { get }
  func updaterState() async -> UpdaterState?
  func setAutomaticUpdateChecks(_ on: Bool) async
  func setAutomaticUpdateDownloads(_ on: Bool) async
  func setUpdateChannel(_ channel: String) async
  func checkForUpdates() async
  var updateChecksNote: String? { get }
  func copyText(_ text: String)
  func openURL(_ url: String)
  func reportBug()
}

@MainActor
@Observable
public final class AboutPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: AboutServices
  var updater: UpdaterState??
  var copied = false

  public init(services: AboutServices) {
    self.services = services
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { updater != nil }

  public func prepare(_ place: SettingsPlace) async {
    updater = .some(await services.updaterState())
  }

  public func view(_ place: SettingsPlace) -> AnyView { AnyView(AboutPane(model: self)) }

  func refreshUpdater() async { updater = .some(await services.updaterState()) }

  func setUpdater(_ change: (inout UpdaterState) -> Void) {
    guard case .some(.some(var state)) = updater else { return }
    change(&state)
    updater = .some(state)
  }

  var channel: String? {
    guard case .some(.some(let state)) = updater else { return nil }
    return state.channel
  }

  static func channelTitle(_ channel: String?) -> String? {
    switch channel {
    case "stable": "Stable"
    case "nightly": "Nightly"
    default: nil
    }
  }

  static func versionLine(_ info: AboutInfo, channel: String?) -> String {
    let build = info.build.isEmpty || info.build == info.appVersion ? "" : " (\(info.build))"
    let channel = channelTitle(channel).map { ", \($0)" } ?? ""
    return "\(info.appVersion)\(build)\(channel)"
  }

  static func osLine(_ info: AboutInfo) -> String {
    "\(info.osVersion), \(info.architecture)"
  }

  static func report(_ info: AboutInfo, app: String, channel: String?) -> String {
    var lines = ["\(app) \(versionLine(info, channel: channel))"]
    if let chromium = info.chromiumVersion { lines.append("Chromium \(chromium)") }
    lines.append("macOS \(osLine(info))")
    return lines.joined(separator: "\n")
  }

  static func copyrightLine(_ info: AboutInfo) -> String? {
    let parts = [info.copyright, info.upstreamCredit].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  func copy(app: String) {
    services.copyText(Self.report(services.aboutInfo, app: app, channel: channel))
    copied = true
  }
}

struct AboutPane: View {
  @Environment(\.settingsContext) private var context
  let model: AboutPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    let info = model.services.aboutInfo
    SettingsForm {
      SettingsSection(app) {
        SettingRow("about.version", description: RowDescription.none) {
          Text(AboutPaneModel.versionLine(info, channel: model.channel))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        SettingRow("about.chromium", description: RowDescription.none) {
          Text(info.chromiumVersion ?? "…")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        SettingRow("about.macOS", description: RowDescription.none) {
          Text(AboutPaneModel.osLine(info))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        SettingRow("about.copy") {
          Button(model.copied ? "Copied" : "Copy") { model.copy(app: app) }
        }
        if info.releaseRepo != nil {
          SettingRow("about.reportBug") {
            Button("Report a Bug…") { model.services.reportBug() }
          }
        }
      }

      UpdatesSection(model: model)

      SettingsSection("License") {
        SettingRow("about.license") {
          if let repo = info.releaseRepo {
            Button("Show License") { model.services.openURL("https://github.com/\(repo)/blob/v\(info.appVersion)/LICENSE") }
          }
        }
        if let repo = info.releaseRepo {
          SettingRow("about.source") {
            Button("Show on GitHub") { model.services.openURL("https://github.com/\(repo)/tree/v\(info.appVersion)") }
          }
        }
        if let line = AboutPaneModel.copyrightLine(info) {
          SettingRow("about.copyright", description: line) {
            if let repo = info.releaseRepo {
              Button("Show Credits") { model.services.openURL("https://github.com/\(repo)/blob/v\(info.appVersion)/NOTICE") }
            }
          }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refreshUpdater() }
    }
    .task(id: model.copied) {
      guard model.copied else { return }
      try? await Task.sleep(for: .seconds(2))
      model.copied = false
    }
  }
}

struct UpdatesSection: View {
  @Environment(\.settingsContext) private var context
  let model: AboutPaneModel

  var body: some View {
    if case .some(.some(let state)) = model.updater {
      let app = context?.appName ?? ""
      let ready = state.configured
      SettingsSection("Updates", description: ready ? nil : "Updates aren't set up for this build.") {
        SettingRow("about.updateChecks", description: model.services.updateChecksNote) {
          Toggle("", isOn: Binding(
            get: { ready && state.automaticChecks },
            set: { on in
              model.setUpdater { $0.automaticChecks = on }
              Task { await model.services.setAutomaticUpdateChecks(on); await model.refreshUpdater() }
            }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
          .disabled(!ready)
        }
        SettingRow("about.autoUpdate") {
          Toggle("", isOn: Binding(
            get: { ready && state.automaticChecks && state.automaticDownloads },
            set: { on in
              model.setUpdater { $0.automaticDownloads = on }
              Task { await model.services.setAutomaticUpdateDownloads(on); await model.refreshUpdater() }
            }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
          .disabled(!ready || !state.automaticChecks)
        }
        if let channel = state.channel {
          SettingRow("about.updateChannel") {
            SettingPicker(
              [SettingOption("stable", "Stable"), SettingOption("nightly", "Nightly")],
              selection: Binding(get: { channel }, set: { next in
                model.setUpdater { $0.channel = next }
                Task { await model.services.setUpdateChannel(next); await model.refreshUpdater() }
              })
            )
            .disabled(!ready)
          }
        }
        SettingRow(
          "about.checkNow",
          title: "\(app) \(state.displayVersion ?? state.version)",
          description: ready ? Self.lastCheck(state.lastCheck) : nil
        ) {
          Button("Check Now") {
            Task { await model.services.checkForUpdates(); await model.refreshUpdater() }
          }
          .disabled(ready && (!state.canCheck || state.sessionInProgress))
        }
      }
    }
  }

  static func lastCheck(_ date: Date?) -> String {
    guard let date else { return "Not checked yet." }
    return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
  }
}
