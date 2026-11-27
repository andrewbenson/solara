import AppKit
import Foundation
internal import SolaraBridgeCore
internal import SolaraModel
internal import SolaraOmnibox
public import SolaraPersistence
internal import SolaraStore
internal import SolaraUI

public final class NativeStore: Sendable {
  nonisolated(unsafe) public private(set) static var ownsWorkspace = false
  nonisolated(unsafe) public private(set) static var safeMode = false
  nonisolated(unsafe) public private(set) static var safeModeAfterFailedLaunches = false
  nonisolated(unsafe) public private(set) static var safeModeRequestedAfterFailedOpen = false

  static func config(_ folder: URL) -> StoreConfig {
    var config = StoreConfig()
    config.safeMode = safeMode
    config.nativePrivateSessionEffects = true
    config.handOffPinsImmediately = false
    config.earlyLaunchTab = earlyLaunchTabSwitch(folder)
    return config
  }

  static func earlyLaunchTabSwitch(_ folder: URL) -> Bool {
    EarlyLaunchTabProvider.resolve(
      environment: ProcessInfo.processInfo.environment["SOLARA_SWITCHES"],
      cache: try? Data(contentsOf: folder.appending(path: "switches-cache.json")))
  }

  nonisolated(unsafe) public private(set) static var shared: NativeStore?
  nonisolated(unsafe) public private(set) static var unavailableReason: String?
  nonisolated(unsafe) public private(set) static var refusedSession: String?
  nonisolated(unsafe) public private(set) static var handedOff = false
  nonisolated(unsafe) static var folderLock: FolderLock?

  let profileDataCleanup: NativeProfileDataCleanup
  let privateSessionEffects: NativePrivateSessionEffects
  let tabSleep: NativeTabSleep
  let keepAwakeSites: NativeKeepAwakeSites
  let host: StoreHost
  var bridge: StoreBridge { host.bridge }
  var writer: PersistenceWriter? { host.writer }
  let launch: SafeLaunch
  let caches: NativeCacheFeeds
  let strips: StripTransport

  @MainActor
  init(host: StoreHost, launch: SafeLaunch, folder: URL) {
    profileDataCleanup = NativeProfileDataCleanup(store: host.bridge.store)
    privateSessionEffects = NativePrivateSessionEffects(store: host.bridge.store)
    tabSleep = NativeTabSleep(store: host.bridge.store)
    keepAwakeSites = NativeKeepAwakeSites(store: host.bridge.store, folder: folder)
    self.host = host
    let bridge = host.bridge
    self.launch = launch
    caches = NativeCacheFeeds(store: bridge.store, folder: folder)
    strips = StripTransport(store: bridge.store, engine: SolaraCoreStripEngine(), trouble: { NSLog("[store] %@", $0) })
  }

