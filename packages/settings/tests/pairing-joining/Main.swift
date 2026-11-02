import Foundation
import SolaraSyncAdapter
import SolaraUI

@main struct Probe {
  @MainActor static func main() async {
    let owner = PairingServices.shared
    let bridge = OnboardingPairingBridge(PairingJoiningAdapter(folder: "/fixture/custom"))
    var seen: [SolaraUI.PairingJoinState] = []
    let handle = bridge.start(cid: "fixture-cid") { seen.append($0) }
    precondition(owner.starts.count == 1)
    precondition(owner.starts[0].0 == "/fixture/custom" && owner.starts[0].1 == "fixture-cid")
    let deadline = ContinuousClock.now
    let states: [SolaraSyncAdapter.PairingJoinState] = [.preparing, .waiting(expires: deadline), .comparing(code: "ABC DEF", claimedName: "Fixture"), .approved, .installed, .failed(.expired), .failed(.denied), .failed(.mismatch), .failed(.folderUnavailable), .failed(.invalidPeer), .failed(.cancelled)]
    let expected: [SolaraUI.PairingJoinState] = [.preparing, .waiting(expires: deadline), .comparing(code: "ABC DEF", claimedName: "Fixture"), .approved, .installed, .failed(.expired), .failed(.denied), .failed(.mismatch), .failed(.folderUnavailable), .failed(.invalidPeer), .failed(.cancelled)]
    for state in states { owner.callback?(state) }
    precondition(seen == expected)
    precondition(handle.cancel() == .unavailable)
    owner.handle.result = .cancelled
    precondition(handle.cancel() == .cancelled)
    owner.handle.result = .alreadyCommitted
    precondition(handle.cancel() == .alreadyCommitted)
    handle.startAgain()
    precondition(owner.handle.retries == 1 && owner.handle.cancellations == 3)
    precondition(bridge.committedJoin { seen.append($0) })
    precondition(owner.starts.count == 1)
    owner.callback?(.installed)
    precondition(seen.last == .installed)
    owner.committed = false
    precondition(!bridge.committedJoin { _ in })
    print("Completed onboarding bridge: 1 test, 11 assertions, 0 failures")
  }
}
