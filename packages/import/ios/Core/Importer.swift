import Foundation

public final class Importer: @unchecked Sendable {
  public let discovery: BrowserDiscovery
  private let lock = NSLock()
  private var keys: [String: Data] = [:]
  private var firefoxPasswords: [String: String] = [:]
  private var epochs: [String: Int] = [:]
  private var generation = 0

  public init(discovery: BrowserDiscovery) {
    self.discovery = discovery
  }

  public typealias SecretProvider = (_ service: String, _ account: String) throws -> Data

  public func unlock(browserId: String, primaryPassword: String = "", session: (epoch: ImportEpoch, started: Int)? = nil,
                     secret: SecretProvider = SafeStorageKeychain.secret) throws {
    guard let def = BrowserDefinition.find(browserId) else { throw ImportError.notFound("Unknown browser \(browserId)") }
    let started = lock.withLock { generation }
    let epoch = session?.started ?? Int.min
    func stillCurrent() -> Bool { generation == started && (session.map { $0.epoch.isCurrent($0.started) } ?? true) }
    switch def.family {
    case .chromium, .arc:
      let items = def.keychainItems
      guard !items.isEmpty else { return }
      let key = ChromiumCrypto.deriveKey(secret: try Self.firstSecret(items, secret))
      lock.withLock { if stillCurrent() { keys[browserId] = key; epochs[browserId] = epoch } }
    case .firefox:
      lock.withLock { if stillCurrent() { firefoxPasswords[browserId] = primaryPassword; epochs[browserId] = epoch } }
    case .safari, .automation:
      break
    }
  }

  static func firstSecret(_ items: [BrowserDefinition.KeychainItem], _ secret: SecretProvider) throws -> Data {
    var missing: Error?
    for item in items {
      do {
        return try secret(item.service, item.account)
      } catch ImportError.notFound(let message) {
        missing = missing ?? ImportError.notFound(message)
      }
    }
    throw missing ?? ImportError.notFound("No Safe Storage item in the Keychain")
  }

  func setKey(_ key: Data, for browserId: String) { lock.withLock { keys[browserId] = key; epochs[browserId] = Int.min } }

  public func isUnlocked(_ browserId: String) -> Bool {
    lock.withLock { keys[browserId] != nil || firefoxPasswords[browserId] != nil }
  }

  public func forgetKeys() {
    lock.withLock {
      generation += 1
      keys.removeAll()
      firefoxPasswords.removeAll()
      epochs.removeAll()
    }
  }

  public func forgetKeys(before epoch: Int) {
    lock.withLock {
      let stale = Set(keys.keys).union(firefoxPasswords.keys).filter { (epochs[$0] ?? Int.min) < epoch }
      for id in stale {
        keys[id] = nil
        firefoxPasswords[id] = nil
        epochs[id] = nil
      }
    }
  }

  private func key(_ browserId: String) -> Data? { lock.withLock { keys[browserId] } }
  private func primaryPassword(_ browserId: String) -> String? { lock.withLock { firefoxPasswords[browserId] } }

  public func importData(browserId: String, profileId: String, kinds: [ImportKind], options: ImportOptions = .init(),
                         observer: ImportObserver = .silent, cancellation: Cancellation = .init()) throws -> ImportResult {
    guard let def = BrowserDefinition.find(browserId) else { throw ImportError.notFound("Unknown browser \(browserId)") }
    guard def.family != .safari else { throw ImportError.unsupported("Safari imports come from its export archive") }
    let dir = try discovery.profileDirectory(def, profileId)
    var result = ImportResult(browserId: browserId, profileId: profileId)
    if let info = discovery.profile(def, profileId) {
      result.profile = ProfileSuggestion(name: info.name, color: info.color, avatarPath: info.avatarPath)
    }

    var arc: ArcSidebar?
    func arcSidebar() throws -> ArcSidebar {
      if let arc { return arc }
      let url = discovery.arcSidebarURL()
      guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.notFound("No Arc sidebar data") }
      let parsed = try ArcSidebar.parse(Data(contentsOf: url))
      arc = parsed
      return parsed
    }

    var zen: ZenSidebar?
    func zenSidebar() throws -> ZenSidebar {
      if let zen { return zen }
      let parsed = try ZenSidebar.load(profile: dir, profileId: profileId, cancellation: cancellation)
      zen = parsed
      return parsed
    }

