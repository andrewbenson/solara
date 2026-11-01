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

  static var scope: PersistenceScope {
    LaunchSwitches.shared.scope == "settingsAndDownloads" ? .settingsAndDownloads : .everything
  }

  static func config(_ folder: URL) -> StoreConfig {
    var config = StoreConfig()
    config.safeMode = safeMode
    config.replicaProfilesFromDisk = scope == .settingsAndDownloads
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
  let host: StoreHost
  var bridge: StoreBridge { host.bridge }
  var writer: PersistenceWriter? { host.writer }
  let launch: SafeLaunch
  let caches: NativeCacheFeeds
  let strips: StripTransport

  @MainActor
  init(host: StoreHost, launch: SafeLaunch, folder: URL) {
    profileDataCleanup = NativeProfileDataCleanup(store: host.bridge.store)
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
    guard let folder = dataFolder() else {
      unavailableReason = "no data folder"
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: .openFailed, detail: "no data folder", dataFolder: nil)
      return false
    }
    do {
      guard let lock = try FolderLock.acquire(DataFolder(url: folder)) ?? waitForHolder(folder) else { return false }
      folderLock = lock
      let switches = LaunchSwitches.countLaunch()
      safeMode = switches.safeMode
      safeModeAfterFailedLaunches = switches.safeModeAfterFailedLaunches
      if switches.countedLaunch { MainActor.assumeIsolated { LaunchSuccessWatch.start() } }
    } catch {
      unavailableReason = "couldn't lock the data folder: \(error)"
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: .openFailed, detail: unavailableReason ?? "", dataFolder: folder)
      NSLog("[store] %@; store unavailable", unavailableReason ?? "")
      return false
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let now = Date()
    let clock: @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }
    let memory = StoreMemory(ids: IdSource.random(now: clock()))
    let addressing = OmniboxAddressing()
    var storeConfig = Self.config(folder)
    let activeScope = Self.scope
    let context = LoadContext(env: addressing, config: storeConfig, memory: memory, now: clock())
    do {
      let launch = try safeMode
        ? Launcher.openSafe(DataFolder(url: folder), appVersion: version, now: now, context: context)
        : SafeLaunch(Launcher.open(DataFolder(url: folder), appVersion: version, now: now, context: context, scope: activeScope))
      let profileDataTombstones = folder.appending(path: "profile-data-tombstones.json")
      storeConfig.profileDataTombstones = profileDataTombstones
      for note in launch.report.notes { NSLog("[store] %@", note) }
      var state = launch.state
      state.caches.systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
      if safeMode && launch.database == nil {
        storeConfig.persistenceRefusal = "Safe mode could not open the database. Changes to settings and downloads cannot be saved. Open Solara normally to make these changes."
      }
      let store = Store(
        state: state, memory: launch.memory, env: addressing, config: storeConfig,
        onPersistenceRefusal: { message in DispatchQueue.main.async { showPersistenceRefusal(message) } }, clock: clock)
      ownsWorkspace = activeScope == .everything
      let host = StoreHost(
        store: store, ownsWorkspace: ownsWorkspace, folder: folder,
        restoreTrouble: { NSLog("[store] couldn't restore launch themes: %@", $0) },
        makeWriter: { store in launch.database.map { database in
          PersistenceWriter(
            store: store, database: database, folder: DataFolder(url: folder), persisted: launch.persisted,
            scope: safeMode ? .settingsAndDownloads : activeScope,
            trouble: { message in NSLog("[store] %@", message) })
        } })
      if ownsWorkspace {
        let issuer = PageIssuer(store: store, deliver: { work in host.deliverPageCallback(work) })
        PageIssuer.shared = issuer
        RNPageReports.install(issuer: issuer)
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
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        guard let store = NativeStore.shared else { return }
        store.profileDataCleanup.stop()
        let result = store.host.termination()
        if result != .saved { NSLog("[store] quit flush: %@", result.description) }
      }
      return true
    } catch {
      unavailableReason = "\(error)"
      if error is ImportRefused { refusedSession = DataFolder(url: folder).session.path }
      NativeSettingsHandle.unavailable = StoreUnavailable(cause: error is ImportRefused ? .refused : .openFailed, detail: "\(error)", dataFolder: folder)
      NSLog("[store] unavailable: %@", "\(error)")
      return false
    }
  }

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

  func flush(timeout: TimeInterval) -> FlushResult { FlushResult.flushing(writer, timeout: timeout) }

  public func flushForQuit(barrierTimeout: TimeInterval = 0.5, writerTimeout: TimeInterval = 0.5) -> FlushResult {
    profileDataCleanup.stop()
    return host.flushForQuit(barrierTimeout: barrierTimeout, writerTimeout: writerTimeout)
  }

  public func freeze() {
    profileDataCleanup.stop()
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
