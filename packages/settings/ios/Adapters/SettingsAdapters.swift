import AppKit
import SolaraCore
import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraUI

@MainActor
enum SettingsAdapters {
  static func register(_ context: SettingsContext, store: StoreSettingsSource) {
    context.panes[.general] = GeneralPaneModel(services: GeneralAdapter(), store: store)
    context.panes[.tabs] = TabsPaneModel(store: store)
    context.panes[.appearance] = AppearancePaneModel(services: AppearanceAdapter(), store: store)
    context.panes[.search] = SearchEnginePaneModel(services: SearchEngineAdapter(model: store.model), store: store)
    context.panes[.engines] = EnginesPaneModel(services: EnginesAdapter(model: store.model), store: store)
    context.panes[.advanced] = AdvancedPaneModel(services: AdvancedAdapter(model: store.model), store: store, experiments: ExperimentsModel(), hooks: NativeHooks.shared.sectionModel())
    context.panes[.about] = AboutPaneModel(services: AboutAdapter())
    context.panes[.privacy] = PrivacyPaneModel(services: PrivacyAdapter(), store: store)
    context.panes[.passwords] = PasswordsPaneModel(services: PasswordsAdapter(), store: store)
    context.panes[.autofill] = AutofillPaneModel(services: AutofillAdapter(), store: store)
    context.panes[.extensions] = ExtensionsPaneModel(services: ExtensionsAdapter(), store: store)
    context.panes[.shortcuts] = ShortcutsPaneModel(services: ShortcutsAdapter(), store: store)
    context.panes[.profiles] = ProfilesPaneModel(services: ProfilesAdapter(store: store), store: store, safeMode: SolaraCoreHost.safeMode)
    #if DEBUG
    context.panes[.sync] = SyncPairingFixturePane.select(environment: ProcessInfo.processInfo.environment) {
      SyncPaneModel(services: SyncAdapter())
    }
    #else
    context.panes[.sync] = SyncPaneModel(services: SyncAdapter())
    #endif
    let live = LiveAdapter()
    context.panes[.liveFolders] = LiveFoldersPaneModel(services: live, store: store)
    context.panes[.calendar] = CalendarPaneModel(services: live)
  }

  static func displayHost(_ host: String) -> String { SolaraOmnibox.displayHost(host) }

  static func favicon(url: String, profile: String?) async -> NSImage? {
    await NativeHistoryCatalog.favicon(page: url, profileId: profile ?? "default", dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
  }

  static func image(_ uri: String?) -> NSImage? {
    guard let uri, !uri.isEmpty else { return nil }
    if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
      let payload = String(uri[uri.index(after: comma)...])
      return Data(base64Encoded: payload).flatMap(NSImage.init(data:))
    }
    if let url = URL(string: uri), url.isFileURL { return NSImage(contentsOf: url) }
    if uri.hasPrefix("/") { return NSImage(contentsOfFile: uri) }
    return nil
  }

  @discardableResult
  static func js(_ name: String, _ args: Any...) async -> Any? {
    do {
      return try await SettingsJS.shared.invoke(name, args)
    } catch {
      NSLog("[settings] %@ failed: %@", name, String(describing: error))
      return nil
    }
  }

  static func jsThrowing(_ name: String, _ args: Any...) async throws -> Any? {
    try await SettingsJS.shared.invoke(name, args)
  }

  static func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
  func bool(_ key: String) -> Bool? { self[key] as? Bool }
  func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
  func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
  func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
  func list(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
  func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
  func date(_ key: String) -> Date? { double(key).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

func jsonArg(_ value: String?) -> Any { value ?? NSNull() }
func jsonArg(_ value: Bool?) -> Any { value ?? NSNull() }
