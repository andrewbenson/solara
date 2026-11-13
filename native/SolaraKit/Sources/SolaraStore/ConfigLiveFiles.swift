import Foundation
import SolaraModel

public final class ConfigLiveFiles: @unchecked Sendable {
  public let location: ConfigLocation
  public let directory: ConfigDirectory
  public let problems: ConfigProblems
  let store: Store
  let queue: DispatchQueue
  let lock = NSLock()
  var lastGood: ConfigContents?
  var loadCount = 0
  var observer: Int?
  var subscription: Int?

  public var source: String { location.display(ConfigFile.name) }

  public init(
    location: ConfigLocation, store: Store, contents: ConfigContents?, problems: ConfigProblems = .shared,
    debounce: TimeInterval = ConfigDirectory.defaultDebounce, queue: DispatchQueue = .main
  ) {
    self.location = location
    self.store = store
    self.problems = problems
    self.queue = queue
    lastGood = contents
    directory = ConfigDirectory(location: location, debounce: debounce, delivery: queue)
  }

  public var current: ConfigContents? { lock.withLock { lastGood } }
  public var loads: Int { lock.withLock { loadCount } }

  public static func launch(_ location: ConfigLocation?, state: BrowserState, problems: ConfigProblems = .shared) -> (BrowserState, ConfigContents?) {
    guard let location else { return (state, nil) }
    let load = ConfigFile.load { ConfigDirectory.read(location.file($0)) }
    problems.set(load.problems, for: ConfigFile.owner)
    guard let contents = load.contents else { return (state, nil) }
    return (ConfigApply.applied(contents, source: location.display(ConfigFile.name), to: state), contents)
  }

  public func start() {
    observer = directory.observe { [weak self] changed in
      guard let self else { return }
      guard changed.contains(ConfigFile.name) || changed.contains(where: { $0.hasPrefix(ConfigFile.themes + "/") }) else { return }
      self.reload()
    }
    subscription = store.subscribe { [weak self] commit in
      guard !commit.changes.profiles.isEmpty || commit.changes.settings, let self else { return }
      self.queue.async { self.reapply() }
    }
  }

  public func stop() {
    if let observer { directory.removeObserver(observer) }
    if let subscription { store.unsubscribe(subscription) }
    observer = nil
    subscription = nil
  }

  @discardableResult
  public func reload() -> ConfigLoad {
    let load = ConfigFile.load { directory.read($0) }
    lock.withLock {
      loadCount += 1
      if load.good { lastGood = load.contents }
    }
    problems.set(load.problems, for: ConfigFile.owner)
    for problem in load.problems { NSLog("[config] %@ (keeping the last config that worked)", problem.summary(in: location)) }
    if load.good { apply() }
    return load
  }

  func reapply() {
    guard ConfigApply.needsApply(current, source: source, to: store.state) else { return }
    apply()
  }

  func apply() {
    do {
      try store.applyConfig(current, source: source)
    } catch {
      NSLog("[config] couldn't apply %@: %@", source, "\(error)")
    }
  }
}
