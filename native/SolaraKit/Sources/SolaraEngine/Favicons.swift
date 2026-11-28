import Foundation

public struct FaviconLookup: Sendable, Equatable {
  public var data: Data
  public var source: String

  public init(data: Data, source: String) {
    self.data = data
    self.source = source
  }
}

public extension EngineClient {
  func storedFavicon(page: String, engineProfile: String) async throws -> Data? { nil }
  func fetchFavicon(source: String, engineProfile: String) async -> Data? { nil }
  func bundledFavicon(page: String, dark: Bool) async -> Data? { nil }
  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws {}
}

@MainActor
public final class FaviconLibrary {
  nonisolated public static let didInvalidate = Notification.Name("SolaraFaviconInvalidated")
  nonisolated public static let didEndPrivateSession = Notification.Name("SolaraPrivateSessionEnded")
  struct Key: Hashable {
    var page: String
    var source: String
    var engineProfile: Data
    var dark: Bool
  }

  enum Entry {
    case found(FaviconLookup)
    case reported(FaviconLookup)
    case missing(since: Date)

    var result: FaviconLookup? {
      switch self {
      case .found(let result), .reported(let result): result
      case .missing: nil
      }
    }
  }

  private final class Request {
    var invalidated = false
  }

  private let client: any EngineClient
  private let limit: Int
  private let missLifetime: TimeInterval
  private let now: () -> Date
  private var cache: [Key: Entry] = [:]
  private var order: [Key] = []
  private var pending: [Key: (request: Request, task: Task<FaviconLookup?, Never>)] = [:]
  private var liveRequests: [Key: Request] = [:]
  private var retiredProfiles: Set<Data> = []
  nonisolated(unsafe) private var privateSessionObservation: NSObjectProtocol?

  public init(client: any EngineClient, limit: Int = 3_000, missLifetime: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
    self.client = client
    self.limit = max(1, limit)
    self.missLifetime = missLifetime
    self.now = now
    privateSessionObservation = NotificationCenter.default.addObserver(forName: Self.didEndPrivateSession, object: nil, queue: .main) { [weak self] notification in
      let aliases = notification.userInfo?["aliases"] as? [String] ?? []
      MainActor.assumeIsolated { self?.endPrivateSession(engineProfiles: aliases) }
    }
  }

  deinit {
    if let privateSessionObservation { NotificationCenter.default.removeObserver(privateSessionObservation) }
  }

  public func endPrivateSession(engineProfiles: [String]) {
    for profile in engineProfiles where profile.hasPrefix("incognito:") {
      retiredProfiles.insert(Data(profile.utf8))
      invalidate(engineProfile: profile)
    }
  }

  public var cachedCount: Int { cache.count }

  public func cachedFavicon(page: String, source: String?, engineProfile: String, appearance dark: Bool) -> FaviconLookup? {
    let key = Key(page: String(page.prefix { $0 != "#" }), source: source ?? "", engineProfile: Data(engineProfile.utf8), dark: dark)
    if let result = cache[key]?.result { return result }
    var canonical = key
    canonical.source = ""
    return cache[canonical]?.result
  }

  public func favicon(page: String, source: String? = nil, engineProfile: String, appearance dark: Bool) async -> FaviconLookup? {
    await lookup(page: page, source: source, engineProfile: engineProfile, dark: dark)
  }

  public func notePageIcon(page: String, source: String, engineProfile: String, dark: Bool, load: @escaping @MainActor () async -> Data?) async {
    guard !source.isEmpty, !page.isEmpty, !retiredProfiles.contains(Data(engineProfile.utf8)) else { return }
    let key = Key(page: String(page.prefix { $0 != "#" }), source: source, engineProfile: Data(engineProfile.utf8), dark: dark)
    var canonical = key
    canonical.source = ""
    let report = Request()
    liveRequests[canonical] = report
    defer { if liveRequests[canonical] === report { liveRequests[canonical] = nil } }
    let previous = cache[key]
    if let existing = pending.removeValue(forKey: key) { existing.request.invalidated = true }
    cache[key] = nil
    order.removeAll { $0 == key }
    let result = await lookup(page: page, source: source, engineProfile: engineProfile, dark: dark, live: load)
    guard let result, liveRequests[canonical] === report else { return }
    if previous?.result == result, cache[canonical]?.result == result { return }
    if let existing = pending.removeValue(forKey: canonical) { existing.request.invalidated = true }
    insert(.reported(result), for: canonical)
    NotificationCenter.default.post(name: Self.didInvalidate, object: nil)
  }

