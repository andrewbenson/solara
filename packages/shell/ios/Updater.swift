import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

public struct PendingUpdate: Equatable {
  public let version: String
  public let build: String
  public let channel: String?

  public var payload: [String: Any] { ["version": version, "build": build] }
}

public final class AppUpdater: NSObject {
  public static let shared = AppUpdater()
  public static let pendingUpdateChanged = Notification.Name("SolaraPendingUpdateChanged")

  public private(set) var pendingUpdate: PendingUpdate? {
    didSet {
      guard pendingUpdate != oldValue else { return }
      NotificationCenter.default.post(name: Self.pendingUpdateChanged, object: self)
    }
  }

  static var releaseRepository: String? {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "ACReleaseRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    return repo.isEmpty ? nil : "https://github.com/\(repo)"
  }

  static var feedOverride: String? {
    let env = ProcessInfo.processInfo.environment
    if let feed = env["SOLARA_UPDATE_FEED_URL"] { return feed }
    if env["SOLARA_RELEASE_LAUNCH"] != "1", let feed = UserDefaults.standard.string(forKey: "ACUpdateFeedURL") { return feed }
    guard env["SOLARA_BACKGROUND"] == "1", let repository = releaseRepository else { return nil }
    return "\(repository)/releases/latest/download/appcast.xml"
  }

  public static let channels = ["stable", "nightly"]
  static let channelDefaultsKey = "ACUpdateChannel"

  static var buildChannel: String {
    Bundle.main.object(forInfoDictionaryKey: "ACUpdateChannel") as? String == "nightly" ? "nightly" : "stable"
  }

  public var channel: String {
    let chosen = UserDefaults.standard.string(forKey: Self.channelDefaultsKey) ?? ""
    return Self.channels.contains(chosen) ? chosen : Self.buildChannel
  }

  public func setChannel(_ channel: String) {
    guard Self.channels.contains(channel) else { return }
    UserDefaults.standard.set(channel, forKey: Self.channelDefaultsKey)
    if let pendingUpdate, !isOnChannel(pendingUpdate.channel) {
      self.pendingUpdate = nil
      installWhenIdle = false
    }
    #if canImport(Sparkle)
    guard started else { return }
    channelChangePending = true
    userDriver.leaveOffChannelUpdate()
    applyChannelChangeWhenIdle()
    #endif
  }

  #if canImport(Sparkle)
  private func applyChannelChangeWhenIdle() {
    guard channelChangePending, !updater.sessionInProgress else { return }
    channelChangePending = false
    if hasOffChannelStagedUpdate {
      updater.checkForUpdatesInBackground()
    } else if updater.automaticallyChecksForUpdates {
      updater.resetUpdateCycle()
    }
  }

  private var hasOffChannelStagedUpdate: Bool {
    guard !allowedChannels.contains("nightly") else { return false }
    guard let bundleId = Bundle.main.bundleIdentifier else { return true }
    let staged = StagedUpdates.scan(bundleId: bundleId)
    return !staged.complete || staged.channels.contains("nightly")
  }
  #endif

  static let quitWaitLimit: TimeInterval = 8
  static let quitWaitAfterIdle: TimeInterval = 1

  public var holdsQuitForStagedUpdate: Bool {
    #if canImport(Sparkle)
    started && hasOffChannelStagedUpdate
    #else
    false
    #endif
  }

  public func dropOffChannelStagedUpdateBeforeQuit(then quit: @escaping () -> Void) {
    #if canImport(Sparkle)
    guard holdsQuitForStagedUpdate else { return quit() }
    applyChannelChangeWhenIdle()
    let deadline = Date().addingTimeInterval(Self.quitWaitLimit)
    var idleSince: Date?
    func settle() {
      guard hasOffChannelStagedUpdate else { return quit() }
      let busy = channelChangePending || updater.sessionInProgress
      idleSince = busy ? nil : idleSince ?? Date()
      if let idleSince, Date().timeIntervalSince(idleSince) >= Self.quitWaitAfterIdle {
        NSLog("\(Bundle.main.productName): a staged nightly is still in Sparkle's cache with nothing left to drop it; quitting")
        return quit()
      }
      if Date() >= deadline {
        NSLog("\(Bundle.main.productName): Sparkle didn't drop the staged nightly within \(Int(Self.quitWaitLimit)) s; quitting, and it may install")
        return quit()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle() }
    }
    settle()
    #else
    quit()
    #endif
  }

