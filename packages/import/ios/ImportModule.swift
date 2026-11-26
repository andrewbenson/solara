import AppKit
import SolaraCore
import ExpoModulesCore

public final class ImportService: @unchecked Sendable {
  public static let shared = ImportService()

  static let importer: Importer = {
    let support = ImportEnvironment.applicationSupport
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

  static var safariHome: URL { ImportEnvironment.safariHome }

  static let secret: Importer.SecretProvider = {
    let provider = ImportEnvironment.secret
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

  static var diaBundleId: String { ImportEnvironment.diaBundleId }

  static let work = DispatchQueue(label: "solara.import", qos: .userInitiated, attributes: .concurrent)

  public func browsersJSON() async -> String? {
    try? await onWork { [importer] in try ImportModule.json(importer.discovery.list()) }
  }

  public func isUnlocked(_ browserId: String) -> Bool { importer.isUnlocked(browserId) }

  public func unlock(_ browserId: String) async -> Bool {
    await session.unlock(browserId, on: Self.work, secret: Self.secret)
  }

  public struct Written: Sendable {
    public let cookies: Int
    public let addresses: Int
    public let cards: Int
    public let cookiesFailed: Bool
    public let autofillFailed: Bool
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
                bookmarks: data.bookmarks, tabs: data.tabs, favorites: [], spaces: [], history: history, favicons: [])
  }

  public func cancelRead(jobId: String) { session.jobs.cancel(jobId) }

  #if DEBUG
  static var diaFixture: String? { ImportEnvironment.diaFixture }
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
  private var importer: Importer { ImportService.importer }

  public func definition() -> ModuleDefinition {
    Name("SolaraImportAdapter")

    AsyncFunction("listBrowsers") { (promise: Promise) in
      self.run(promise) { try Self.json(self.importer.discovery.list()) }
    }

    #if DEBUG
    Function("devSecretRequests") { () -> [[String: String]] in ImportService.secretRequests }
    Function("devResetSecretRequests") { ImportService.secretRequestLog.reset() }
    #endif

    AsyncFunction("importPasswordsCSV") { (path: String, promise: Promise) in
      self.run(promise) { try Self.json(PasswordsCSV.load(Self.fileURL(path))) }
    }

    AsyncFunction("chooseImportFile") { (kind: String, promise: Promise) in
      guard kind == "passwordsCSV" else { return promise.resolve(nil) }
      Task { @MainActor in promise.resolve(await ImportService.chooseFile(kind)) }
    }.runOnQueue(.main)
  }

  private func run(_ promise: Promise, _ body: @escaping () throws -> String?) {
    ImportService.work.async {
      do { promise.resolve(try body()) }
      catch let error as ImportError { promise.reject(error.code, error.description) }
      catch { promise.reject("unreadable", error.localizedDescription) }
    }
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
