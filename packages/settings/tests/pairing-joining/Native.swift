import Foundation

public final class PairingServices: PairingJoining {
  public static let shared = PairingServices()
  public var starts: [(String?, String)] = []
  public var handle = Handle()
  public var callback: (@MainActor (PairingJoinState) -> Void)?
  public var committed = true
  public func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    start(folder: nil, cid: cid, onState: onState)
  }
  public func start(folder: String?, cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    starts.append((folder, cid)); callback = onState; return handle
  }
  public func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool {
    callback = onState; return committed
  }
  public final class Handle: PairingJoinHandle {
    public var cancellations = 0
    public var retries = 0
    public var result = PairingCancelResult.unavailable
    public func cancel() -> PairingCancelResult { cancellations += 1; return result }
    public func startAgain() { retries += 1 }
  }
}

public enum SyncDiscoveryOutcome {
  case found([Candidate]), empty, needsHydration, unavailable, permissionDenied, timedOut
  public struct Candidate { public var cid: String; public var lastActivity: Date? }
}
public enum SyncDiscoveryBridge {
  public static func run(folder: URL, completion: @escaping (SyncDiscoveryOutcome) -> Void) {}
}
