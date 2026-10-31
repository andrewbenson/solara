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
  public static let didInvalidate = Notification.Name("SolaraFaviconInvalidated")
  struct Key: Hashable {
    var page: String
    var source: String
    var engineProfile: String
    var dark: Bool
  }

  enum Entry {
    case found(FaviconLookup)
    case missing(since: Date)
  }

  private let client: any EngineClient
  private let limit: Int
  private let missLifetime: TimeInterval
  private let now: () -> Date
  private var cache: [Key: Entry] = [:]
  private var order: [Key] = []
  private var pending: [Key: (generation: Int, task: Task<FaviconLookup?, Never>)] = [:]
  private var generations: [String: Int] = [:]

  public init(client: any EngineClient, limit: Int = 3_000, missLifetime: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
    self.client = client
    self.limit = max(1, limit)
    self.missLifetime = missLifetime
    self.now = now
  }

  public var cachedCount: Int { cache.count }

  public func favicon(page: String, source: String? = nil, engineProfile: String, appearance dark: Bool) async -> FaviconLookup? {
    guard !page.isEmpty || !(source ?? "").isEmpty else { return nil }
    let key = Key(page: String(page.prefix { $0 != "#" }), source: source ?? "", engineProfile: engineProfile, dark: dark)
    if let entry = cache[key] {
      switch entry {
      case .found(let result): return result
      case .missing(let since) where now().timeIntervalSince(since) < missLifetime: return nil
      case .missing:
        cache[key] = nil
        order.removeAll { $0 == key }
      }
    }
    if let pending = pending[key] {
      let result = await pending.task.value
      return generations[engineProfile, default: 0] == pending.generation ? result : nil
    }
    let generation = generations[engineProfile, default: 0]
    let client = client
    let task = Task<FaviconLookup?, Never> { @MainActor in
      let privateProfile = engineProfile.hasPrefix("incognito:")
      if !privateProfile, !key.page.isEmpty, let data = try? await client.storedFavicon(page: key.page, engineProfile: engineProfile), !data.isEmpty {
        return FaviconLookup(data: data, source: "chrome")
      }
      if !key.source.isEmpty, let data = await client.fetchFavicon(source: key.source, engineProfile: engineProfile), !data.isEmpty {
        if !privateProfile, !key.page.isEmpty, (key.source.hasPrefix("http://") || key.source.hasPrefix("https://")), generations[engineProfile, default: 0] == generation {
          try? await client.storeFavicon(page: key.page, source: key.source, data: data, engineProfile: engineProfile)
        }
        return FaviconLookup(data: data, source: "source")
      }
      if let data = await client.bundledFavicon(page: key.page, dark: dark), !data.isEmpty {
        return FaviconLookup(data: data, source: "bundled")
      }
      return nil
    }
    pending[key] = (generation, task)
    let result = await task.value
    if generations[engineProfile, default: 0] == generation {
      cache[key] = result.map(Entry.found) ?? .missing(since: now())
      order.append(key)
      if order.count > limit { cache[order.removeFirst()] = nil }
    }
    if pending[key]?.generation == generation { pending[key] = nil }
    return generations[engineProfile, default: 0] == generation ? result : nil
  }

  public func forgetMisses(engineProfile: String, pages: [String]) {
    let shown = Set(pages.map { String($0.prefix { $0 != "#" }) })
    let keys = cache.compactMap { key, entry -> Key? in
      guard case .missing = entry, key.engineProfile == engineProfile, shown.contains(key.page) else { return nil }
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
    generations[engineProfile, default: 0] += 1
    let keys = cache.keys.filter { $0.engineProfile == engineProfile && (gone == nil || gone!.contains($0.page)) }
    for key in keys { cache[key] = nil }
    order.removeAll { key in key.engineProfile == engineProfile && (gone == nil || gone!.contains(key.page)) }
    pending = pending.filter { key, _ in key.engineProfile != engineProfile || (gone != nil && !gone!.contains(key.page)) }
    NotificationCenter.default.post(name: Self.didInvalidate, object: nil)
  }
}
