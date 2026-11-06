import Foundation
import Synchronization
#if os(macOS)
import Security
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif

public enum LaunchSwitch: String, CaseIterable, Sendable {
  case nativeShell = "SOLARA_NATIVE_SHELL"
  case shellPanes = "SOLARA_SHELL_PANES"
  case nativePagesPool = "SOLARA_NATIVE_PAGES_POOL"
  case shellMainTop = "SOLARA_SHELL_MAIN_TOP"
  case nativeTopStrip = "SOLARA_NATIVE_TOP_STRIP"
  case nativeBookmarksBar = "SOLARA_NATIVE_BOOKMARKS_BAR"
  case syncRedesign = "SOLARA_SYNC_REDESIGN"
  case nativeServices = "SOLARA_NATIVE_SERVICES"
  case nativeTabSleep = "SOLARA_NATIVE_TAB_SLEEP"

  public static let experiments: [LaunchSwitch] = [
    .nativeShell, .shellPanes, .nativeTopStrip,
  ]
  static let storedInDevelopment: Set<LaunchSwitch> = [
    .nativeShell, .shellPanes, .nativePagesPool, .shellMainTop, .nativeTopStrip,
    .nativeBookmarksBar,
  ]
  static let developmentOnly: Set<LaunchSwitch> = [.syncRedesign]
  public static let onByDefault: Set<LaunchSwitch> = [
    .nativeShell, .nativeTopStrip,
    .shellPanes, .nativePagesPool, .shellMainTop, .nativeTabSleep,
  ]

  public var needs: [LaunchSwitch] {
    switch self {
    case .shellPanes, .nativePagesPool, .nativeBookmarksBar: [.nativeShell]
    case .shellMainTop: [.shellPanes, .nativePagesPool]
    default: []
    }
  }

  public func storable(distribution: Bool) -> Bool {
    distribution ? Self.experiments.contains(self) && !Self.onByDefault.contains(self) : Self.storedInDevelopment.contains(self)
  }
}

public struct LaunchSwitches: Sendable {
  public static let scopeVariable = "SOLARA_NATIVE_SCOPE"
  public static let defaultsVariable = "SOLARA_LAUNCH_SWITCHES_DEFAULTS"
  public static let optionVariable = "SOLARA_LAUNCH_SWITCHES_OPTION"
  static let storedPrefixes = ["SOLARA_NATIVE_", "SOLARA_SHELL_"]

  public let isolated: Bool
  public let defaultsSuite: String?
  public let distribution: Bool
  public var safeMode = false
  public var safeModeAfterFailedLaunches = false
  public var countedLaunch = false
  public let scope: String?
  let environment: [LaunchSwitch: Bool]
  let stored: [LaunchSwitch: Bool]

  public init(environment env: [String: String], defaults: UserDefaults?, distribution: Bool, skipStored: Bool) {
    let isolated = env["SOLARA_BACKGROUND"] == "1" || env["SOLARA_DATA_DIR"] != nil
    self.isolated = isolated
    let suite = distribution ? nil : env[Self.defaultsVariable].flatMap { $0.isEmpty ? nil : $0 }
    self.defaultsSuite = suite
    self.distribution = distribution
    self.scope = env[Self.scopeVariable]
    var environment: [LaunchSwitch: Bool] = [:]
    let ownDataFolder = env["SOLARA_DATA_DIR"].map { !$0.isEmpty } ?? false
    for name in LaunchSwitch.allCases where (!LaunchSwitch.developmentOnly.contains(name) || (ownDataFolder && !distribution))
      && (!distribution || !LaunchSwitch.onByDefault.contains(name)) {
      if let value = env[name.rawValue].flatMap(Self.parse) { environment[name] = value }
    }
    self.environment = environment
    let readsDefaults = (!isolated || suite != nil) && defaults != nil
    var stored: [LaunchSwitch: Bool] = [:]
    if readsDefaults, !skipStored, let defaults {
      for name in LaunchSwitch.allCases where name.storable(distribution: distribution) {
        if let value = Self.storedValue(name, in: defaults) { stored[name] = value }
      }
    }
    self.stored = stored
  }

  public var usesDefaults: Bool { !isolated || defaultsSuite != nil }