  var allowedChannels: Set<String> {
    channel == "nightly" ? ["nightly"] : []
  }

  func isOnChannel(_ itemChannel: String?) -> Bool {
    itemChannel.map { allowedChannels.contains($0) } ?? true
  }

  private var installWhenIdle = false
  #if DEBUG
  private var simulatedInstall: String?
  public private(set) var simulatedInstallRequests = 0
  #endif

  @objc public func installPendingUpdate(_ sender: Any?) {
    guard pendingUpdate != nil else { return }
    #if DEBUG
    if let simulatedInstall {
      simulatedInstallRequests += 1
      NSLog("\(Bundle.main.productName): simulated update install requested (\(simulatedInstallRequests))")
      if simulatedInstall == "quit" { NSApp.terminate(nil) }
      return
    }
    #endif
    #if canImport(Sparkle)
    guard started, UpdateQuitApproval.approve() else { return }
    if userDriver.retryQuietInstall() || userDriver.installStagedNow() { return }
    installWhenIdle = true
    startQuietInstallWhenIdle()
    #endif
  }

  #if DEBUG
  public func devSimulatePendingUpdate(version: String?, onInstall: String) {
    simulatedInstall = version == nil ? nil : onInstall
    simulatedInstallRequests = 0
    pendingUpdate = version.map { PendingUpdate(version: $0, build: $0, channel: nil) }
  }
  #endif

  #if canImport(Sparkle)
  private func startQuietInstallWhenIdle() {
    guard installWhenIdle, pendingUpdate != nil, !updater.sessionInProgress else { return }
    installWhenIdle = false
    userDriver.installsQuietly = true
    updater.checkForUpdates()
  }

  private func forgetSkippedUpdate() {
    UpdateQuitApproval.revoke()
    pendingUpdate = nil
    installWhenIdle = false
  }

  private func publishPending(_ item: SUAppcastItem) {
    guard isOnChannel(item.channel) else { return }
    pendingUpdate = PendingUpdate(version: item.displayVersionString, build: item.versionString, channel: item.channel)
  }
  #endif

  private func rememberChannel() {
    guard !Self.channels.contains(UserDefaults.standard.string(forKey: Self.channelDefaultsKey) ?? "") else { return }
    UserDefaults.standard.set(Self.buildChannel, forKey: Self.channelDefaultsKey)
  }

  public static var displayVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    guard let range = version.range(of: #"-nightly\.(\d+)$"#, options: .regularExpression) else { return version }
    let number = version[range].split(separator: ".").last.map(String.init) ?? ""
    return "\(version[..<range.lowerBound]) Nightly \(number)"
  }

