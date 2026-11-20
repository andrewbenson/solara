import AppKit
import Observation
import SwiftUI

public enum PasskeyAccessStatus: String, Sendable {
  case entitlementRequired
  case deviceNotConfigured
  case notDetermined
  case authorized
  case denied
}

public struct PasskeyAccess: Equatable, Sendable {
  public var entitled: Bool
  public var status: PasskeyAccessStatus

  public init(entitled: Bool, status: PasskeyAccessStatus) {
    self.entitled = entitled
    self.status = status
  }
}

@MainActor
public protocol EnginesServices: AnyObject {
  func setWebsiteEngine(_ site: String, _ engine: String?)
  func site(forTyped address: String) -> String?
  func passkeyAccess() async -> PasskeyAccess?
  func requestPasskeyAccess() async -> PasskeyAccess?
  func openPasskeySystemSettings()
}

@MainActor
@Observable
public final class EnginesPaneModel: SettingsPaneProvider {
  public static let recommendedEngine = "chromium"
  static let engineOptions = [SettingOption("chromium", "Chromium"), SettingOption("webkit", "WebKit")]

  @ObservationIgnored let services: EnginesServices
  @ObservationIgnored let store: SettingsStoreSource
  var passkeys: PasskeyAccess?
  var askingPasskeys = false

  public init(services: EnginesServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { true }
  public func prepare(_ place: SettingsPlace) async {}
  public func view(_ place: SettingsPlace) -> AnyView { AnyView(EnginesPane(model: self)) }

  var defaultEngine: String { store.string("pageEngine") == "webkit" ? "webkit" : "chromium" }

  var rules: [(site: String, engine: String)] {
    let object = store.settingValue("websiteEngines")?.object
    let sites = object?.keys ?? []
    return sites
      .compactMap { site in object?[site]?.string.map { (site, $0) } }
      .sorted { Self.siteLabel($0.site).localizedCompare(Self.siteLabel($1.site)) == .orderedAscending }
  }

  static func siteLabel(_ site: String) -> String {
    site.hasPrefix("https://") ? String(site.dropFirst("https://".count)) : site
  }

  func refreshPasskeys() async {
    passkeys = await services.passkeyAccess()
  }

  func askPasskeys() async {
    askingPasskeys = true
    passkeys = await services.requestPasskeyAccess()
    askingPasskeys = false
  }

  static func passkeyStatus(_ status: PasskeyAccessStatus, app: String) -> String? {
    switch status {
    case .entitlementRequired: nil
    case .deviceNotConfigured: "Set up a passkey app in System Settings, then reopen \(app)."
    case .notDetermined: "Allow \(app) to use passkeys saved on this Mac in WebKit and Chromium."
    case .authorized: "Websites can use the passkeys saved on this Mac, in WebKit and Chromium pages."
    case .denied: "Allow \(app) in System Settings › Privacy & Security › Passkeys Access for Web Browsers."
    }
  }

  func saveRule(address: String, engine: String, replacing site: String?) -> String? {
    let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let target = services.site(forTyped: typed) else { return "Enter a website address, like netflix.com." }
    if let site, site != target { services.setWebsiteEngine(site, nil) }
    services.setWebsiteEngine(target, engine)
    return nil
  }
}

enum RuleSheetTarget: Identifiable {
  case add
  case edit(site: String, engine: String)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let site, _): site
    }
  }
}

struct EnginesPane: View {
  @Environment(\.settingsContext) private var context
  let model: EnginesPaneModel
  @State private var sheet: RuleSheetTarget?