  public static var defaults: UserDefaults { shared.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

  static let current = Mutex<LaunchSwitches?>(nil)

  public static var shared: LaunchSwitches {
    resolve(current, ask: askSafeMode) { system(counting: false, safeModeAnswer: $0) }
  }

  @discardableResult
  public static func countLaunch() -> LaunchSwitches {
    resolve(current, ask: askSafeMode) { system(counting: true, safeModeAnswer: $0) }
  }

  static func resolve(
    _ cell: borrowing Mutex<LaunchSwitches?>, ask: () -> Bool?, build: (Bool?) -> LaunchSwitches
  ) -> LaunchSwitches {
    if let existing = cell.withLock({ $0 }) { return existing }
    let safeModeAnswer = ask()
    return cell.withLock { current in
      if let current { return current }
      let switches = build(safeModeAnswer)
      current = switches
      return switches
    }
  }

  public func isOn(_ name: LaunchSwitch, defaultOn: Bool) -> Bool {
    requested(name, defaultOn: defaultOn) && unmetNeeds(name).isEmpty
  }

  public func isOn(_ name: LaunchSwitch) -> Bool {
    isOn(name, defaultOn: LaunchSwitch.onByDefault.contains(name))
  }

  public func requested(_ name: LaunchSwitch, defaultOn: Bool) -> Bool {
    environment[name] ?? stored[name] ?? defaultOn
  }

  public func unmetNeeds(_ name: LaunchSwitch) -> [LaunchSwitch] {
    name.needs.filter { !isOn($0) }
  }

  public var refusals: [String] {
    LaunchSwitch.allCases.compactMap { name in
      let unmet = unmetNeeds(name)
      guard !unmet.isEmpty, requested(name, defaultOn: LaunchSwitch.onByDefault.contains(name)) else { return nil }
      return "\(name.rawValue) is on but stays off: it needs \(unmet.map { "\($0.rawValue)=1" }.joined(separator: " and "))"
    }
  }

  public func fromEnvironment(_ name: LaunchSwitch) -> Bool { environment[name] != nil }

  static func parse(_ text: String) -> Bool? {
    switch text {
    case "1": true
    case "0": false
    default: nil
    }
  }

  static func storedValue(_ name: LaunchSwitch, in defaults: UserDefaults?) -> Bool? {
    switch defaults?.object(forKey: name.rawValue) {
    case let text as String: parse(text)
    case let number as NSNumber: number.intValue == 1 ? true : number.intValue == 0 ? false : nil
    default: nil
    }
  }

  static let failedLaunchesKey = "SolaraLaunchSwitchFailedLaunches"
  static let failedLaunchLimit = 2

  public static func launching(
    environment env: [String: String], defaults: UserDefaults, distribution: Bool, optionHeld: () -> Bool, counting: Bool = true,
    confirmSafeMode: () -> Bool = { true }
  ) -> LaunchSwitches {
    let probe = LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false)
    if !probe.usesDefaults { return probe }
    var switches = LaunchSwitches(environment: env, defaults: defaults, distribution: distribution, skipStored: false)
    if optionHeld(), confirmSafeMode() {
      if counting {
        defaults.set(max(defaults.integer(forKey: failedLaunchesKey), failedLaunchLimit), forKey: failedLaunchesKey)
        switches.countedLaunch = true
      }
      switches.safeMode = true
      return switches
    }
    guard counting else { return switches }
    let failed = defaults.integer(forKey: failedLaunchesKey)
    if failed >= failedLaunchLimit {
      switches.safeMode = true
      switches.safeModeAfterFailedLaunches = true
      switches.countedLaunch = true
      return switches
    }
    defaults.set(failed + 1, forKey: failedLaunchesKey)
    switches.countedLaunch = true
    return switches
  }

  public var safeModeReport: String? {
    guard safeMode else { return nil }
    return safeModeAfterFailedLaunches
      ? "Solara didn't finish opening twice in a row, so this launch skips session restore and extensions."
      : "Option was held while Solara opened, so this launch skips session restore and extensions."
  }

