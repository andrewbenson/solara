import Foundation
import SolaraModel

public final class EarlyLaunchTabProvider: Sendable {
  private let store: Store
  private let environment: String?
  private let readCache: @Sendable () -> Data?

  public init(store: Store, environment: String?, readCache: @escaping @Sendable () -> Data?) {
    self.store = store
    self.environment = environment
    self.readCache = readCache
  }

  public static func resolve(environment: String?, cache: Data?) -> Bool {
    var override: Bool?
    for part in (environment ?? "").components(separatedBy: ",") {
      let pair = part.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      guard pair.count >= 2, pair[0] == "launchTab" else { continue }
      switch pair[1] {
      case "off", "0", "false": override = false
      case "on", "1", "true": override = true
      default: break
      }
    }
    if let override { return override }
    guard let cache, let document = try? JSONValue.parse(cache) else { return true }
    return document["switches"]?["launchTab"] != .bool(false)
  }

  public func refresh() throws {
    let enabled = Self.resolve(environment: environment, cache: readCache())
    guard store.displayState.caches.earlyLaunchTab != enabled else { return }
    try store.transact { session in
      session.update { $0.caches.earlyLaunchTab = enabled }
    }
  }
}

public final class LastTabPolicyProvider: Sendable {
  private let store: Store

  public init(store: Store) { self.store = store }

  public func receive(_ reply: JSONValue) throws {
    try store.transact { $0.memory.lastTabKeepsWindow = reply["closesWindow"] == .bool(false) }
  }
}

public extension Store {
  func updateAppAppearance(_ dark: Bool) throws {
    try transact { session in
      session.update { $0.caches.systemDark = dark }
    }
  }
}