    func sidebarSpaces() throws -> [SpaceSuggestion]? {
      switch def.sidebar {
      case .arc:
        return try arcSidebar().spaces.filter { $0.profileId == profileId }
      case .zen:
        let spaces = (try? zenSidebar())?.spaces ?? []
        return spaces.isEmpty ? nil : spaces
      case nil:
        return nil
      }
    }

    func take(_ all: [SpaceSuggestion], for kind: ImportKind) -> Int {
      let spaces = all.filter { options.spaceIds?.contains($0.id) ?? true }
      result.spaces = spaces.map { space in
        var s = space
        if !kinds.contains(.pinnedTabs) { s.pinned = [] }
        if !kinds.contains(.tabs) { s.tabs = [] }
        return s
      }
      switch kind {
      case .tabs:
        result.tabs = spaces.flatMap(\.tabs)
        return result.tabs.count
      case .pinnedTabs:
        return spaces.reduce(0) { $0 + $1.pinned.reduce(0) { $0 + $1.linkCount } }
      default:
        return spaces.count
      }
    }

    let ordered = ImportKind.allCases.filter(kinds.contains)
    for kind in ordered {
      try cancellation.check()
      if kind != .history { observer.progress(ImportProgress(kind: kind, phase: .start, processed: 0, total: nil)) }
      var count = 0
      var succeeded = false
      do {
        switch (kind, def.family) {
        case (.bookmarks, .chromium), (.bookmarks, .arc):
          result.bookmarks = try ChromiumBookmarks.load(profile: dir)
          count = result.bookmarks?.linkCount ?? 0
        case (.bookmarks, .firefox):
          result.bookmarks = try Firefox.bookmarks(places: dir.appendingPathComponent("places.sqlite"), cancellation: cancellation)
          count = result.bookmarks?.linkCount ?? 0

        case (.history, .chromium), (.history, .arc), (.history, .firefox):
          let flavor: HistoryReader.Flavor = def.family == .firefox ? .firefox : .chromium
          let file = dir.appendingPathComponent(def.family == .firefox ? "places.sqlite" : "History")
          let (entries, total) = try HistoryReader.read(file, flavor: flavor, options: options, observer: observer, cancellation: cancellation)
          result.history = entries
          result.historyCount = total
          count = total

        case (.tabs, .chromium):
          let session = try ChromiumSessions.load(profile: dir, key: key(browserId))
          result.tabs = session.tabs
          result.tabGroups = session.groups
          count = session.tabs.count
        case (.tabs, .firefox):
          if let spaces = try sidebarSpaces() {
            count = take(spaces, for: kind)
          } else {
            let session = try Firefox.loadSession(profile: dir)
            result.tabs = session.tabs
            result.tabGroups = session.groups
            count = session.tabs.count
          }

        case (.spaces, .arc), (.pinnedTabs, .arc), (.tabs, .arc), (.spaces, .firefox), (.pinnedTabs, .firefox):
          guard def.sidebar != nil else { throw ImportError.unsupported("\(def.name) has no \(kind.rawValue) to import") }
          guard let spaces = try sidebarSpaces() else { throw ImportError.notFound("No \(def.name) spaces in this profile") }
          count = take(spaces, for: kind)
        case (.favorites, .arc):
          result.favorites = try arcSidebar().favorites[profileId] ?? []
          count = result.favorites.count
        case (.favorites, .firefox):
          guard def.sidebar == .zen else { throw ImportError.unsupported("\(def.name) has no \(kind.rawValue) to import") }
          result.favorites = try zenSidebar().essentials
          count = result.favorites.count

        case (.passwords, .chromium), (.passwords, .arc):
          guard let key = key(browserId) else { throw ImportError.locked("Unlock \(def.name) to import passwords") }
          let outcome = try ChromiumSecrets.logins(profile: dir, key: key, cancellation: cancellation)
          result.credentials = outcome.items
          count = outcome.items.count
          if outcome.undecryptable > 0 {
            result.warnings.append(ImportWarning(kind, "undecryptable", "\(Self.count(outcome.undecryptable, "password")) couldn't be decrypted"))
            if outcome.items.isEmpty { throw ImportError.locked("The \(def.name) key didn't decrypt any passwords") }
          }
        case (.passwords, .firefox):
          guard let password = primaryPassword(browserId) else { throw ImportError.locked("Allow \(def.name) password import first") }
          result.credentials = try FirefoxLogins.logins(profile: dir, primaryPassword: password, cancellation: cancellation)
          count = result.credentials.count

        case (.cookies, .chromium), (.cookies, .arc):
          guard let key = key(browserId) else { throw ImportError.locked("Unlock \(def.name) to import cookies") }
          let outcome = try ChromiumSecrets.cookies(profile: dir, key: key, cancellation: cancellation)
          result.cookies = outcome.items
          count = outcome.items.count
          if outcome.undecryptable > 0 {
            result.warnings.append(ImportWarning(kind, "undecryptable", "\(Self.count(outcome.undecryptable, "cookie")) couldn't be decrypted"))
            if outcome.items.isEmpty { throw ImportError.locked("The \(def.name) key didn't decrypt any cookies") }
          }
        case (.cookies, .firefox):
          let outcome = try Firefox.cookies(profile: dir, cancellation: cancellation)
          result.cookies = outcome.items
          count = outcome.items.count
          if outcome.skipped > 0 {
            result.warnings.append(ImportWarning(kind, "skipped",
              "\(Self.count(outcome.skipped, "cookie")) from containers or private windows weren't imported"))
          }

        case (.autofill, .chromium), (.autofill, .arc):
          let key = key(browserId)
          let outcome = try ChromiumAutofill.load(profile: dir, key: key, cancellation: cancellation)
          result.addresses = outcome.addresses
          result.cards = outcome.cards
          count = outcome.addresses.count + outcome.cards.count
          if outcome.lockedCards > 0 {
            result.warnings.append(ImportWarning(kind, "locked", "Unlock \(def.name) to import \(Self.count(outcome.lockedCards, "saved card"))"))
          }
          if outcome.undecryptable > 0 {
            result.warnings.append(ImportWarning(kind, "undecryptable", "\(Self.count(outcome.undecryptable, "card")) couldn't be decrypted"))
          }

        default:
          throw ImportError.unsupported("\(def.name) has no \(kind.rawValue) to import")
        }
        succeeded = true
      } catch ImportError.cancelled {
        throw ImportError.cancelled
      } catch ImportError.notFound(let message) {
        result.warnings.append(ImportWarning(kind, "empty", message))
      } catch let error as ImportError {
        result.failed.append(kind)
        result.warnings.append(ImportWarning(kind, error.code, error.description))
      } catch {
        result.failed.append(kind)
        result.warnings.append(ImportWarning(kind, "unreadable", error.localizedDescription))
      }
      if kind != .history || !succeeded { observer.progress(ImportProgress(kind: kind, phase: .end, processed: count, total: count)) }
    }
    if def.family == .chromium || def.family == .arc {
      try cancellation.check()
      result.favicons = ChromiumFavicons.read(profiles: [dir], pages: ChromiumFavicons.pages(of: result))
    }
    if let zen {
      result.favicons = zen.favicons(for: ChromiumFavicons.pages(of: result))
    }
    return result
  }

  public func favicons(browserId: String, pages: [String]) -> [ImportedFavicon] {
    guard let def = BrowserDefinition.find(browserId), def.family == .chromium || def.family == .arc else { return [] }
    let dirs = discovery.chromiumProfiles(def).compactMap { try? discovery.profileDirectory(def, $0.id) }
    return ChromiumFavicons.read(profiles: dirs, pages: pages)
  }

  static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

