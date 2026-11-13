import AppKit
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
final class StoreSettingsSource: SettingsStoreSource {
  let model: SettingsModel

  init(model: SettingsModel) {
    self.model = model
  }

  func settingValue(_ key: String) -> JSONValue? { model.value(key) }

  func updateSettings(_ patch: JSONObject) { model.update(patch) }

  var profiles: [SolaraUI.SettingsProfile] {
    model.profiles.map { SolaraUI.SettingsProfile(id: $0.id, name: $0.name, engineProfile: $0.engineProfile) }
  }

  var topTabLayout: Bool { model.value("tabLayout")?.string == "top" }

  func chooseTabLayout(_ layout: String) {
    SettingsJS.shared.fire("tabs.chooseLayout", layout)
  }

  func fileSource(_ key: String) -> String? { model.settings.fileSource(key) }

  func fileSource(shortcut id: String) -> String? { model.settings.fileSource(shortcut: id) }

  func fileTheme(profile id: String) -> String? {
    guard let theme = model.profiles.first(where: { $0.id == id })?.fileTheme else { return nil }
    let folder = ConfigDirectory.shared?.location.display(ConfigThemeFile.file(theme.name)) ?? ConfigThemeFile.file(theme.name)
    return "\(folder), named in \(theme.source)"
  }
}

final class SettingsHostingController: NSHostingController<SettingsWindowView> {
  override func viewWillAppear() {
    super.viewWillAppear()
    if let window = view.window { NativeSettingsWindow.observePairingLifecycle(window) }
    view.window?.titleVisibility = .visible
    view.window?.titlebarAppearsTransparent = false
    guard view.window?.toolbar == nil else { return }
    sceneBridgingOptions = []
    sceneBridgingOptions = [.toolbars]
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(nil)
    guard let search = NativeSettingsWindow.makeContext()?.search, !search.query.isEmpty else { return }
    search.requestFocus()
  }
}

@MainActor
enum NativeSettingsWindow {
  static let windowId = "settings"
  private static var context: SettingsContext?
  private static var pairingCloseObserver: NSObjectProtocol?
  private static weak var observedPairingWindow: NSWindow?

  static func observePairingLifecycle(_ window: NSWindow) {
    if context?.navigation.pane == .sync { (context?.panes[.sync] as? SyncPaneModel)?.pairingSurfaceAvailable(to: window) }
    guard observedPairingWindow !== window else { return }
    if let pairingCloseObserver { NotificationCenter.default.removeObserver(pairingCloseObserver) }
    observedPairingWindow = window
    pairingCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
      MainActor.assumeIsolated { pairingSurfaceRemoved() }
    }
  }

  static func pairingSurfaceRemoved() {
    (context?.panes[.sync] as? SyncPaneModel)?.pairingSurfaceRemoved()
    #if DEBUG
    SettingsDev.destroyPairingFixture()
    #endif
  }

  nonisolated static var enabled: Bool {
    NativeSettingsHandle.active
  }

  static func install() {
    SettingsProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
    NativeOnboarding.register()
    NativeAppStartup.shared.install()
    ShellLiveNotifications.silencesSite = { directory, origin in
      NativeStoreHandle.store?.silencesNotifications(profileDirectory: directory, origin: origin) ?? false
    }
    SettingsPrewarm.schedule()
    NativeCliControl.shared.startWhenReady()
    NativeAppIntegration.shared.startWhenReady()
    NativeMemoryTrim.shared.startWhenReady()
    NativeProfileWarmup.shared.startWhenReady()
    NativeUserScripts.shared.startWhenReady()
    NativeSiteControls.shared.startWhenReady()
    WindowHost.makeAuxController = { id, kind in
      if kind == NativeImportWindow.kind { return NativeImportWindow.makeController() }
      guard kind == "settings" else { return nil }
      return controller() ?? unavailableController()
    }
  }

  static func unavailableController() -> NSViewController? {
    guard !NativeSettingsHandle.active, let failure = NativeSettingsHandle.unavailable else { return nil }
    let view = StoreUnavailableView(
      failure: failure, appName: Bundle.main.productName, quit: { NSApp.terminate(nil) },
      showDataFolder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    return NSHostingController(rootView: view)
  }

  private static var built: SettingsHostingController?
  static var isBuilt: Bool { built != nil }
  static var window: NSWindow? { built?.view.window }

  static func controller() -> SettingsHostingController? {
    if let built { return built }
    guard enabled, let context = makeContext() else { return nil }
    let made = SettingsHostingController(rootView: SettingsWindowView(context: context))
    made.sceneBridgingOptions = [.toolbars]
    built = made
    return made
  }

  static func makeContext() -> SettingsContext? {
    if let context { return context }
    guard let model = NativeSettingsHandle.model else { return nil }
    let store = StoreSettingsSource(model: model)
    let made = SettingsContext(appName: Bundle.main.productName, liquidGlass: liquidGlass, store: store)
    #if DEBUG
    let priorNavigation = made.navigation.willNavigate
    made.navigation.willNavigate = { old, next in
      priorNavigation(old, next)
      if old.pane == .sync && old != next { SettingsDev.destroyPairingFixture() }
    }
    #endif
    made.favicons = SettingsFavicons(displayHost: SettingsAdapters.displayHost, bundled: bundledSiteIcon) { url, profile in await SettingsAdapters.favicon(url: url, profile: profile) }
    made.profileForPane = { pane, current in
      guard pane == .extensions else { return nil }
      if current.pane == .extensions, let profile = current.profileId { return profile }
      return SettingsJS.shared.latestValue("extensions.defaultProfile") as? String
    }
    made.onPaneAppear = { place in
      guard !SettingsPrewarm.warming else { return }
      SettingsTimings.paneAppeared(place.pane.rawValue)
      SettingsDev.paneAppeared(place.pane.rawValue)
    }
    SettingsAdapters.register(made, store: store)
    context = made
    return made
  }

  static var liquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  static func bundledSiteIcon(_ name: String) -> NSImage? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("assets/assets/site-icons/\(name).png") else { return nil }
    return NSImage(contentsOf: url)
  }

  static func navigate(pane: String?, profileId: String?, detail: String?) {
    guard let context = makeContext(), let pane, let target = SettingsPane(rawValue: pane) else { return }
    SettingsTimings.navigating(pane)
    context.navigation.go(target, profileId: profileId, detail: detail)
  }

  static func focusSearch() {
    makeContext()?.search.requestFocus()
  }
}
