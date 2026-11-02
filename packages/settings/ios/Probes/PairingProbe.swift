#if SOLARA_PROBES
import Foundation
import SolaraSyncAdapter

@MainActor
public enum PairingProbe {
  public enum Refusal: Error {
    case invalid
    case notReady
    case unsupported
  }

  private static var arm: PairingNativeArm?
  private static var comparison: PairingNativeComparison?

  public static func enableSync(folder: String) async -> [String: Any] {
    let failure = await SyncAdapter().turnOnSync(folder: folder)
    return ["enabled": failure == nil, "failure": failure ?? NSNull()]
  }

  public static func armTrusted() throws -> [String: Any] {
    guard arm == nil else { throw Refusal.notReady }
    let made: PairingNativeArm
    do { made = try PairingServices.shared.arm() }
    catch { return ["armed": false, "refusal": String(describing: error)] }
    arm = made
    comparison = nil
    return ["armed": true]
  }

  public static func selectTrusted() throws -> [String: Any] {
    guard let arm else { throw Refusal.notReady }
    let requests = try PairingServices.shared.requests(arm)
    guard requests.count == 1, let request = requests.first else { throw Refusal.notReady }
    try PairingServices.shared.select(request, arm: arm)
    try PairingServices.shared.present(arm)
    return ["selected": true]
  }

  public static func trustedState() -> [String: Any] {
    let snapshot = PairingServices.shared.trustedSnapshot(arm)
    var read: [String: Any] = ["phase": arm == nil && snapshot.phase == "idle" ? "idle" : snapshot.phase, "requests": snapshot.requests.count, "armed": arm != nil, "eligible": snapshot.eligible, "markerVerified": snapshot.markerVerified]
    if snapshot.phase == "comparing", let arm, let current = try? PairingServices.shared.comparison(arm) {
      comparison = current
      read["code"] = current.code
      read["claimedName"] = current.claimedName
    }
    return read
  }

  public static func decideTrusted(_ decision: String) throws -> [String: Any] {
    switch decision {
    case "deny":
      guard let arm else { return ["accepted": false] }
      PairingServices.shared.end(arm)
      Self.arm = nil
      comparison = nil
    case "notMe":
      guard let arm else { return ["accepted": false] }
      PairingServices.shared.end(arm, unexpected: true)
      Self.arm = nil
      comparison = nil
    case "allow":
      guard arm != nil, comparison != nil else { return ["accepted": false] }
      throw Refusal.unsupported
    default:
      throw Refusal.invalid
    }
    return ["accepted": true, "phase": PairingServices.shared.trustedSnapshot(arm).phase]
  }

  public static func reset() {
    if let arm { PairingServices.shared.end(arm) }
    arm = nil
    comparison = nil
  }
}
#endif