  public static func launchSucceeded(defaults: UserDefaults = LaunchSwitches.defaults, isolated: Bool = !shared.usesDefaults) {
    guard !isolated else { return }
    defaults.removeObject(forKey: failedLaunchesKey)
  }

  struct Launch {
    let env = ProcessInfo.processInfo.environment
    let distribution = signedForDistribution() || ProcessInfo.processInfo.environment["SOLARA_RELEASE_LAUNCH"] == "1"
    var probe: LaunchSwitches { LaunchSwitches(environment: env, defaults: nil, distribution: distribution, skipStored: false) }
    var defaults: UserDefaults { probe.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }
  }

  static func askSafeMode() -> Bool? {
    let launch = Launch()
    let probe = launch.probe
    guard probe.usesDefaults, (probe.defaultsSuite != nil && launch.env[optionVariable] == "1") || optionHeld() else { return nil }
    return probe.isolated || confirmSafeModeAlert()
  }

  static func system(counting: Bool, safeModeAnswer: Bool?) -> LaunchSwitches {
    let launch = Launch()
    let switches = launching(
      environment: launch.env, defaults: launch.defaults, distribution: launch.distribution, optionHeld: { safeModeAnswer != nil },
      counting: counting, confirmSafeMode: { safeModeAnswer ?? false })
    if let report = switches.safeModeReport { NSLog("[launch switches] %@", report) }
    for refusal in switches.refusals { NSLog("[launch switches] %@", refusal) }
    return switches
  }

  public static func safeModeQuestion() -> (title: String, message: String) {
    (
      "Open Solara in safe mode?",
      "Option was held while Solara opened. Safe mode keeps the native interface on, skips restoring the saved session, and disables extensions for this launch. The saved session returns on the next normal launch."
    )
  }

  static func confirmSafeModeAlert() -> Bool {
    #if os(macOS)
    let question = safeModeQuestion()
    var response: CFOptionFlags = 0
    let shown = CFUserNotificationDisplayAlert(
      0, kCFUserNotificationCautionAlertLevel, nil, nil, nil, question.title as CFString, question.message as CFString,
      "Open in Safe Mode" as CFString, "Open Normally" as CFString, nil, &response)
    return shown == 0 && response & 0x3 == kCFUserNotificationDefaultResponse
    #else
    true
    #endif
  }

  static func optionHeld() -> Bool {
    #if canImport(CoreGraphics) && os(macOS)
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    #else
    false
    #endif
  }

  static func signedForDistribution() -> Bool {
    #if os(macOS)
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
    let text = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return true }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    #else
    false
    #endif
  }
}

public struct StoredLaunchSwitches {
  let defaults: UserDefaults?
  public let distribution: Bool

  public init(defaults: UserDefaults?, distribution: Bool) {
    self.defaults = defaults
    self.distribution = distribution
  }

  public init(_ running: LaunchSwitches, defaults: UserDefaults = LaunchSwitches.defaults) {
    self.init(defaults: running.usesDefaults ? defaults : nil, distribution: running.distribution)
  }

  public var writable: Bool { defaults != nil }

  public func value(_ name: LaunchSwitch) -> Bool? {
    name.storable(distribution: distribution) ? LaunchSwitches.storedValue(name, in: defaults) : nil
  }

  public var any: Bool { LaunchSwitch.allCases.contains { value($0) != nil } }

  public func set(_ name: LaunchSwitch, _ on: Bool?) {
    guard let defaults, name.storable(distribution: distribution) else { return }
    if let on { defaults.set(on ? "1" : "0", forKey: name.rawValue) } else { defaults.removeObject(forKey: name.rawValue) }
    removeUnknown()
  }

  public func clear() {
    guard let defaults else { return }
    for name in LaunchSwitch.allCases where name.storable(distribution: distribution) { defaults.removeObject(forKey: name.rawValue) }
    removeUnknown()
  }

  func removeUnknown() {
    guard let defaults else { return }
    let known = Set(LaunchSwitch.allCases.map(\.rawValue) + [LaunchSwitches.scopeVariable])
    for key in defaults.dictionaryRepresentation().keys
    where LaunchSwitches.storedPrefixes.contains(where: key.hasPrefix) && !known.contains(key) {
      defaults.removeObject(forKey: key)
    }
  }
}
