import Foundation
import SolaraModel

public struct ExtensionCatalogLifecycle {
  public static let coalesceDelay = 0.15
  public static let pollInterval = 1.5
  public static func forcePolling(_ value: String?) -> Bool { value == "on" }
  public private(set) var lists: [String: [JSONObject]] = [:]
  private var loaded: Set<String> = []
  private var running: [String: UUID] = [:]
  private var trailing: Set<String> = []
  private var dirtyLists: Set<String> = []
  private var dirtyActions: Set<String> = []

  public init() {}

  public mutating func loadProfiles(_ profiles: [String]) -> [String] {
    profiles.filter { loaded.insert($0).inserted }
  }

  public mutating func begin(_ profile: String, afterChange: Bool = false) -> UUID? {
    if running[profile] != nil {
      if afterChange { trailing.insert(profile) }
      return nil
    }
    let request = UUID()
    running[profile] = request
    return request
  }

  @discardableResult
  public mutating func finish(_ profile: String, request: UUID, rows: [JSONObject]?) -> Bool {
    guard running[profile] == request else { return false }
    running[profile] = nil
    if let rows {
      lists[profile] = rows.sorted {
        ($0["name"]?.string ?? "").compare($1["name"]?.string ?? "", options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedAscending
      }
    }
    return trailing.remove(profile) != nil
  }

  public func visible(_ profile: String, privateWindow: Bool) -> [JSONObject] {
    (lists[profile] ?? []).filter {
      $0["enabled"]?.truthy == true && (!privateWindow || ($0["incognito"]?.truthy == true && $0["incognitoSplit"]?.truthy == true))
    }
  }

  public mutating func patch(_ profile: String, id: String, values: JSONObject) {
    guard var rows = lists[profile], let index = rows.firstIndex(where: { $0["id"]?.string == id }) else { return }
    for (key, value) in values { rows[index][key] = value }
    lists[profile] = rows
  }

  public mutating func changed(_ profile: String, registry: Bool) {
    if registry { dirtyLists.insert(profile) } else { dirtyActions.insert(profile) }
  }

  public mutating func flush(active: Bool) -> (lists: Set<String>, actions: Set<String>)? {
    guard active, !dirtyLists.isEmpty || !dirtyActions.isEmpty else { return nil }
    defer { dirtyLists.removeAll(); dirtyActions.removeAll() }
    return (dirtyLists.intersection(loaded), dirtyActions)
  }

  public mutating func invalidate() { self = Self() }
}

public struct ExtensionActionCache {
  public private(set) var states: [Int: JSONValue] = [:]
  private var browsers: [PageRegistration: Int] = [:]
  private var owners: [Int: PageRegistration] = [:]

  public init() {}

  public func state(browserId: Int, registration: PageRegistration) -> JSONObject? {
    guard owners[browserId] == registration else { return nil }
    return states[browserId]?.object
  }

  public mutating func refresh(ids: [String], target: () -> (PageRegistration, Int)?, read: (Int, [String]) -> JSONValue?) {
    guard !ids.isEmpty, let (registration, browserId) = target(), browserId != 0 else { return }
    if let previous = browsers[registration], previous != browserId { retire(registration) }
    if let owner = owners[browserId], owner != registration { retire(owner) }
    guard let value = read(browserId, ids) else { return }
    browsers[registration] = browserId
    owners[browserId] = registration
    states[browserId] = value
  }

  @discardableResult
  public mutating func retire(_ registration: PageRegistration) -> Bool {
    guard let browserId = browsers.removeValue(forKey: registration) else { return false }
    states[browserId] = nil
    owners[browserId] = nil
    return true
  }
}
