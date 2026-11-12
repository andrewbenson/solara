import AppKit
import Observation
import SwiftUI

public enum FilterListCategory: String, Sendable, CaseIterable {
  case ads
  case trackers
  case cookies
  case annoyances
  case security
  case regional
}

public struct FilterList: Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var category: FilterListCategory
  public var enabled: Bool
  public var defaultOn: Bool
  public var filters: Int

  public init(id: String, title: String, category: FilterListCategory, enabled: Bool, defaultOn: Bool, filters: Int) {
    self.id = id
    self.title = title
    self.category = category
    self.enabled = enabled
    self.defaultOn = defaultOn
    self.filters = filters
  }
}

public struct ContentBlockerState: Sendable, Equatable {
  public var enabled: Bool
  public var version: String
  public var lists: [FilterList]
  public var allowedHosts: [String]
  public var networkFilters: Int?
  public var cosmeticFilters: Int?

  public init(enabled: Bool, version: String, lists: [FilterList], allowedHosts: [String], networkFilters: Int? = nil, cosmeticFilters: Int? = nil) {
    self.enabled = enabled
    self.version = version
    self.lists = lists
    self.allowedHosts = allowedHosts
    self.networkFilters = networkFilters
    self.cosmeticFilters = cosmeticFilters
  }
}

public enum SiteSettingType: String, Sendable, CaseIterable {
  case popups
  case camera
  case microphone
  case location
  case notifications
  case sound
  case autoplay
  case javascript
  case images
  case clipboard
  case automaticDownloads
  case cookies
  case midi
  case sensors
  case windowManagement
  case localFonts
  case idleDetection
  case storageAccess
  case fileSystem
  case keyboardLock
  case pointerLock
  case cameraPanTiltZoom
}

public enum SiteSettingValue: String, Sendable, CaseIterable {
  case `default`
  case allow
  case block
  case ask
}

public struct SiteSettingState: Sendable, Equatable {
  public var value: SiteSettingValue
  public var isDefault: Bool

  public init(value: SiteSettingValue, isDefault: Bool) {
    self.value = value
    self.isDefault = isDefault
  }
}

public struct ClearSiteDataResult: Sendable, Equatable {
  public var cookies: Int?
  public var storage: Bool

  public init(cookies: Int?, storage: Bool) {
    self.cookies = cookies
    self.storage = storage
  }
}

public struct ExternalAppAllowance: Sendable, Equatable, Identifiable {
  public var origin: String
  public var scheme: String
  public var app: String?
  public var icon: String?

  public var id: String { "\(origin)|\(scheme)" }

  public init(origin: String, scheme: String, app: String?, icon: String?) {
    self.origin = origin
    self.scheme = scheme
    self.app = app
    self.icon = icon
  }
}

@MainActor
public protocol PrivacyServices: AnyObject {
  func contentBlocker() async -> ContentBlockerState?
  func contentBlockerChanges() -> AsyncStream<Void>
  func setContentBlockerEnabled(_ on: Bool) async throws
  func setFilterListEnabled(_ id: String, enabled: Bool) async throws
  func setContentBlockerAllowed(host: String, allowed: Bool) async throws
  func siteSettingsOrigins(profile: String) async -> [String]
  func siteSettings(profile: String, origin: String) async -> [SiteSettingType: SiteSettingState]?
  func setSiteSetting(profile: String, origin: String, type: SiteSettingType, value: SiteSettingValue) async
  func resetSiteSettings(profile: String, origin: String) async
  func clearSiteData(profile: String, origin: String) async -> ClearSiteDataResult
  func externalAppAllowances(profile: String) async -> [ExternalAppAllowance]
  func removeExternalAppAllowance(profile: String, origin: String, scheme: String) async
  func zoomLevels(profile: String) async -> [String: Double]
  func setZoom(profile: String, host: String, zoom: Double) async
}

struct BlockerCategory: Identifiable {
  let id: FilterListCategory
  let toggleAnchor: String?
  let section: String

  static let all: [BlockerCategory] = [
    BlockerCategory(id: .ads, toggleAnchor: "privacy.blockAds", section: "Ad blockers"),
    BlockerCategory(id: .trackers, toggleAnchor: "privacy.blockTrackers", section: "Trackers"),
    BlockerCategory(id: .cookies, toggleAnchor: "privacy.blockCookieBanners", section: "Cookie banners"),
    BlockerCategory(id: .annoyances, toggleAnchor: nil, section: "Annoyances"),
    BlockerCategory(id: .security, toggleAnchor: nil, section: "Malware and scams"),
    BlockerCategory(id: .regional, toggleAnchor: nil, section: "Regional blockers"),
  ]
}