  var body: some View {
    let store = model.store
    let engine = model.defaultEngine
    let rules = model.rules
    SettingsForm {
      SettingsSection("Default engine") {
        SettingRow("engines.defaultEngine") {
          SettingPicker(EnginesPaneModel.engineOptions, selection: Binding(get: { engine }, set: { store.set("pageEngine", $0) }))
        }
        SettingRow("engines.recommendedDefault") {
          Button("Use Recommended") { store.set("pageEngine", EnginesPaneModel.recommendedEngine) }
            .disabled(engine == EnginesPaneModel.recommendedEngine)
        }
        if engine == "chromium" {
          SettingToggle("engines.protectedVideo", key: "protectedVideoInWebKit")
        }
      }

      SettingsSection(anchor: "engines.websiteRules") {
        Button("Add Website Rule…", systemImage: "plus") { sheet = .add }
      } content: {
        if rules.isEmpty {
          SettingRow(title: "No website rules", description: .text("Choose “Opens in” in a site's controls, or add a rule here."))
        } else {
          ForEach(rules, id: \.site) { rule in
            LabeledContent {
              HStack(spacing: 6) {
                SettingPicker(EnginesPaneModel.engineOptions, selection: Binding(get: { rule.engine }, set: { model.services.setWebsiteEngine(rule.site, $0) }))
                Button { sheet = .edit(site: rule.site, engine: rule.engine) } label: { Image(systemName: "pencil") }
                  .buttonStyle(.borderless)
                  .help("Edit")
                Button { model.services.setWebsiteEngine(rule.site, nil) } label: { Image(systemName: "trash") }
                  .buttonStyle(.borderless)
                  .help("Remove")
              }
            } label: {
              Label {
                Text(EnginesPaneModel.siteLabel(rule.site))
              } icon: {
                SettingsFavicon(url: rule.site)
              }
            }
          }
        }
      }

      SettingsSection("How engines differ") {
        SettingRow("engines.separateData")
        SettingRow("engines.chromiumOnly")
        PasskeysRow(model: model)
      }
    }
    .sheet(item: $sheet) { target in
      switch target {
      case .add: RuleSheet(model: model, site: nil, initialEngine: "webkit") { sheet = nil }
      case .edit(let site, let engine): RuleSheet(model: model, site: site, initialEngine: engine) { sheet = nil }
      }
    }
  }
}

struct PasskeysRow: View {
  @Environment(\.settingsContext) private var context
  let model: EnginesPaneModel

  var body: some View {
    Group {
      if let access = model.passkeys, access.entitled {
        SettingRow("engines.passkeys", description: EnginesPaneModel.passkeyStatus(access.status, app: context?.appName ?? "")) {
          if access.status == .notDetermined {
            Button("Allow Passkeys…") { Task { await model.askPasskeys() } }
              .disabled(model.askingPasskeys)
          }
          if access.status == .denied {
            Button("Open System Settings") { model.services.openPasskeySystemSettings() }
          }
        }
      } else {
        SettingRow("engines.passkeys")
      }
    }
    .task { await model.refreshPasskeys() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refreshPasskeys() }
    }
  }
}

struct RuleSheet: View {
  let model: EnginesPaneModel
  let site: String?
  let close: () -> Void
  @State private var address: String
  @State private var engine: String
  @State private var error: String?

  init(model: EnginesPaneModel, site: String?, initialEngine: String, close: @escaping () -> Void) {
    self.model = model
    self.site = site
    self.close = close
    _address = State(initialValue: site.map(EnginesPaneModel.siteLabel) ?? "")
    _engine = State(initialValue: initialEngine)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(site == nil ? "Add Website Rule" : "Edit Website Rule")
        .font(.system(size: 15, weight: .semibold))
      Text("A rule matches the site's address exactly: its scheme, host and port. Subdomains need their own rule.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
      SheetField(label: "Website", text: $address, placeholder: "netflix.com", contentType: .URL, submit: save)
      HStack(spacing: 10) {
        Text("Opens in")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        SettingPicker(EnginesPaneModel.engineOptions, selection: $engine)
      }
      .padding(.top, 12)
      if let error {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .padding(.top, 10)
      }
      HStack(spacing: 8) {
        if let site {
          Button("Remove", role: .destructive) {
            model.services.setWebsiteEngine(site, nil)
            close()
          }
        }
        Spacer()
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
        Button(site == nil ? "Add" : "Save", action: save)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: 440)
  }

  private func save() {
    if let message = model.saveRule(address: address, engine: engine, replacing: site) {
      error = message
      return
    }
    close()
  }
}