  static var chromiumVersion: String? {
    guard let frameworks = Bundle.main.privateFrameworksURL,
          let engine = Bundle(url: frameworks.appendingPathComponent("Chromium Framework.framework")) else { return nil }
    return engine.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  private static func infoString(_ key: String) -> String? {
    let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
    return value.isEmpty || value.hasPrefix("$(") ? nil : value
  }

  @objc public func showAbout(_ sender: Any?) {
    AboutWindowController.shared.show(Self.aboutContent)
  }

  static var aboutContent: AboutContent {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let links = releaseRepository.map { repository in
      [
        ("Source", "\(repository)/tree/v\(version)"),
        ("License", "\(repository)/blob/v\(version)/LICENSE"),
        ("Credits", "\(repository)/blob/v\(version)/NOTICE"),
      ].compactMap { title, url in URL(string: url).map { AboutLink(title: title, url: $0) } }
    } ?? []
    return AboutContent(
      name: Bundle.main.productName,
      version: "Version \(displayVersion)" + (build.map { " (\($0))" } ?? ""),
      chromium: chromiumVersion,
      copyright: infoString("ACCopyright") ?? "© 2026 Mantra Patel",
      upstreamCredit: infoString("ACUpstreamCredit"),
      links: links
    )
  }

  private static var isOff: Bool {
    ACIsolatedDataDirectory() != nil && ProcessInfo.processInfo.environment["SOLARA_UPDATE_FEED_URL"] == nil
  }

  #if canImport(Sparkle)
  private lazy var userDriver = ChannelUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: self)) { [unowned self] item in
    self.isOnChannel(item.channel)
  }
  private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
  private var deferredUpdate = false
  private var channelChangePending = false
  private var sessionObservation: NSKeyValueObservation?
  private var firstCheckPending = false
  #endif
  private var started = false

  public var isAvailable: Bool {
    #if canImport(Sparkle)
    true
    #else
    false
    #endif
  }

  public var isConfigured: Bool {
    guard isAvailable, !Self.isOff else { return false }
    let info = Bundle.main.infoDictionary ?? [:]
    let feed = (Self.feedOverride ?? info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    guard let scheme = URL(string: feed)?.scheme?.lowercased() else { return false }
    return (scheme == "https" || scheme == "http") && !key.isEmpty
  }

  public func start() {
    #if canImport(Sparkle)
    rememberChannel()
    guard !started, isConfigured else { return }
    started = true
    userDriver.onSkip = { [weak self] in self?.forgetSkippedUpdate() }
    firstCheckPending = updater.lastUpdateCheckDate == nil
    do {
      try updater.start()
    } catch {
      NSLog("\(Bundle.main.productName): couldn't start the updater: \(error.localizedDescription)")
    }
    sessionObservation = updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, change in
      guard change.newValue == false else { return }
      DispatchQueue.main.async {
        self?.applyChannelChangeWhenIdle()
        self?.startQuietInstallWhenIdle()
      }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: NSWindow.didExitFullScreenNotification, object: nil)
    #endif
  }

  @objc public func checkForUpdates(_ sender: Any?) {
    #if canImport(Sparkle)
    guard isConfigured else {
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" {
        return NSLog("\(Bundle.main.productName): update checks are off in this instance")
      }
      return showNotSetUp()
    }
    start()
    updater.checkForUpdates()
    #endif
  }

  public var state: [String: Any] {
    #if canImport(Sparkle)
    return [
      "available": true,
      "configured": isConfigured,
      "automaticChecks": updater.automaticallyChecksForUpdates,
      "automaticDownloads": updater.automaticallyDownloadsUpdates,
      "canCheck": updater.canCheckForUpdates,
      "sessionInProgress": updater.sessionInProgress,
      "feedURL": updater.feedURL?.absoluteString as Any,
      "lastCheck": updater.lastUpdateCheckDate.map { $0.timeIntervalSince1970 * 1000 } as Any,
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as Any,
      "displayVersion": Self.displayVersion,
      "channel": channel,
      "buildChannel": Self.buildChannel,
      "pendingUpdate": pendingUpdate?.payload as Any,
    ]
    #else
    return ["available": false]
    #endif
  }

  public func setAutomaticChecks(_ on: Bool) {
    #if canImport(Sparkle)
    updater.automaticallyChecksForUpdates = on
    #endif
  }

  public func setAutomaticDownloads(_ on: Bool) {
    #if canImport(Sparkle)
    updater.automaticallyDownloadsUpdates = on
    #endif
  }

  private func showNotSetUp() {
    let alert = NSAlert()
    let name = Bundle.main.productName
    alert.messageText = "Updates aren't set up for this build"
    alert.informativeText = "This copy of \(name) doesn't have an update feed, so it can't check for new versions. Get newer versions from wherever you got this one."
    alert.addButton(withTitle: "OK")
    if let window = NSApp.keyWindow, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  static var isPresentingFullScreen: Bool {
    NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.fullScreen) }
  }

  #if canImport(Sparkle)
  @objc private func fullScreenChanged() {
    DispatchQueue.main.async { [self] in
      guard !Self.isPresentingFullScreen, deferredUpdate else { return }
      deferredUpdate = false
      updater.checkForUpdates()
    }
  }
  #endif
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
  public func feedURLString(for updater: SPUUpdater) -> String? { Self.feedOverride ?? Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }

  public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    allowedChannels
  }

  public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    NSLog("\(Bundle.main.productName): update found: \(item.displayVersionString) (build \(item.versionString)\(item.channel.map { ", \($0)" } ?? "")) on the \(channel) channel")
  }

  public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    NSLog("\(Bundle.main.productName): no update on the \(channel) channel")
  }

  public func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
    guard firstCheckPending else { return [] }
    firstCheckPending = false
    return [["key": "first", "value": "1"]]
  }

  public func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    UpdatePrewarm.start(version: item.versionString)
    publishPending(item)
    return false
  }
}

