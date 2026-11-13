import AppKit
internal import SolaraModel
internal import SolaraStore

enum NativeConfigFiles {
  nonisolated(unsafe) private(set) static var live: ConfigLiveFiles?
  nonisolated(unsafe) static var activation: NSObjectProtocol?

  static func prepare(safeMode: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfigLocation? {
    if safeMode {
      NSLog("[config] safe mode: config files are not read")
      return nil
    }
    return ConfigLocation.resolve(environment: environment)
  }

  static func applyAtLaunch(_ location: ConfigLocation?, to state: BrowserState) -> (BrowserState, ConfigContents?) {
    let (applied, contents) = ConfigLiveFiles.launch(location, state: state)
    for problem in ConfigProblems.shared.problems(for: ConfigFile.owner) { NSLog("[config] %@", problem.summary(in: location)) }
    return (applied, contents)
  }

  @MainActor
  static func start(location: ConfigLocation?, contents: ConfigContents?, store: Store) {
    guard let location else { return }
    let live = ConfigLiveFiles(location: location, store: store, contents: contents)
    self.live = live
    ConfigDirectory.shared = live.directory
    live.start()
    activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
      live.directory.rescanNow()
    }
  }
}
