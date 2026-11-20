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

  func keep(cookies: [Cookie], addresses: [ImportedAddress], cards: [ImportedCard], started: Int) -> String? {
    session.keep(cookies: cookies, addresses: addresses, cards: cards, started: started)
  }
}

public class ImportModule: Module {
  private let service = ImportService.shared
  private var importer: Importer { service.importer }
  private var jobs: ImportJobs { service.jobs }
  private var vault: ImportVault { service.vault }
  private static let work = DispatchQueue(label: "solara.import", qos: .userInitiated, attributes: .concurrent)
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
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { NSLog("[import] background instance, not opening %@", url.absoluteString) } else { NSWorkspace.shared.open(url) }
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
      self.run(promise) { try Self.json(DiaAutomation.status(ImportService.diaBundleId, ask: false)) }
    }

    AsyncFunction("requestDiaAutomation") { (promise: Promise) in
      let ask = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"
      self.run(promise) { try Self.json(DiaAutomation.status(ImportService.diaBundleId, ask: ask)) }
    }

    AsyncFunction("openAutomationSettings") { (promise: Promise) in
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { NSLog("[import] background instance, not opening %@", url.absoluteString) } else { NSWorkspace.shared.open(url) }
      promise.resolve(nil)
    }.runOnQueue(.main)

    AsyncFunction("openDia") { (promise: Promise) in
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
      self.run(promise) {
        guard DiaAutomation.isRunning(ImportService.diaBundleId) else { throw ImportError.notRunning("Dia isn't running") }
        var result = try DiaTabsImport.read(from: DiaAppleEvents(bundleIdentifier: ImportService.diaBundleId))
        result.favicons = self.importer.favicons(browserId: "dia", pages: result.profiles.flatMap { $0.pinned.map(\.url) + $0.tabs.map(\.url) })
        return try Self.json(result)
      }
    }

    AsyncFunction("importBookmarksHTML") { (path: String, promise: Promise) in
      self.run(promise) { try Self.json(NetscapeBookmarks.load(Self.fileURL(path))) }
    }

    AsyncFunction("importPasswordsCSV") { (path: String, promise: Promise) in
      self.run(promise) { try Self.json(PasswordsCSV.load(Self.fileURL(path))) }
    }

    AsyncFunction("chooseImportFile") { (kind: String, promise: Promise) in
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
      panel.begin { response in promise.resolve(response == .OK ? panel.url?.path : nil) }
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

  static func fileURL(_ path: String) -> URL {
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