enum KillSwitch {
  static let cacheDocument = "switches-cache.json"

  static func isOn(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    cache: () -> String? = { DocumentStore.read(cacheDocument) }
  ) -> Bool {
    for part in (environment["SOLARA_SWITCHES"] ?? "").split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pair.count == 2, pair[0] == name else { continue }
      if ["off", "0", "false"].contains(pair[1]) { return false }
      if ["on", "1", "true"].contains(pair[1]) { return true }
    }
    guard let data = cache()?.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let switches = json["switches"] as? [String: Any],
      let value = switches[name] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
    else { return true }
    return value.boolValue
  }
}

enum UpdatePrewarm {
  static let timeout: TimeInterval = 90
  static let installHold: TimeInterval = 15
  static let statusSpawnFailed = -2
  static let statusRejected = -3
  static let statusStopped = Int(SIGKILL)
  private static var started = Set<String>()
  private static var warmed = Set<String>()
  private static var runningVersion: String?
  private static var attempt: Attempt?
  private static var generation = 0
  private static var afterRun: [() -> Void] = []
  private static var watchingQuit = false

  static func start(version: String) {
    guard !started.contains(version) else { return }
    started.insert(version)
    warm(version: version)
  }

  static func warm(version: String) {
    guard runningVersion != version, !warmed.contains(version), KillSwitch.isOn("updatePrewarm"),
      let bundleId = Bundle.main.bundleIdentifier, let staged = StagedUpdates.newest(version: version, bundleId: bundleId)
    else { return }
    stop()
    launch(staged, version: version)
  }

  static func beforeInstall(version: String, install: @escaping () -> Void) {
    warm(version: version)
    guard runningVersion == version else { return install() }
    var waiting = true
    let proceed = {
      guard waiting else { return }
      waiting = false
      install()
    }
    afterRun.append(proceed)
    DispatchQueue.main.asyncAfter(deadline: .now() + installHold, execute: proceed)
  }

  static func stop() {
    attempt?.stop()
    attempt = nil
    runningVersion = nil
    afterRun = []
    generation += 1
  }

  private static let ownRequirement: SecRequirement? = {
    var running: SecCode?
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
      SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
      SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess
    else { return nil }
    return requirement
  }()

  private final class Attempt {
    let version: String
    private let began = Date()
    private let lock = NSLock()
    private var settled = false
    private var pid: pid_t = 0
    private var exit: DispatchSourceProcess?

    init(version: String) {
      self.version = version
    }

    func spawnSuspended(_ executable: URL, environment: [String: String], ended: @escaping () -> Void) throws -> pid_t? {
      lock.lock()
      defer { lock.unlock() }
      guard !settled else { return nil }
      let child = try VerifiedLaunch.spawnSuspended(executable, environment: environment)
      pid = child
      let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
      source.setEventHandler {
        self.reap(child)
        ended()
      }
      exit = source
      source.activate()
      return child
    }

    func resume() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !settled, pid != 0 else { return false }
      return kill(pid, SIGCONT) == 0
    }

    var running: Bool {
      lock.lock()
      defer { lock.unlock() }
      return !settled && pid != 0
    }

    func stop(status: Int = UpdatePrewarm.statusStopped) {
      lock.lock()
      defer { lock.unlock() }
      if !settled, pid != 0 { kill(pid, SIGKILL) }
      settle(status: status)
    }

    func record(status: Int) {
      lock.lock()
      defer { lock.unlock() }
      settle(status: status)
    }

    private func reap(_ child: pid_t) {
      lock.lock()
      defer { lock.unlock() }
      exit?.cancel()
      exit = nil
      let status = VerifiedLaunch.reap(child) ?? VerifiedLaunch.reap(child, waiting: true)
      if pid == child { pid = 0 }
      settle(status: status ?? UpdatePrewarm.statusStopped)
    }