public final class ImportEpoch: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  private var owner = 0

  public init() {}

  public var current: Int { lock.withLock { value } }

  public func isCurrent(_ epoch: Int) -> Bool { lock.withLock { value == epoch } }

  @discardableResult
  public func advance() -> Int { lock.withLock { value += 1; return value } }

  public func claim() -> (owner: Int, epoch: Int) {
    lock.withLock {
      owner += 1
      value += 1
      return (owner, value)
    }
  }

  public func begin(owner claimed: Int) -> Int? { lock.withLock { owner == claimed ? value : nil } }

  public func advance(owner claimed: Int) -> Int? {
    lock.withLock {
      guard owner == claimed else { return nil }
      value += 1
      return value
    }
  }
}

public final class ImportSession: @unchecked Sendable {
  public let importer: Importer
  public let jobs = ImportJobs()
  public let vault = ImportVault()
  public let epoch = ImportEpoch()
  #if DEBUG
  let afterJobStart = DevHook()
  #endif

  public init(importer: Importer) {
    self.importer = importer
  }

  public func claim() -> Int {
    let claimed = epoch.claim()
    clear(before: claimed.epoch)
    return claimed.owner
  }

  public func begin(owner: Int) -> Int? { epoch.begin(owner: owner) }

  public func start(_ id: String, owner: Int) -> (started: Int, cancellation: Cancellation)? {
    guard let started = epoch.begin(owner: owner) else { return nil }
    let cancellation = jobs.start(id, epoch: started)
    #if DEBUG
    afterJobStart()
    #endif
    guard epoch.isCurrent(started) else {
      cancellation.cancel()
      jobs.finish(id, cancellation)
      return nil
    }
    return (started, cancellation)
  }

