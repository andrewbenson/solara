import AppKit
import SolaraCore
import ExpoModulesCore

public final class ImportService: @unchecked Sendable {
  public static let shared = ImportService()

  static let importer: Importer = {
    let env = ProcessInfo.processInfo.environment
    let support = env["SOLARA_IMPORT_SOURCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let icons = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Solara")/ImportIcons", isDirectory: true)
    return Importer(discovery: BrowserDiscovery(
      applicationSupport: support,
      locateApp: AppIcons.locate,
      iconFor: { app, id in AppIcons.png(for: app, id: id, directory: icons, safeMode: SolaraCoreHost.safeMode) }
    ))
  }()

  let session = ImportSession(importer: ImportService.importer)

  var importer: Importer { session.importer }
  var jobs: ImportJobs { session.jobs }
  var vault: ImportVault { session.vault }
  var epoch: ImportEpoch { session.epoch }

  static let safariHome: URL = {
    let env = ProcessInfo.processInfo.environment
    if let home = env["SOLARA_IMPORT_SAFARI_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
    if let support = env["SOLARA_IMPORT_SOURCE_DIR"] {
      return URL(fileURLWithPath: support, isDirectory: true).deletingLastPathComponent().deletingLastPathComponent()
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }()

  static let secret: Importer.SecretProvider = {
    let provider: Importer.SecretProvider
    if let fixed = ProcessInfo.processInfo.environment["SOLARA_IMPORT_TEST_SECRET"] {
      provider = { _, _ in Data(fixed.utf8) }
    } else {
      provider = SafeStorageKeychain.secret
    }
    #if DEBUG
    return { service, account in
      secretRequestLog.record(["service": service, "account": account, "main": Thread.isMainThread ? "1" : "0"])
      return try provider(service, account)
    }
    #else
    return provider
    #endif
  }()

  #if DEBUG
  static let secretRequestLog = SecretRequestLog()

  public static var secretRequests: [[String: String]] { secretRequestLog.entries }
  #endif

  static let diaBundleId = ProcessInfo.processInfo.environment["SOLARA_IMPORT_DIA_BUNDLE_ID"] ?? DiaAutomation.bundleIdentifier

  static let work = DispatchQueue(label: "solara.import", qos: .userInitiated, attributes: .concurrent)

  func keep(cookies: [Cookie], addresses: [ImportedAddress], cards: [ImportedCard], started: Int) -> String? {
    session.keep(cookies: cookies, addresses: addresses, cards: cards, started: started)
  }

  private func onWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Self.work.async { continuation.resume(with: Result { try body() }) }
    }
  }

  public func browsersJSON() async -> String? {
    try? await onWork { [importer] in try ImportModule.json(importer.discovery.list()) }
  }

  public func isUnlocked(_ browserId: String) -> Bool { importer.isUnlocked(browserId) }

  public func unlock(_ browserId: String) async -> Bool {
    await session.unlock(browserId, on: Self.work, secret: Self.secret)
  }

  public struct Read: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let vaultToken: String?
    public let profileName: String?
    public let profileColor: String?
    public let failed: [ImportKind]
    public let warnings: [ImportWarning]
    public let credentials: [Credential]
    public let bookmarks: BookmarkNode?
    public let tabs: [ImportedTab]
    public let favorites: [ImportedTab]
    public let hasSpaces: Bool
    public let history: [HistoryEntry]
    public let favicons: [ImportedFavicon]

    public var description: String { "ImportService.Read" }
    public var debugDescription: String { "ImportService.Read" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
  }

  public struct Written: Sendable {
    public let cookies: Int
    public let addresses: Int
    public let cards: Int
    public let cookiesFailed: Bool
    public let autofillFailed: Bool
  }