enum PrivacySheet: Identifiable {
  case filterLists
  case site(PrivacySiteModel)

  var id: String {
    switch self {
    case .filterLists: "filterLists"
    case .site(let site): "site \(site.profile) \(site.origin)"
    }
  }
}

@MainActor
@Observable
public final class PrivacyPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: PrivacyServices
  @ObservationIgnored let store: SettingsStoreSource
  var blockerLoaded = false
  var blocker: ContentBlockerState?
  var origins: [String: [String]] = [:]
  var appLinks: [String: [ExternalAppAllowance]] = [:]
  var zoom: [String: [String: Double]] = [:]
  var sitePermissionsProfileId: String
  var appLinksProfileId: String
  var zoomProfileId: String
  var sheet: PrivacySheet?
  var confirmingAdsOff = false
  @ObservationIgnored private var watchingBlocker: Task<Void, Never>?

  public init(services: PrivacyServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
    let profile = store.string("defaultProfileId")
    sitePermissionsProfileId = profile
    appLinksProfileId = profile
    zoomProfileId = profile
  }

  var defaultEngineProfile: String { store.engineProfile(store.string("defaultProfileId")) }
  var sitePermissionsProfile: String { store.engineProfile(sitePermissionsProfileId) }
  var appLinksProfile: String { store.engineProfile(appLinksProfileId) }
  var zoomProfile: String { store.engineProfile(zoomProfileId) }

  public func isLoaded(_ place: SettingsPlace) -> Bool {
    let profile = defaultEngineProfile
    return blockerLoaded && origins[profile] != nil && appLinks[profile] != nil && zoom[profile] != nil
  }

  public func prepare(_ place: SettingsPlace) async {
    watchBlocker()
    let profile = defaultEngineProfile
    let blocker = Task { await reloadBlocker() }
    let origins = Task { await loadOrigins(profile) }
    let appLinks = Task { await loadAppLinks(profile) }
    let zoom = Task { await loadZoom(profile) }
    await blocker.value
    await origins.value
    await appLinks.value
    await zoom.value
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(PrivacyPane(model: self))
  }

  func reloadBlocker() async {
    blocker = await services.contentBlocker()
    blockerLoaded = true
  }

  func watchBlocker() {
    guard watchingBlocker == nil else { return }
    let changes = services.contentBlockerChanges()
    watchingBlocker = Task { [weak self] in
      for await _ in changes {
        await self?.reloadBlocker()
      }
    }
  }

  func loadOrigins(_ profile: String) async { origins[profile] = await services.siteSettingsOrigins(profile: profile) }
  func loadAppLinks(_ profile: String) async { appLinks[profile] = await services.externalAppAllowances(profile: profile) }
  func loadZoom(_ profile: String) async { zoom[profile] = await services.zoomLevels(profile: profile) }

  static func categoryOn(_ state: ContentBlockerState, _ category: FilterListCategory) -> Bool {
    state.enabled && state.lists.contains { $0.category == category && $0.enabled }
  }

  func categoryOn(_ category: FilterListCategory) -> Bool {
    blocker.map { Self.categoryOn($0, category) } ?? false
  }

  static func categoryChanges(_ state: ContentBlockerState, _ category: FilterListCategory, on: Bool) -> (lists: [String], blockerEnabled: Bool?) {
    let lists = state.lists.filter { $0.category == category }
    let usual = lists.filter { $0.defaultOn || $0.enabled }
    let starters = usual.isEmpty ? lists.filter { $0.id.range(of: "easylist|fanboy", options: .regularExpression) != nil } : usual
    let targets = on ? (starters.isEmpty ? lists : starters) : lists.filter(\.enabled)
    let anyOn = BlockerCategory.all.contains { $0.id == category ? on : categoryOn(state, $0.id) }
    return (targets.map(\.id), anyOn == state.enabled ? nil : anyOn)
  }

  func requestCategory(_ category: FilterListCategory, on: Bool) {
    guard blocker != nil else { return }
    if !on && category == .ads {
      confirmingAdsOff = true
      return
    }
    Task { await setCategory(category, on: on) }
  }

  func setCategory(_ category: FilterListCategory, on: Bool) async {
    guard let state = blocker else { return }
    let changes = Self.categoryChanges(state, category, on: on)
    do {
      for id in changes.lists { try await services.setFilterListEnabled(id, enabled: on) }
      if let enabled = changes.blockerEnabled { try await services.setContentBlockerEnabled(enabled) }
    } catch {}
    await reloadBlocker()
  }

  func setList(_ list: FilterList, on: Bool) async {
    do {
      try await services.setFilterListEnabled(list.id, enabled: on)
      if on, let blocker, !blocker.enabled { try await services.setContentBlockerEnabled(true) }
    } catch {}
    await reloadBlocker()
  }

  #if DEBUG
  public func devSetFilterList(_ id: String, on: Bool) async -> Bool {
    await reloadBlocker()
    guard let list = blocker?.lists.first(where: { $0.id == id }) else { return false }
    sheet = .filterLists
    await setList(list, on: on)
    return blocker?.lists.first(where: { $0.id == id })?.enabled == on
  }
  #endif

  func blockAgain(_ host: String) async {
    try? await services.setContentBlockerAllowed(host: host, allowed: false)
    await reloadBlocker()
  }

  func openSite(_ origin: String) {
    let profile = sitePermissionsProfile
    let site = PrivacySiteModel(services: services, profile: profile, origin: origin) { [weak self] in
      await self?.loadOrigins(profile)
    }
    sheet = .site(site)
  }

  func removeAppLink(_ allowance: ExternalAppAllowance) async {
    let profile = appLinksProfile
    await services.removeExternalAppAllowance(profile: profile, origin: allowance.origin, scheme: allowance.scheme)
    await loadAppLinks(profile)
  }

  func resetZoom(_ host: String) async {
    let profile = zoomProfile
    await services.setZoom(profile: profile, host: host, zoom: 1)
    await loadZoom(profile)
  }

  static func withoutScheme(_ origin: String) -> String {
    origin.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
  }

  static func filtersText(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "filter" : "filters")"
  }

  static func listDescription(_ list: FilterList) -> String {
    list.defaultOn ? "\(filtersText(list.filters)) · On by default" : filtersText(list.filters)
  }

  static func rulesLoaded(_ state: ContentBlockerState) -> String {
    "\((state.networkFilters ?? 0).formatted()) network and \((state.cosmeticFilters ?? 0).formatted()) cosmetic rules loaded."
  }

  static func zoomText(_ level: Double) -> String {
    "\(Int((level * 100).rounded()))%"
  }

  static func appLinkDescription(_ allowance: ExternalAppAllowance) -> String {
    "Opens \(allowance.scheme): links in \(allowance.app ?? "an app that's no longer installed")"
  }
}

