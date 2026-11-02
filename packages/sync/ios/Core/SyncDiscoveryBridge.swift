import Foundation

public enum SyncDiscoveryOutcome: Equatable, Sendable {
  public struct Candidate: Equatable, Sendable {
    public let cid: String
    public let lastActivity: Date?

    public init(cid: String, lastActivity: Date?) {
      self.cid = cid
      self.lastActivity = lastActivity
    }
  }

  case found([Candidate])
  case empty, needsHydration, unavailable, permissionDenied, timedOut
}

public enum SyncDiscoveryBridge {
  public static func run(folder: URL, timeout: Duration = .seconds(10), done: @escaping @Sendable (SyncDiscoveryOutcome) -> Void) {
    SyncDiscovery(folder: folder, timeout: timeout).run { result in
      switch result {
      case .found(let candidates): done(.found(candidates.map { .init(cid: $0.cid, lastActivity: $0.lastActivity) }))
      case .empty: done(.empty)
      case .needsHydration: done(.needsHydration)
      case .unavailable: done(.unavailable)
      case .permissionDenied: done(.permissionDenied)
      case .timedOut: done(.timedOut)
      }
    }
  }
}