  public func adopt(page: String, source: String, data: Data, engineProfile: String) {
    guard !engineProfile.hasPrefix("incognito:"), !page.isEmpty, !data.isEmpty else { return }
    let page = String(page.prefix { $0 != "#" })
    let profile = Data(engineProfile.utf8)
    let result = FaviconLookup(data: data, source: "source")
    for dark in [false, true] {
      for source in Set([source, ""]) {
        let key = Key(page: page, source: source, engineProfile: profile, dark: dark)
        if let previous = cache[key]?.result, previous.source != "bundled" { continue }
        pending.removeValue(forKey: key)?.request.invalidated = true
        insert(.found(result), for: key)
      }
    }
  }

  private func insert(_ entry: Entry, for key: Key) {
    if cache[key] != nil { order.removeAll { $0 == key } }
    cache[key] = entry
    order.append(key)
    if order.count > limit { cache[order.removeFirst()] = nil }
  }

  private func lookup(page: String, source: String?, engineProfile: String, dark: Bool, live: (@MainActor () async -> Data?)? = nil) async -> FaviconLookup? {
    guard !retiredProfiles.contains(Data(engineProfile.utf8)), !page.isEmpty || !(source ?? "").isEmpty else { return nil }
    let key = Key(page: String(page.prefix { $0 != "#" }), source: source ?? "", engineProfile: Data(engineProfile.utf8), dark: dark)
    if let entry = cache[key] {
      switch entry {
      case .found(let result), .reported(let result): return result
      case .missing(let since) where now().timeIntervalSince(since) < missLifetime: return nil
      case .missing:
        cache[key] = nil
        order.removeAll { $0 == key }
      }
    }
    if let pending = pending[key] {
      let result = await pending.task.value
      return pending.request.invalidated ? nil : result
    }
    if live == nil, !key.source.isEmpty {
      var canonical = key
      canonical.source = ""
      if case .reported(let result) = cache[canonical] { return result }
    }
    let request = Request()
    let client = client
    let task = Task<FaviconLookup?, Never> { @MainActor in
      let privateProfile = engineProfile.hasPrefix("incognito:")
      if let live, let data = await live(), !data.isEmpty {
        return FaviconLookup(data: data, source: "source")
      }
      guard !request.invalidated else { return nil }
      if !privateProfile, !key.page.isEmpty, let data = try? await client.storedFavicon(page: key.page, engineProfile: engineProfile), !data.isEmpty {
        return FaviconLookup(data: data, source: "chrome")
      }
      if !key.source.isEmpty, let data = await client.fetchFavicon(source: key.source, engineProfile: engineProfile), !data.isEmpty {
        if !privateProfile, !key.page.isEmpty, (key.source.hasPrefix("http://") || key.source.hasPrefix("https://")), !request.invalidated {
          try? await client.storeFavicon(page: key.page, source: key.source, data: data, engineProfile: engineProfile)
        }
        return FaviconLookup(data: data, source: "source")
      }
      if let data = await client.bundledFavicon(page: key.page, dark: dark), !data.isEmpty {
        return FaviconLookup(data: data, source: "bundled")
      }
      return nil
    }
    pending[key] = (request, task)
    let result = await task.value
    if !request.invalidated {
      insert(result.map(Entry.found) ?? .missing(since: now()), for: key)
    }
    if pending[key]?.request === request { pending[key] = nil }
    return request.invalidated ? nil : result
  }

  public func forgetMisses(engineProfile: String, pages: [String]) {
    let shown = Set(pages.map { String($0.prefix { $0 != "#" }) })
    let keys = cache.compactMap { key, entry -> Key? in
      guard case .missing = entry, key.engineProfile == Data(engineProfile.utf8), shown.contains(key.page) else { return nil }
      return key
    }
    guard !keys.isEmpty else { return }
    let gone = Set(keys)
    for key in keys { cache[key] = nil }
    order.removeAll { gone.contains($0) }
    NotificationCenter.default.post(name: Self.didInvalidate, object: nil)
  }

  public func invalidate(engineProfile: String, pages: [String]? = nil) {
    let gone = pages.map { Set($0.map { String($0.prefix { $0 != "#" }) }) }
    let profile = Data(engineProfile.utf8)
    func affected(_ key: Key) -> Bool { key.engineProfile == profile && (gone?.contains(key.page) ?? true) }
    let keys = cache.keys.filter(affected)
    for key in keys { cache[key] = nil }
    order.removeAll(where: affected)
    for key in pending.keys.filter(affected) {
      pending.removeValue(forKey: key)?.request.invalidated = true
    }
    for key in liveRequests.keys.filter(affected) { liveRequests[key] = nil }
    NotificationCenter.default.post(name: Self.didInvalidate, object: nil)
  }
}
