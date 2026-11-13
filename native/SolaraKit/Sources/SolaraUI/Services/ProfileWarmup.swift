import Foundation

public struct ProfileWarmHistory: Codable, Equatable, Sendable {
  public static let limit = 8
  public private(set) var recent: [String]

  public init(recent: [String] = []) {
    var seen = Set<String>()
    self.recent = Array(recent.filter { seen.insert($0).inserted }.prefix(Self.limit))
  }

  @discardableResult
  public mutating func switched(to profileId: String) -> Bool {
    guard recent.first != profileId else { return false }
    recent.removeAll { $0 == profileId }
    recent.insert(profileId, at: 0)
    if recent.count > Self.limit { recent.removeLast(recent.count - Self.limit) }
    return true
  }

  @discardableResult
  public mutating func keepOnly(_ profiles: Set<String>) -> Bool {
    let kept = recent.filter { profiles.contains($0) }
    guard kept != recent else { return false }
    recent = kept
    return true
  }
}

public struct ProfileIntentDebounce: Sendable {
  public static let delay: TimeInterval = 0.15

  public enum Change: Equatable, Sendable {
    case schedule(TimeInterval)
    case keep
    case cancel
  }

  public private(set) var pending: String?
  public private(set) var dueAt: TimeInterval?

  public init() {}

  public mutating func hover(_ profileId: String?, now: TimeInterval) -> Change {
    guard let profileId else {
      pending = nil
      dueAt = nil
      return .cancel
    }
    if profileId == pending { return .keep }
    pending = profileId
    dueAt = now + Self.delay
    return .schedule(now + Self.delay)
  }

  public mutating func fire(now: TimeInterval) -> String? {
    guard let pending, let dueAt, now + 0.001 >= dueAt else { return nil }
    self.pending = nil
    self.dueAt = nil
    return pending
  }
}

public struct IdleWarmSchedule: Sendable {
  public static let idleSeconds: Double = 10

  public enum Decision: Equatable, Sendable {
    case wait(TimeInterval)
    case warm
  }

  public let startedAt: TimeInterval
  public private(set) var done = false

  public init(startedAt: TimeInterval) {
    self.startedAt = startedAt
  }

  public mutating func check(now: TimeInterval, inputIdleSeconds: Double, launchSettled: Bool) -> Decision? {
    guard !done else { return nil }
    let sinceLaunch = now - startedAt
    guard sinceLaunch >= Self.idleSeconds else { return .wait(Self.idleSeconds - sinceLaunch) }
    guard launchSettled else { return .wait(1) }
    guard inputIdleSeconds >= Self.idleSeconds else { return .wait(max(1, Self.idleSeconds - inputIdleSeconds)) }
    done = true
    return .warm
  }
}

public enum ProfileWarmup {
  public static func idleTarget(
    recent: [String], engines: [String: String], shownEngines: Set<String>, loadAll: Bool, lowPower: Bool
  ) -> String? {
    guard !loadAll, !lowPower else { return nil }
    for id in recent {
      guard let engine = engines[id] else { continue }
      if shownEngines.contains(engine) { continue }
      return engine
    }
    return nil
  }

  public static func historyURL(environment: [String: String], applicationSupport: URL?, bundleId: String?) -> URL? {
    let folder: URL
    if let scratch = environment["SOLARA_DATA_DIR"], !scratch.isEmpty {
      folder = URL(fileURLWithPath: (scratch as NSString).standardizingPath, isDirectory: true)
    } else if let applicationSupport {
      folder = applicationSupport.appending(path: bundleId ?? "Solara", directoryHint: .isDirectory)
    } else {
      return nil
    }
    return folder.appending(path: "profile-warmup.json", directoryHint: .notDirectory)
  }
}
