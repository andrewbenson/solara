import Foundation

extension ImportService {
  func onWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Self.work.async { continuation.resume(with: Result { try body() }) }
    }
  }

  public func read(jobId: String, browserId: String, profileId: String, kinds: [String], spaceIds: Set<String>? = nil,
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
      try importer.importData(browserId: browserId, profileId: profileId, kinds: parsed, options: ImportOptions(spaceIds: spaceIds), observer: observer, cancellation: cancellation)
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
    return Self.readValue(result, vaultToken: token)
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
    public let spaces: [SpaceSuggestion]
    public var hasSpaces: Bool { !spaces.isEmpty }
    public let history: [HistoryEntry]
    public let favicons: [ImportedFavicon]

    public var description: String { "ImportService.Read" }
    public var debugDescription: String { "ImportService.Read" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
  }

  static func readValue(_ result: ImportResult, vaultToken: String?) -> Read {
    Read(vaultToken: vaultToken, profileName: result.profile?.name, profileColor: result.profile?.color,
         failed: result.failed, warnings: result.warnings, credentials: result.credentials,
         bookmarks: result.bookmarks, tabs: result.tabs, favorites: result.favorites, spaces: result.spaces,
         history: result.history, favicons: result.favicons)
  }
}