struct PrivacyPane: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: PrivacyPaneModel

  var body: some View {
    let app = context?.appName ?? ""
    SettingsForm {
      ContentBlockingSection(model: model)
      AllowedHostsSection(model: model)
      SitePermissionsSection(model: model)
      AppLinksSection(model: model)
      ZoomLevelsSection(model: model)
      if let blocker = model.blocker {
        Section {
        } footer: {
          Text(PrivacyPaneModel.rulesLoaded(blocker))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task {
      model.watchBlocker()
      await model.reloadBlocker()
    }
    .task(id: model.zoomProfile) {
      if model.zoom[model.zoomProfile] == nil { await model.loadZoom(model.zoomProfile) }
    }
    .alert("Turn Off Ad Blocker?", isPresented: $model.confirmingAdsOff) {
      Button("Turn Off") { Task { await model.setCategory(.ads, on: false) } }
      Button("Cancel", role: .cancel) { Task { await model.reloadBlocker() } }
    } message: {
      Text("\(app)'s Ad Blocker hides ads so pages load faster and feel cleaner.")
    }
    .sheet(item: $model.sheet) { sheet in
      switch sheet {
      case .filterLists: FilterListsSheet(model: model)
      case .site(let site): SiteSheet(model: site)
      }
    }
  }
}

struct ContentBlockingSection: View {
  let model: PrivacyPaneModel

  var body: some View {
    SettingsSection("Content blocking", description: "Built on EasyList and EasyPrivacy. Blocking happens on this Mac.") {
      ForEach(BlockerCategory.all.filter { $0.toggleAnchor != nil }) { category in
        SettingRow(category.toggleAnchor) {
          Toggle("", isOn: Binding(
            get: { model.categoryOn(category.id) },
            set: { model.requestCategory(category.id, on: $0) }
          ))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
          .disabled(model.blocker == nil)
        }
      }
      SettingRow("privacy.filterLists") {
        Button("Advanced…") { model.sheet = .filterLists }
          .disabled(model.blocker == nil)
      }
    }
  }
}

struct AllowedHostsSection: View {
  let model: PrivacyPaneModel

  var body: some View {
    if let hosts = model.blocker?.allowedHosts, !hosts.isEmpty {
      SettingsSection("Sites without blocking", description: "Turned off from a site's controls. Blocking applies to subdomains too.") {
        ForEach(hosts, id: \.self) { host in
          PrivacyIconRow(title: host) {
            SettingsFavicon(url: "https://\(host)", profile: model.defaultEngineProfile)
          } control: {
            Button("Block Again") { Task { await model.blockAgain(host) } }
          }
        }
      }
    }
  }
}

struct PrivacyProfilePicker: View {
  let model: PrivacyPaneModel
  @Binding var selection: String

  var body: some View {
    let profiles = model.store.profiles
    if profiles.count > 1 {
      SettingPicker(profiles.map { SettingOption($0.id, $0.name) }, selection: $selection)
    }
  }
}

struct SitePermissionsSection: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: PrivacyPaneModel

  var body: some View {
    let profile = model.sitePermissionsProfile
    SettingsSection(
      description: context?.index.entry("privacy.sitePermissions")?.displayCaption,
      anchor: "privacy.sitePermissions"
    ) {
      PrivacyProfilePicker(model: model, selection: $model.sitePermissionsProfileId)
    } content: {
      if let origins = model.origins[profile] {
        if origins.isEmpty {
          SettingRow(title: "No sites yet", description: "Sites appear here after you allow or block something for them.") { EmptyView() }
        } else {
          ForEach(origins, id: \.self) { origin in
            Button { model.openSite(origin) } label: {
              PrivacyIconRow(title: PrivacyPaneModel.withoutScheme(origin)) {
                SettingsFavicon(url: origin, profile: profile)
              } control: {
                Image(systemName: "chevron.right")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      } else {
        PrivacyPlaceholderRow()
      }
    }
    .task(id: profile) {
      if model.origins[profile] == nil { await model.loadOrigins(profile) }
    }
  }
}

struct AppLinksSection: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: PrivacyPaneModel

  var body: some View {
    let profile = model.appLinksProfile
    SettingsSection(
      description: context?.index.entry("privacy.appLinks")?.displayCaption,
      anchor: "privacy.appLinks"
    ) {
      PrivacyProfilePicker(model: model, selection: $model.appLinksProfileId)
    } content: {
      if let allowed = model.appLinks[profile] {
        if allowed.isEmpty {
          SettingRow(title: "No apps yet", description: "Check “Always allow” when a site opens an app, and it shows up here.") { EmptyView() }
        } else {
          ForEach(allowed) { allowance in
            PrivacyIconRow(title: PrivacyPaneModel.withoutScheme(allowance.origin), description: PrivacyPaneModel.appLinkDescription(allowance)) {
              if let icon = PrivacyImages.dataURI(allowance.icon) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
              } else {
                SettingsFavicon(url: allowance.origin, profile: profile)
              }
            } control: {
              Button("Remove") { Task { await model.removeAppLink(allowance) } }
            }
          }
        }
      } else {
        PrivacyPlaceholderRow()
      }
    }
    .task(id: profile) {
      if model.appLinks[profile] == nil { await model.loadAppLinks(profile) }
    }
  }
}

struct ZoomLevelsSection: View {
  @Bindable var model: PrivacyPaneModel

  var body: some View {
    let profile = model.zoomProfile
    let levels = model.zoom[profile] ?? [:]
    let hosts = levels.keys.sorted()
    if !hosts.isEmpty {
      SettingsSection("Zoom levels") {
        PrivacyProfilePicker(model: model, selection: $model.zoomProfileId)
      } content: {
        ForEach(hosts, id: \.self) { host in
          PrivacyIconRow(title: host, description: PrivacyPaneModel.zoomText(levels[host] ?? 1)) {
            SettingsFavicon(url: "https://\(host)", profile: profile)
          } control: {
            Button("Reset") { Task { await model.resetZoom(host) } }
          }
        }
      }
    }
  }
}