  public func read(jobId: String, browserId: String, profileId: String, kinds: [String],
                   progress: @escaping @Sendable (String, Bool) -> Void) async throws -> Read {
    let session = session
    let started = session.epoch.current
    let cancellation = session.jobs.start(jobId, epoch: started)
    defer { session.jobs.finish(jobId, cancellation) }
    guard session.epoch.isCurrent(started) else { throw ImportError.cancelled }
    let parsed = kinds.compactMap(ImportKind.init(rawValue:))
    let observer = ImportObserver(progress: { p in
      if p.phase == .start { progress(p.kind.rawValue, false) }
      if p.phase == .end { progress(p.kind.rawValue, true) }
    })
    var result = try await onWork { [importer = session.importer] in
      try importer.importData(browserId: browserId, profileId: profileId, kinds: parsed, observer: observer, cancellation: cancellation)
    }
    #if DEBUG
    if ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] != nil,
       let delay = ProcessInfo.processInfo.environment["SOLARA_IMPORT_TEST_READ_DELAY_MS"].flatMap(Int.init) {
      try? await Task.sleep(for: .milliseconds(delay))
    }
    #endif
    let token = session.keep(cookies: result.cookies, addresses: result.addresses, cards: result.cards, started: started)
    result.cookies = []
    result.addresses = []
    result.cards = []
    guard session.epoch.isCurrent(started) else {
      if let token { session.vault.discard(token) }
      throw ImportError.cancelled
    }
    return Read(vaultToken: token, profileName: result.profile?.name, profileColor: result.profile?.color,
                failed: result.failed, warnings: result.warnings, credentials: result.credentials,
                bookmarks: result.bookmarks, tabs: result.tabs, favorites: result.favorites, hasSpaces: !result.spaces.isEmpty,
                history: result.history, favicons: result.favicons)
  }

  public func readSafari(jobId: String, exportPath: String?) async throws -> Read {
    let session = session
    let started = session.epoch.current
    let cancellation = session.jobs.start(jobId, epoch: started)
    defer { session.jobs.finish(jobId, cancellation) }
    guard session.epoch.isCurrent(started) else { throw ImportError.cancelled }
    var data = try await onWork {
      if let exportPath { return try SafariExport.load(ImportModule.fileURL(exportPath), cancellation: cancellation) }
      return try SafariDirect.load(home: Self.safariHome, cancellation: cancellation)
    }
    let token = session.keep(cookies: data.cookies, addresses: [], cards: data.cards, started: started)
    data.cookies = []
    data.cards = []
    guard session.epoch.isCurrent(started) else {
      if let token { session.vault.discard(token) }
      throw ImportError.cancelled
    }
    let history = data.profiles.first { $0.name?.isEmpty ?? true }?.history ?? data.profiles.first?.history ?? []
    return Read(vaultToken: token, profileName: nil, profileColor: nil, failed: [], warnings: data.warnings, credentials: data.credentials,
                bookmarks: data.bookmarks, tabs: data.tabs, favorites: [], hasSpaces: false, history: history, favicons: [])
  }

  public func cancelRead(jobId: String) { session.jobs.cancel(jobId) }

  #if DEBUG
  static var diaFixture: String? { ProcessInfo.processInfo.environment["SOLARA_IMPORT_DIA_FIXTURE"] }
  #endif

  static var diaFixtureStatus: DiaAutomation.Status? {
    #if DEBUG
    if diaFixture != nil { return .granted }
    #endif
    return nil
  }

  static func diaTabs(_ importer: Importer) throws -> DiaTabsResult {
    #if DEBUG
    if let diaFixture { return try JSONDecoder().decode(DiaTabsResult.self, from: Data(contentsOf: URL(fileURLWithPath: diaFixture))) }
    #endif
    guard DiaAutomation.isRunning(diaBundleId) else { throw ImportError.notRunning("Dia isn't running") }
    var result = try DiaTabsImport.read(from: DiaAppleEvents(bundleIdentifier: diaBundleId))
    result.favicons = importer.favicons(browserId: "dia", pages: result.profiles.flatMap { $0.pinned.map(\.url) + $0.tabs.map(\.url) })
    return result
  }

  public func readDiaTabs() async throws -> DiaTabsResult {
    try await onWork { [importer] in try Self.diaTabs(importer) }
  }

  @MainActor public static func openDia() async -> Bool {
    #if DEBUG
    if diaFixture != nil { return true }
    #endif
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return false }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: diaBundleId) else { return false }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in continuation.resume(returning: error == nil) }
    }
  }

  #if DEBUG
  public var devVaultCount: Int { session.vault.count }
  #endif

  public func discard(_ token: String) { session.vault.discard(token) }

  public func write(token: String, engineProfile: String, kinds: [String]) async -> Written? {
    guard let entry = session.vault.take(token) else { return nil }
    let json = await ImportWriter.write(entry, profile: engineProfile, kinds: Set(kinds))
    guard let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
    func count(_ key: String) -> Int { (body[key] as? NSNumber)?.intValue ?? 0 }
    return Written(cookies: count("cookies"), addresses: count("addresses"), cards: count("cards"),
                   cookiesFailed: count("cookiesFailed") != 0, autofillFailed: count("autofillFailed") != 0)
  }

  public func forget() { session.forget() }

  public func extensions(browserId: String, profileId: String) async -> [ImportedExtension] {
    guard let def = BrowserDefinition.find(browserId), def.isChromiumBased else { return [] }
    return (try? await onWork { [importer] in ChromiumExtensions.list(profile: try importer.discovery.profileDirectory(def, profileId)) }) ?? []
  }

  public func safariHasFullDiskAccess() async -> Bool {
    (try? await onWork { SafariDirect.hasAccess(home: Self.safariHome) }) ?? false
  }

  public func diaStatus(ask: Bool) async -> String? {
    #if DEBUG
    if Self.diaFixture != nil { return DiaAutomation.Status.granted.rawValue }
    #endif
    guard let json = try? await onWork({ try ImportModule.json(DiaAutomation.status(Self.diaBundleId, ask: ask)) }) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) as? String
  }

  @MainActor public static func openPrivacySettings(_ pane: String) {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { NSLog("[import] background instance, not opening %@", url.absoluteString) } else { NSWorkspace.shared.open(url) }
  }

  #if DEBUG
  @MainActor public static var devChosenFile: String?
  #endif

  @MainActor public static func chooseFile(_ kind: String) async -> String? {
    #if DEBUG
    if let chosen = devChosenFile {
      devChosenFile = nil
      return chosen
    }
    #endif
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    switch kind {
    case "safariExport":
      panel.canChooseDirectories = true
      panel.allowedContentTypes = [.zip]
    case "bookmarksHTML":
      panel.allowedContentTypes = [.html]
    default:
      panel.allowedContentTypes = [.commaSeparatedText]
    }
    return await withCheckedContinuation { continuation in
      panel.begin { response in continuation.resume(returning: response == .OK ? panel.url?.path : nil) }
    }
  }
}