    private func settle(status: Int) {
      guard !settled else { return }
      settled = true
      pid = 0
      NSLog("\(Bundle.main.productName): prewarmed update \(version) in \(Int(Date().timeIntervalSince(began) * 1000)) ms (status \(status))")
    }
  }

  private static func launch(_ staged: StagedCopy, version: String) {
    if !watchingQuit {
      watchingQuit = true
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in stop() }
    }
    generation += 1
    let current = generation
    let tried = Attempt(version: version)
    attempt = tried
    runningVersion = version
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SOLARA_") && !$0.key.hasPrefix("DYLD_") }
    env["SOLARA_PREWARM"] = "1"
    DispatchQueue.global(qos: .utility).async {
      guard let requirement = ownRequirement, let verified = VerifiedLaunch.verify(staged, requirement: requirement) else {
        tried.record(status: statusRejected)
        NSLog("\(Bundle.main.productName): not prewarming \(staged.bundleURL.path): its signature isn't this app's")
        return DispatchQueue.main.async { finish(current) }
      }
      let child: pid_t
      do {
        guard let spawned = try tried.spawnSuspended(staged.executableURL, environment: env, ended: { DispatchQueue.main.async { finish(current) } })
        else { return }
        child = spawned
      } catch {
        tried.record(status: statusSpawnFailed)
        NSLog("\(Bundle.main.productName): couldn't prewarm update \(version): \(error.localizedDescription)")
        return DispatchQueue.main.async { finish(current) }
      }
      guard VerifiedLaunch.isGenuine(pid: child, verified: verified, inside: staged.bundleURL) else {
        NSLog("\(Bundle.main.productName): not prewarming \(staged.bundleURL.path): the process it started isn't the code it checked")
        tried.stop(status: statusRejected)
        return
      }
      guard tried.resume() else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        guard attempt === tried, tried.running else { return }
        NSLog("\(Bundle.main.productName): update prewarm still running after \(Int(timeout)) s; stopping it")
        stop()
      }
    }
  }

  private static func finish(_ which: Int) {
    guard which == generation else { return }
    if let runningVersion { warmed.insert(runningVersion) }
    runningVersion = nil
    attempt = nil
    let waiting = afterRun
    afterRun = []
    waiting.forEach { $0() }
  }
}

enum SkippedUpdateDefaults {
  static let keys = ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"]

  static func unchanged(by answer: () -> Void) {
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    answer()
    DispatchQueue.main.async {
      for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
    }
  }
}

final class PendingChoice {
  private var reply: ((SPUUserUpdateChoice) -> Void)?

  init(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
    self.reply = reply
  }

  func answer(_ choice: SPUUserUpdateChoice) {
    guard let reply else { return }
    self.reply = nil
    reply(choice)
  }

  func discard() {
    reply = nil
  }
}

final class ChannelUserDriver: NSObject, SPUUserDriver {
  private let standard: SPUStandardUserDriver
  private let isOnChannel: (SUAppcastItem) -> Bool
  private var shownItem: SUAppcastItem?
  private var pendingChoice: PendingChoice?
  private var heldInstall: PendingChoice?
  private var pendingCancellation: (() -> Void)?
  private var quietInstall = false
  private var retryTermination: (() -> Void)?
  private var stagedAnswer: (choice: PendingChoice, answer: (SPUUserUpdateChoice) -> Void)?
  var installsQuietly = false
  var onSkip: () -> Void = {}