  public func isCurrent(_ started: Int) -> Bool { epoch.isCurrent(started) }

  @discardableResult
  public func forget() -> Int {
    let next = epoch.advance()
    clear(before: next)
    return next
  }

  public func forget(owner: Int) {
    guard let next = epoch.advance(owner: owner) else { return }
    clear(before: next)
  }

  public func keep(cookies: [Cookie], addresses: [ImportedAddress], cards: [ImportedCard], started: Int) -> String? {
    vault.keep(cookies: cookies, addresses: addresses, cards: cards, epoch: epoch, started: started)
  }

  func clear(before next: Int) {
    jobs.cancelAll(before: next)
    importer.forgetKeys(before: next)
    vault.discardAll(before: next)
  }
}

public final class ImportJobs: @unchecked Sendable {
  private let lock = NSLock()
  private var running: [String: (cancellation: Cancellation, epoch: Int)] = [:]

  public init() {}

  public func start(_ id: String, epoch: Int = Int.min) -> Cancellation {
    let c = Cancellation()
    lock.withLock { running[id] = (c, epoch) }
    return c
  }

  public func cancel(_ id: String) { lock.withLock { running[id]?.cancellation }?.cancel() }

  public func finish(_ id: String, _ cancellation: Cancellation) {
    lock.withLock { if running[id]?.cancellation === cancellation { running[id] = nil } }
  }

  public func cancelAll() { cancelAll(before: Int.max) }

  var count: Int { lock.withLock { running.count } }

  public func cancelAll(before epoch: Int) {
    let stale = lock.withLock { () -> [Cancellation] in
      let ids = running.filter { $0.value.epoch < epoch }.map(\.key)
      return ids.compactMap { running.removeValue(forKey: $0)?.cancellation }
    }
    for c in stale { c.cancel() }
  }
}

public final class ImportVault: @unchecked Sendable {
  public struct Entry {
    public var cookies: [Cookie]
    public var addresses: [ImportedAddress]
    public var cards: [ImportedCard]
    var kept: Date
    var epoch: Int
  }

  private static let lifetime: TimeInterval = 600
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  #if DEBUG
  let betweenCheckAndInsert = DevHook()
  #endif

  public init() {}

  public func keep(cookies: [Cookie], addresses: [ImportedAddress], cards: [ImportedCard], epoch: ImportEpoch, started: Int) -> String? {
    guard !cookies.isEmpty || !addresses.isEmpty || !cards.isEmpty else { return nil }
    let token = UUID().uuidString
    let kept = lock.withLock { () -> Bool in
      guard epoch.isCurrent(started) else { return false }
      #if DEBUG
      betweenCheckAndInsert()
      #endif
      purge()
      entries[token] = Entry(cookies: cookies, addresses: addresses, cards: cards, kept: Date(), epoch: started)
      return true
    }
    guard kept else { return nil }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.lifetime + 1) { [weak self] in
      self?.lock.withLock { self?.purge() }
    }
    return token
  }

  public func take(_ token: String) -> Entry? {
    lock.withLock {
      purge()
      return entries.removeValue(forKey: token)
    }
  }

  public func discard(_ token: String) { _ = take(token) }
  public func discardAll() { lock.withLock { entries.removeAll() } }
  public func discardAll(before epoch: Int) { lock.withLock { entries = entries.filter { $0.value.epoch >= epoch } } }

  var count: Int { lock.withLock { entries.count } }

  private func purge() {
    let cutoff = Date().addingTimeInterval(-Self.lifetime)
    entries = entries.filter { $0.value.kept > cutoff }
  }
}

#if DEBUG
final class DevHook: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (() -> Void)?

  func set(_ action: (() -> Void)?) { lock.withLock { self.action = action } }

  func callAsFunction() { lock.withLock { action }?() }
}
#endif