public class ImportModule: Module {
  private let service = ImportService.shared
  private var importer: Importer { service.importer }
  private var jobs: ImportJobs { service.jobs }
  private var vault: ImportVault { service.vault }
  private static var work: DispatchQueue { ImportService.work }
  private var owner = 0

  public func definition() -> ModuleDefinition {
    Name("SolaraImportAdapter")
    Events("onImportEvent")

    OnCreate { self.owner = self.service.session.claim() }

    OnDestroy { self.service.session.forget(owner: self.owner) }

    AsyncFunction("listBrowsers") { (promise: Promise) in
      self.run(promise) { try Self.json(self.importer.discovery.list()) }
    }

    AsyncFunction("importData") { (jobId: String, browserId: String, profileId: String, kinds: [String], options: [String: Any], promise: Promise) in
      guard let job = self.service.session.start(jobId, owner: self.owner) else { return Self.rejectCancelled(promise) }
      let (started, cancellation) = job
      let observer = self.observer(jobId: jobId, options: options)
      let parsed = kinds.compactMap(ImportKind.init(rawValue:))
      self.run(promise, job: (jobId, cancellation), started: started) {
        var result = try self.importer.importData(browserId: browserId, profileId: profileId, kinds: parsed,
                                                  options: Self.options(options), observer: observer, cancellation: cancellation)
        result.vaultToken = self.service.keep(cookies: result.cookies, addresses: result.addresses, cards: result.cards, started: started)
        return try Self.json(result)
      }
    }

    Function("cancelImport") { (jobId: String) in self.jobs.cancel(jobId) }

    #if DEBUG
    Function("devSecretRequests") { () -> [[String: String]] in ImportService.secretRequests }
    Function("devResetSecretRequests") { ImportService.secretRequestLog.reset() }
    #endif

    AsyncFunction("unlockBrowser") { (browserId: String, primaryPassword: String?, promise: Promise) in
      guard let started = self.service.session.begin(owner: self.owner) else { return Self.rejectCancelled(promise) }
      let session = (epoch: self.service.epoch, started: started)
      self.run(promise, started: started) {
        try self.importer.unlock(browserId: browserId, primaryPassword: primaryPassword ?? "", session: session,
                                 secret: ImportService.secret)
        return nil
      }
    }

    Function("isBrowserUnlocked") { (browserId: String) -> Bool in self.importer.isUnlocked(browserId) }
    AsyncFunction("forgetUnlockedKeys") { (promise: Promise) in
      self.service.session.forget(owner: self.owner)
      promise.resolve(nil)
    }

    AsyncFunction("writeImported") { (token: String, profile: String, kinds: [String], promise: Promise) in
      guard self.service.session.begin(owner: self.owner) != nil else { return Self.rejectCancelled(promise) }
      guard let entry = self.vault.take(token) else { return promise.reject("notFound", "Nothing to write; import again") }
      Task { @MainActor in
        promise.resolve(await ImportWriter.write(entry, profile: profile, kinds: Set(kinds)))
      }
    }

    Function("discardImported") { (token: String) in self.vault.discard(token) }

    AsyncFunction("listExtensions") { (browserId: String, profileId: String, promise: Promise) in
      self.run(promise) {
        guard let def = BrowserDefinition.find(browserId), def.isChromiumBased else { return "[]" }
        return try Self.json(ChromiumExtensions.list(profile: try self.importer.discovery.profileDirectory(def, profileId)))
      }
    }

    AsyncFunction("importSafariExport") { (jobId: String, path: String, promise: Promise) in
      guard let job = self.service.session.start(jobId, owner: self.owner) else { return Self.rejectCancelled(promise) }
      let (started, cancellation) = job
      self.run(promise, job: (jobId, cancellation), started: started) {
        var data = try SafariExport.load(Self.fileURL(path), cancellation: cancellation)
        data.vaultToken = self.service.keep(cookies: data.cookies, addresses: [], cards: data.cards, started: started)
        return try Self.json(data)
      }
    }

    Function("safariHasFullDiskAccess") { () -> Bool in SafariDirect.hasAccess(home: ImportService.safariHome) }

    AsyncFunction("openFullDiskAccessSettings") { (promise: Promise) in
      MainActor.assumeIsolated { ImportService.openPrivacySettings("Privacy_AllFiles") }
      promise.resolve(nil)
    }.runOnQueue(.main)

    AsyncFunction("importSafariDirect") { (jobId: String, promise: Promise) in
      guard let job = self.service.session.start(jobId, owner: self.owner) else { return Self.rejectCancelled(promise) }
      let (started, cancellation) = job
      self.run(promise, job: (jobId, cancellation), started: started) {
        var data = try SafariDirect.load(home: ImportService.safariHome, cancellation: cancellation)
        data.vaultToken = self.service.keep(cookies: data.cookies, addresses: [], cards: data.cards, started: started)
        return try Self.json(data)
      }
    }

    AsyncFunction("diaAutomationStatus") { (promise: Promise) in
      self.run(promise) { try Self.json(ImportService.diaFixtureStatus ?? DiaAutomation.status(ImportService.diaBundleId, ask: false)) }
    }

    AsyncFunction("requestDiaAutomation") { (promise: Promise) in
      let ask = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"
      self.run(promise) { try Self.json(ImportService.diaFixtureStatus ?? DiaAutomation.status(ImportService.diaBundleId, ask: ask)) }
    }

    AsyncFunction("openAutomationSettings") { (promise: Promise) in
      MainActor.assumeIsolated { ImportService.openPrivacySettings("Privacy_Automation") }
      promise.resolve(nil)
    }.runOnQueue(.main)

    AsyncFunction("openDia") { (promise: Promise) in
      #if DEBUG
      if ImportService.diaFixture != nil { return promise.resolve(nil) }
      #endif
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return promise.reject("background", "a background instance doesn't open Dia") }
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ImportService.diaBundleId) else {
        return promise.reject("notFound", "Dia isn't installed")
      }
      let config = NSWorkspace.OpenConfiguration()
      config.activates = false
      NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
        if let error { promise.reject("unreadable", error.localizedDescription) } else { promise.resolve(nil) }
      }
    }.runOnQueue(.main)

    AsyncFunction("readDiaTabs") { (promise: Promise) in
      self.run(promise) { try Self.json(ImportService.diaTabs(self.importer)) }
    }

    AsyncFunction("importBookmarksHTML") { (path: String, promise: Promise) in
      self.run(promise) { try Self.json(NetscapeBookmarks.load(Self.fileURL(path))) }
    }

    AsyncFunction("importPasswordsCSV") { (path: String, promise: Promise) in
      self.run(promise) { try Self.json(PasswordsCSV.load(Self.fileURL(path))) }
    }

    AsyncFunction("chooseImportFile") { (kind: String, promise: Promise) in
      Task { @MainActor in promise.resolve(await ImportService.chooseFile(kind)) }
    }.runOnQueue(.main)
  }

  private static func rejectCancelled(_ promise: Promise) {
    promise.reject(ImportError.cancelled.code, ImportError.cancelled.description)
  }

  private func run(_ promise: Promise, job: (id: String, cancellation: Cancellation)? = nil, started: Int? = nil,
                   _ body: @escaping () throws -> String?) {
    Self.work.async { [jobs, session = service.session] in
      defer { if let job { jobs.finish(job.id, job.cancellation) } }
      do {
        let value = try body()
        if let started, !session.isCurrent(started) { return Self.rejectCancelled(promise) }
        promise.resolve(value)
      } catch let error as ImportError {
        promise.reject(error.code, error.description)
      } catch {
        promise.reject("unreadable", error.localizedDescription)
      }
    }
  }

  private func observer(jobId: String, options: [String: Any]) -> ImportObserver {
    let stream = options["streamHistory"] as? Bool ?? false
    let emit: @Sendable ([String: Any?]) -> Void = { [weak self] body in self?.sendEvent("onImportEvent", body) }
    let progress: @Sendable (ImportProgress) -> Void = { p in
      var body: [String: Any?] = ["jobId": jobId, "type": "progress", "kind": p.kind.rawValue,
                                  "phase": p.phase.rawValue, "processed": p.processed]
      if let total = p.total { body["total"] = total }
      emit(body)
    }
    var history: (@Sendable ([HistoryEntry]) -> Void)?
    if stream {
      history = { chunk in emit(["jobId": jobId, "type": "history", "entries": (try? Self.json(chunk)) ?? "[]"]) }
    }
    return ImportObserver(chunkSize: options["chunkSize"] as? Int ?? 1000, progress: progress, history: history)
  }

  static func options(_ o: [String: Any]) -> ImportOptions {
    ImportOptions(
      historyLimit: (o["historyLimit"] as? NSNumber)?.intValue,
      historySince: (o["historySince"] as? NSNumber)?.doubleValue,
      spaceIds: (o["spaceIds"] as? [String]).map(Set.init),
      streamHistory: o["streamHistory"] as? Bool ?? false
    )
  }

  public static func fileURL(_ path: String) -> URL {
    if path.hasPrefix("file://"), let url = URL(string: path) { return url }
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  }

  static func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
}

#if DEBUG
final class SecretRequestLog: @unchecked Sendable {
  static let limit = 200
  private let lock = NSLock()
  private var recorded: [[String: String]] = []

  var entries: [[String: String]] { lock.withLock { recorded } }

  func record(_ entry: [String: String]) {
    lock.withLock {
      recorded.append(entry)
      if recorded.count > Self.limit { recorded.removeFirst(recorded.count - Self.limit) }
    }
  }

  func reset() { lock.withLock { recorded.removeAll() } }
}
#endif