  public static func productName() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
    return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Solara" : name
  }

  static func dataFolder() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let scratch = environment["SOLARA_DATA_DIR"], !scratch.isEmpty {
      let path = scratch.hasPrefix("/") ? scratch : FileManager.default.currentDirectoryPath + "/" + scratch
      return URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true)
    }
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    return support.appending(path: Bundle.main.bundleIdentifier ?? "Solara", directoryHint: .isDirectory)
  }

  static let handOffWait: TimeInterval = 15

  static func chromeSingletonPid(_ folder: URL) -> pid_t? {
    let link = folder.appending(path: "Chromium/SingletonLock").path
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link), let dash = target.lastIndex(of: "-") else { return nil }
    return pid_t(target[target.index(after: dash)...])
  }

  static func waitForHolder(_ folder: URL) throws -> FolderLock? {
    let data = DataFolder(url: folder)
    let deadline = Date().addingTimeInterval(handOffWait)
    while Date() < deadline {
      if let lock = try FolderLock.acquire(data) { return lock }
      if let holder = FolderLock.holder(data), chromeSingletonPid(folder) == holder {
        handedOff = true
        unavailableReason = "another instance (pid \(holder)) is using this data folder"
        NSLog("[store] %@; handing this launch to it", unavailableReason ?? "")
        return nil
      }
      usleep(100_000)
    }
    NSLog("[store] the instance holding this data folder never became the browser; quitting")
    if let holder = FolderLock.holder(data) { NSRunningApplication(processIdentifier: holder)?.activate() }
    exit(0)
  }

  @MainActor
  @discardableResult
  public static func launchAtStartup() -> Bool {
    RNPageReports.install(issuer: nil)
    _ = setAppScheme(productName())
    #if DEBUG
    let chosenFolder = storeOpenTestFailure == "noFolder" ? nil : dataFolder()
    #else
    let chosenFolder = dataFolder()
    #endif
    guard let folder = chosenFolder else {
      unavailableReason = "no data folder"
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: .openFailed, detail: "no data folder", dataFolder: nil, errorType: "NoDataFolder")
      return false
    }
    var countedLaunch = false
    do {
      guard let lock = try FolderLock.acquire(DataFolder(url: folder)) ?? waitForHolder(folder) else { return false }
      folderLock = lock
      let switches = LaunchSwitches.countLaunch()
      safeMode = switches.safeMode
      safeModeAfterFailedLaunches = switches.safeModeAfterFailedLaunches
      safeModeRequestedAfterFailedOpen = switches.safeModeRequestedAfterFailedOpen
      countedLaunch = switches.countedLaunch
    } catch {
      unavailableReason = "couldn't lock the data folder: \(error)"
      NativeSettingsHandle.unavailable = StoreUnavailable(
        cause: .openFailed, detail: unavailableReason ?? "", dataFolder: folder, errorType: String(describing: type(of: error)))
      NSLog("[store] %@; store unavailable", unavailableReason ?? "")
      return false
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let now = Date()
    let clock: @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
    let memory = StoreMemory(ids: IdSource.random(now: clock()))
    let addressing = OmniboxAddressing()
    var storeConfig = Self.config(folder)
    let context = LoadContext(env: addressing, config: storeConfig, memory: memory, now: clock())
    let launch: SafeLaunch
    do {
      #if DEBUG
      if storeOpenTestFailure == (safeMode ? "safeOpenFailed" : "openFailed") { throw StoreOpenTestFailure(folder: folder) }
      #endif
      launch = try safeMode
        ? Launcher.openSafe(DataFolder(url: folder), appVersion: version, now: now, context: context)
        : SafeLaunch(Launcher.open(DataFolder(url: folder), appVersion: version, now: now, context: context))
    } catch {
      return storeUnavailable(error, folder: folder, offersSafeMode: true)
    }
    do {
      let profileDataTombstones = folder.appending(path: "profile-data-tombstones.json")
      storeConfig.profileDataTombstones = profileDataTombstones
      for note in launch.report.notes { NSLog("[store] %@", note) }
      var state = launch.state
      state.caches.systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
      let configLocation = NativeConfigFiles.prepare(safeMode: safeMode)
      let (configured, configContents) = NativeConfigFiles.applyAtLaunch(configLocation, to: state)
      state = configured
      if safeMode && launch.database == nil {
        storeConfig.persistenceRefusal = "Safe mode could not open the database. Changes to settings and downloads cannot be saved. Open Solara normally to make these changes."
      }
      let store = Store(
        state: state, memory: launch.memory, env: addressing, config: storeConfig,
        onPersistenceRefusal: { message in DispatchQueue.main.async { showPersistenceRefusal(message) } }, clock: clock)
      let host = StoreHost(
        store: store, ownsWorkspace: true, folder: folder,
        restoreTrouble: { NSLog("[store] couldn't restore launch themes: %@", $0) },
        makeWriter: { store in launch.database.map { database in
          PersistenceWriter(
            store: store, database: database, folder: DataFolder(url: folder), persisted: launch.persisted,
            scope: safeMode ? .settingsAndDownloads : .everything,
            trouble: { message in NSLog("[store] %@", message) })
        } })
      do {
        try NewTabsLaunchOverride.apply(store: store, writer: host.writer, folder: folder, safeMode: safeMode)
      } catch {
        host.writer?.freeze()
        throw error
      }
      ownsWorkspace = true
      NativeConfigFiles.start(location: configLocation, contents: configContents, store: store)
      if ownsWorkspace {
        let issuer = PageIssuer(store: store, deliver: { work in host.deliverPageCallback(work) })
        PageIssuer.shared = issuer
        RNPageReports.install(issuer: issuer)
        _ = NativeStoreHandle.subscribeLifecycle { [weak issuer] in
          if NativeStoreHandle.frozen || !NativeStore.ownsWorkspace { issuer?.endMedia() }
        }
        _ = store.subscribe { [weak issuer] commit in
          guard !commit.changes.tabs.isEmpty || !commit.changes.windows.isEmpty else { return }
          Task { @MainActor in
            guard let issuer, NativeStore.ownsWorkspace, PageIssuer.shared === issuer else { return }
            issuer.pruneMedia()
          }
        }
      }
      shared = NativeStore(host: host, launch: launch, folder: folder)
      NativeSettingsHandle.active = true
      NativeStoreHandle.ownsWorkspace = ownsWorkspace
      NativeStoreHandle.ownedWorkspaceAtLaunch = ownsWorkspace
      NativeStoreHandle.opened = true
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          StoreAppearanceWatch.start()
          NativeSettingsHandle.resolve = { NativeStore.settingsModel }
          NativeStoreHandle.resolve = { NativeStore.shared?.bridge.store }
          if NativeStore.ownsWorkspace { NativeStore.shared?.strips.start() }
        }
      }
      NotificationCenter.default.addObserver(forName: Notification.Name("SolaraWindowKeptOnCloseChanged"), object: nil, queue: nil) { note in
        guard NativeStore.ownsWorkspace, let store = NativeStore.shared,
          let id = note.userInfo?["id"] as? String, let on = note.userInfo?["on"] as? Bool else { return }
        do { _ = try store.bridge.store.dispatch(Command("setWindowKeptOnClose", [.string(id), .bool(on)]), origin: .native) }
        catch { NSLog("[store] couldn't save retained window: %@", "\(error)") }
      }
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        guard let store = NativeStore.shared else { return }
        store.profileDataCleanup.stop()
        store.privateSessionEffects.stop()
        store.tabSleep.stop()
        store.keepAwakeSites.stop()
        let result = store.host.termination()
        if result != .saved { NSLog("[store] quit flush: %@", result.description) }
      }
      if countedLaunch { LaunchSuccessWatch.start() }
      return true
    } catch {
      return storeUnavailable(error, folder: folder, offersSafeMode: false)
    }
  }

  @MainActor
  private static func storeUnavailable(_ error: any Error, folder: URL, offersSafeMode: Bool) -> Bool {
    unavailableReason = "\(error)"
    let refused = error is ImportRefused
    if refused { refusedSession = DataFolder(url: folder).session.path }
    NativeSettingsHandle.unavailable = StoreUnavailable(
      cause: refused ? .refused : .openFailed, detail: "\(error)", dataFolder: folder, offersSafeMode: offersSafeMode,
      errorType: String(describing: type(of: error)), launchWasSafeMode: safeMode)
    NSLog("[store] unavailable: %@", "\(error)")
    return false
  }

  #if DEBUG
  static var storeOpenTestFailure: String? {
    let environment = ProcessInfo.processInfo.environment
    guard let scratch = environment["SOLARA_DATA_DIR"], !scratch.isEmpty else { return nil }
    return environment["SOLARA_TEST_STORE_OPEN_FAIL"].flatMap { ["openFailed", "noFolder", "safeOpenFailed"].contains($0) ? $0 : nil }
  }

  struct StoreOpenTestFailure: Error, CustomStringConvertible {
    let folder: URL

    var description: String {
      let resolved = realpath(folder.path, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
      } ?? folder.path
      return "SQLite error 14: unable to open database file \(folder.path)/solara.sqlite (resolved \(resolved)/solara.sqlite, home \(NSHomeDirectory()))\nsecond line that the report leaves out"
    }
  }
  #endif

  @MainActor private static var persistenceAlertVisible = false

  @MainActor
  private static func showPersistenceRefusal(_ message: String) {
    guard !persistenceAlertVisible else { return }
    persistenceAlertVisible = true
    let alert = NSAlert()
    alert.messageText = "Changes Couldn't Be Saved"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window) { _ in persistenceAlertVisible = false }
    } else {
      alert.runModal()
      persistenceAlertVisible = false
    }
  }

  public func flush(timeout: TimeInterval) -> FlushResult { FlushResult.flushing(writer, timeout: timeout) }

  public func flushForQuit(barrierTimeout: TimeInterval = 0.5, writerTimeout: TimeInterval = 0.5) -> FlushResult {
    profileDataCleanup.stop()
    privateSessionEffects.stop()
    tabSleep.stop()
    keepAwakeSites.stop()
    return host.flushForQuit(barrierTimeout: barrierTimeout, writerTimeout: writerTimeout)
  }

  public func freeze() {
    NativeStoreHandle.markFrozen()
    Self.ownsWorkspace = false
    if Thread.isMainThread {
      MainActor.assumeIsolated { NativeStoreHandle.ownsWorkspace = false }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeStoreHandle.ownsWorkspace = false } }
    }
    profileDataCleanup.stop()
    privateSessionEffects.stop()
    tabSleep.stop()
    keepAwakeSites.stop()
    writer?.freeze()
  }
}

@MainActor
enum LaunchSuccessWatch {
  static var tokens: [NSObjectProtocol] = []

  static func start() {
    let success = LaunchSuccess(
      after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } } },
      report: {
        LaunchSwitches.launchSucceeded()
        MainActor.assumeIsolated {
          tokens.forEach(NotificationCenter.default.removeObserver)
          tokens = []
        }
      })
    success.start()
    tokens.append(
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { success.quitting() }
      })
    for name in [NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
          let window = note.object as? NSWindow
          MainActor.assumeIsolated {
            guard let window, window.isVisible, window.occlusionState.contains(.visible) || window.isMainWindow else { return }
            success.windowShown()
          }
        })
    }
  }
}
