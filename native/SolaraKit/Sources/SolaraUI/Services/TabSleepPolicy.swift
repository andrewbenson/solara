public enum TabSleepPolicy {
  public struct Configuration: Decodable, Sendable {
    public let idleMs: Double
    public let protectedRecent: Int
    public let perSweep: Int

    public init(idleMs: Double = 1_800_000, protectedRecent: Int = 10, perSweep: Int = 6) {
      self.idleMs = idleMs
      self.protectedRecent = protectedRecent
      self.perSweep = perSweep
    }
  }

  public struct Tab: Decodable, Sendable {
    public let id: String
    public let url: String
    public let profileId: String
    public let lastActiveAt: Double

    public init(id: String, url: String, profileId: String, lastActiveAt: Double) {
      self.id = id
      self.url = url
      self.profileId = profileId
      self.lastActiveAt = lastActiveAt
    }
  }

  public enum Pressure: String, Decodable, Sendable {
    case normal
    case warning
    case critical
  }

  public struct UnusedProfilesResult: Sendable {
    public let unusedSince: [String: Double]
    public let eligibleIds: [String]
  }

  public static func candidates(
    tabs: [Tab],
    shownIds: Set<String>,
    discardedIds: Set<String>,
    loadedIds: [String],
    hiddenAt: [String: Double],
    now: Double,
    pressure: Pressure,
    unusedProfileIds: Set<String>,
    policy: Configuration,
    keepAliveReasons: [String: String]
  ) -> [String] {
    let recent = Set(tabs.enumerated().filter { !$0.element.url.isEmpty }.sorted {
      if $0.element.lastActiveAt == $1.element.lastActiveAt { return $0.offset < $1.offset }
      return $0.element.lastActiveAt > $1.element.lastActiveAt
    }.prefix(pressure == .critical ? 0 : max(0, policy.protectedRecent)).map { $0.element.id })
    let byId = tabs.reduce(into: [String: Tab]()) { $0[$1.id] = $1 }
    return loadedIds.enumerated().filter {
      let id = $0.element
      guard let tab = byId[id], !shownIds.contains(id), !discardedIds.contains(id) else { return false }
      let idle = now - (hiddenAt[id] ?? now)
      if !unusedProfileIds.contains(tab.profileId)
        && (recent.contains(id) || (pressure == .normal && idle < policy.idleMs)) { return false }
      return keepAliveReasons[id]?.isEmpty != false
    }.sorted {
      let first = hiddenAt[$0.element] ?? now
      let second = hiddenAt[$1.element] ?? now
      if first == second { return $0.offset < $1.offset }
      return first < second
    }.map(\.element)
  }

  public static func unusedProfiles(
    profileIds: [String],
    shownProfileIds: Set<String>,
    unusedSince: [String: Double],
    now: Double,
    idleMs: Double
  ) -> UnusedProfilesResult {
    var next: [String: Double] = [:]
    var eligible: [String] = []
    for id in profileIds where !shownProfileIds.contains(id) {
      let since = unusedSince[id] ?? now
      next[id] = since
      if now - since >= idleMs { eligible.append(id) }
    }
    return UnusedProfilesResult(unusedSince: next, eligibleIds: eligible)
  }
}