  init(standard: SPUStandardUserDriver, isOnChannel: @escaping (SUAppcastItem) -> Bool) {
    self.standard = standard
    self.isOnChannel = isOnChannel
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || standard.responds(to: aSelector)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    standard.responds(to: aSelector) ? standard : nil
  }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard isOnChannel(appcastItem) else { return drop(appcastItem, answering: reply) }
    shownItem = appcastItem
    let staged = state.stage == .installing
    if staged { UpdatePrewarm.warm(version: appcastItem.versionString) }
    let answer = awaiting(reply, staged: staged)
    let quiet = installsQuietly && staged
    installsQuietly = false
    guard quiet else { return standard.showUpdateFound(with: appcastItem, state: state, reply: answer) }
    quietInstall = true
    answer(.install)
  }

  func retryQuietInstall() -> Bool {
    guard quietInstall, let retry = retryTermination else { return false }
    retry()
    return true
  }

  func leaveOffChannelUpdate() {
    guard let item = shownItem, !isOnChannel(item) else { return }
    if let choice = pendingChoice {
      pendingChoice = nil
      drop(item, answering: choice.answer)
    } else if let cancel = pendingCancellation {
      pendingCancellation = nil
      drop(item) { _ in cancel() }
    }
  }

  private func drop(_ item: SUAppcastItem, answering reply: (SPUUserUpdateChoice) -> Void) {
    NSLog("\(Bundle.main.productName): dropping update \(item.displayVersionString) (build \(item.versionString)): its channel isn't this copy's any more")
    UpdatePrewarm.stop()
    SkippedUpdateDefaults.unchanged { reply(.skip) }
  }

  private func awaiting(_ reply: @escaping (SPUUserUpdateChoice) -> Void, staged: Bool = false) -> (SPUUserUpdateChoice) -> Void {
    let choice = PendingChoice(reply)
    pendingChoice = choice
    var answered = false
    let answer: (SPUUserUpdateChoice) -> Void = { [weak self] picked in
      guard !answered else { return }
      answered = true
      if self?.pendingChoice === choice { self?.pendingChoice = nil }
      if self?.stagedAnswer?.choice === choice { self?.stagedAnswer = nil }
      if picked == .skip { self?.onSkip() }
      guard picked == .install, let self, let item = self.shownItem else { return choice.answer(picked) }
      guard self.isOnChannel(item) else { return self.drop(item, answering: choice.answer) }
      guard staged else { return choice.answer(.install) }
      self.heldInstall = choice
      UpdatePrewarm.beforeInstall(version: item.versionString) { [weak self] in
        if self?.heldInstall === choice { self?.heldInstall = nil }
        if let self, !self.isOnChannel(item) { return self.drop(item, answering: choice.answer) }
        choice.answer(.install)
      }
    }
    stagedAnswer = staged ? (choice, answer) : nil
    return answer
  }

  func installStagedNow() -> Bool {
    guard let staged = stagedAnswer, let item = shownItem, isOnChannel(item) else { return false }
    stagedAnswer = nil
    installsQuietly = false
    quietInstall = true
    standard.dismissUpdateInstallation()
    staged.answer(.install)
    return true
  }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    standard.show(request, reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    installsQuietly = false
    standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    standard.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
    standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    standard.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    pendingCancellation = cancellation
    standard.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    standard.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    pendingCancellation = nil
    standard.showDownloadDidStartExtractingUpdate()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    standard.showExtractionReceivedProgress(progress)
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    if let item = shownItem, isOnChannel(item) { UpdatePrewarm.warm(version: item.versionString) }
    standard.showReady(toInstallAndRelaunch: awaiting(reply, staged: true))
    leaveOffChannelUpdate()
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    guard !quietInstall else {
      retryTermination = retryTerminatingApplication
      return
    }
    standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    standard.showUpdateInFocus()
  }

  func dismissUpdateInstallation() {
    if quietInstall { UpdateQuitApproval.revoke() }
    stagedAnswer = nil
    installsQuietly = false
    quietInstall = false
    retryTermination = nil
    heldInstall?.discard()
    heldInstall = nil
    shownItem = nil
    pendingChoice = nil
    pendingCancellation = nil
    standard.dismissUpdateInstallation()
  }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
  public var supportsGentleScheduledUpdateReminders: Bool { true }

  public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
    !Self.isPresentingFullScreen
  }

  public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    if !handleShowingUpdate { deferredUpdate = true }
  }

  public func standardUserDriverWillFinishUpdateSession() {
    deferredUpdate = false
  }

  @objc(standardUserDriverShowVersionHistoryForAppcastItem:)
  public func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
    guard let page = item.fullReleaseNotesURL else { return }
    var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
    components?.fragment = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    OpenURLInbox.receive([components?.url ?? page])
  }
}
#endif
