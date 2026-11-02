import Foundation

enum PairingInstallationRecovery {
  enum Stage: CaseIterable {
    case prepared
    case keySaved
    case document
  }

  enum Disposition: Equatable {
    case unused
    case saved
    case orphan
    case blocked
  }

  static func reconcile(stage: Stage, selectedCID: Data, account: String, keys: PairingInstallationKeyStoring, installation: PairingInstallation? = nil, store: PairingAccountingStoring? = nil, localVersion: Int = 2) -> Disposition {
    guard localVersion == 2, selectedCID.count == 16, !account.isEmpty else { return .blocked }
    let decision: PairingInstallationDecision?
    if let installation, let store {
      guard installation.device == account, (try? PairingFormat.cid(installation.cid)) == selectedCID else { return .blocked }
      do {
        decision = try store.installationDecision(for: installation)
        guard decision == nil || decision?.installation == installation else { return .blocked }
      } catch { return .blocked }
    } else { decision = nil }
    switch keys.pairingLookup(account: account) {
    case .absent:
      return stage == .prepared && decision?.disposition != .admitted ? .unused : .blocked
    case .failure:
      return .blocked
    case .found(let root):
      guard root.count == 32, let derived = try? PairingFormat.cid(SyncKeys(entropy: root).chainTag), PairingCrypto.equal(derived, selectedCID) else { return .blocked }
      return decision?.disposition == .admitted ? .saved : .orphan

    }
  }
}
