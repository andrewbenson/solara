import Foundation
import LocalAuthentication
import XCTest
@testable import SolaraLegacySyncCore

final class PairingOwnerAuthenticationTests: XCTestCase {
  final class Context: SyntheticPairingAuthenticationContext {
    var touchIDAuthenticationAllowableReuseDuration: TimeInterval = 99
    var available = true
    var policies: [LAPolicy] = []
    var reasons: [String] = []
    var reply: ((Bool, Error?) -> Void)?
    var invalidations = 0
    func canEvaluatePolicy(_ policy: LAPolicy) -> Bool { policies.append(policy); return available }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void) {
      policies.append(policy)
      reasons.append(localizedReason)
      self.reply = reply
    }
    func invalidate() { invalidations += 1 }
  }

  func tuple() -> PairingSession.Authorization {
    .init(handle: Data([1]), transcript: Data([2]), cid: Data([3]), rid: Data([4]), aid: Data([5]), folderIdentity: Data([6]), folderGeneration: 1, entropyHandle: Data([7]), entropyGeneration: 2, sessionGeneration: 3, comparisonGeneration: 4, armGeneration: 5, armDeadline: 120000, requestDeadline: 300000, nameCommitment: Data([8]))
  }

  func testPanelLifetimeEndsAtReplyBeforeAdjudication() {
    let context = Context()
    var evaluation: (() -> Void)?
    var adjudication: (() -> Void)?
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { evaluation = $0 }, scheduleReply: { adjudication = $0 })
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { _ in callbacks += 1 })
    XCTAssertFalse(attempt.panelLive)
    evaluation?()
    XCTAssertTrue(attempt.panelLive)
    context.reply?(true, nil)
    XCTAssertFalse(attempt.panelLive)
    XCTAssertEqual(callbacks, 0)
    adjudication?()
    XCTAssertEqual(callbacks, 1)
    XCTAssertFalse(attempt.panelLive)
  }

  func testReplySurfaceHandoffDoesNotHoldAttemptLock() {
    let context = Context()
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context })
    let attempt = PairingCoordinatorTests.Handoff<PairingAuthenticationAttempt?>(nil)
    let cancelled = DispatchSemaphore(value: 0)
    attempt.value = factory.authenticate(tuple(), validate: { _ in true }, replied: { resume in
      DispatchQueue.global().async { attempt.value?.cancel(); cancelled.signal() }
      XCTAssertEqual(cancelled.wait(timeout: .now() + 0.2), .success)
      XCTAssertEqual(context.invalidations, 1)
      resume()
    }, completion: { _ in })
    context.reply?(true, nil)
    withExtendedLifetime(attempt.value) {}
  }

  func testCancellationEndsLivePanelAndRejectsLateReply() {
    let context = Context()
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context })
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { _ in callbacks += 1 })
    XCTAssertTrue(attempt.panelLive)
    attempt.cancel()
    XCTAssertFalse(attempt.panelLive)
    XCTAssertEqual(context.invalidations, 1)
    context.reply?(true, nil)
    XCTAssertEqual(callbacks, 0)
  }

  func testCapabilitySingleUse() {
    let value = tuple(), capability = SyntheticPairingOwnerAuthenticator.authenticated(tuple())
    XCTAssertTrue(capability.consume(matching: value))
    XCTAssertFalse(capability.consume(matching: value))
  }

  func testEveryAuthorizationFieldIsBoundAndMismatchBurnsCapability() {
    let original = tuple()
    var variants: [PairingSession.Authorization] = []
    for key in [\PairingSession.Authorization.handle, \.transcript, \.cid, \.rid, \.aid, \.folderIdentity, \.entropyHandle, \.nameCommitment] {
      var value = original
      value[keyPath: key].append(9)
      variants.append(value)
    }
    for key in [\PairingSession.Authorization.folderGeneration, \.entropyGeneration, \.sessionGeneration, \.comparisonGeneration, \.armGeneration, \.armDeadline, \.requestDeadline] {
      var value = original
      value[keyPath: key] += 1
      variants.append(value)
    }
    for value in variants {
      let capability = SyntheticPairingOwnerAuthenticator.authenticated(original)
      XCTAssertFalse(capability.consume(matching: value))
      XCTAssertFalse(capability.consume(matching: original))
    }
  }

  func testFreshContextPolicyReasonAndSuccess() {
    var contexts: [Context] = []
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { let context = Context(); contexts.append(context); return context }, schedule: { $0() })
    var results: [OwnerAuthentication?] = []
    let first = factory.authenticate(tuple(), validate: { _ in true }, completion: { results.append($0) })
    let second = factory.authenticate(tuple(), validate: { _ in true }, completion: { results.append($0) })
    XCTAssertEqual(contexts.count, 2)
    guard contexts.count == 2 else { return }
    XCTAssertFalse(contexts[0] === contexts[1])
    XCTAssertEqual(contexts[0].touchIDAuthenticationAllowableReuseDuration, 0)
    XCTAssertEqual(contexts[0].policies, [.deviceOwnerAuthentication, .deviceOwnerAuthentication])
    XCTAssertEqual(contexts[0].reasons, ["allow your other Mac to access your synced data, including passwords"])
    XCTAssertEqual(contexts[1].touchIDAuthenticationAllowableReuseDuration, 0)
    contexts[0].reply?(true, nil)
    XCTAssertEqual(results.count, 1)
    XCTAssertTrue((results.first ?? nil)?.consume(matching: tuple()) == true)
    XCTAssertEqual(contexts[0].invalidations, 1)
    withExtendedLifetime([first, second]) {}
  }

  func testFailureBurnsAttemptAndDuplicateSuccessCannotMint() {
    let context = Context()
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() })
    var results: [OwnerAuthentication?] = []
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { results.append($0) })
    context.reply?(false, nil)
    context.reply?(true, nil)
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first ?? nil)
    XCTAssertEqual(context.invalidations, 1)
    withExtendedLifetime(attempt) {}
  }

  func testSuccessWithErrorCannotMint() {
    let context = Context()
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() })
    var result: OwnerAuthentication?
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { result = $0; callbacks += 1 })
    context.reply?(true, NSError(domain: "test", code: 1))
    XCTAssertNil(result)
    XCTAssertEqual(callbacks, 1)
    XCTAssertEqual(context.invalidations, 1)
    withExtendedLifetime(attempt) {}
  }

  func testCancellationBeforeMainHopPreventsContextAndEvaluation() {
    var hop: (() -> Void)?
    var contexts = 0
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { contexts += 1; return Context() }, schedule: { hop = $0 })
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { _ in callbacks += 1 })
    attempt.cancel()
    hop?()
    XCTAssertEqual(contexts, 0)
    XCTAssertEqual(callbacks, 0)
  }

  func testCancellationAfterEvaluationDiscardsLateCallback() {
    let context = Context()
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() })
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { _ in callbacks += 1 })
    attempt.cancel()
    context.reply?(true, nil)
    XCTAssertEqual(callbacks, 0)
    XCTAssertEqual(context.invalidations, 1)
  }

  func testUnavailablePolicyEndsAttemptWithoutEvaluation() {
    let context = Context()
    context.available = false
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() })
    var callbacks = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { result in XCTAssertNil(result); callbacks += 1 })
    XCTAssertEqual(callbacks, 1)
    XCTAssertNil(context.reply)
    XCTAssertEqual(context.invalidations, 1)
    withExtendedLifetime(attempt) {}
  }

  func testRevalidationRejectsChangedTupleAndPreEvaluationEligibility() {
    let context = Context()
    var valid = true
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() })
    var results: [OwnerAuthentication?] = []
    let attempt = factory.authenticate(tuple(), validate: { _ in valid }, completion: { results.append($0) })
    valid = false
    context.reply?(true, nil)
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first ?? nil)
    XCTAssertEqual(context.invalidations, 1)
    var checks = 0
    let rejected = factory.authenticate(tuple(), validate: { _ in checks += 1; return false }, completion: { results.append($0) })
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(results.count, 2)
    XCTAssertNil(results.last ?? nil)
    withExtendedLifetime([attempt, rejected]) {}
  }

  func testCancellationAfterCallbackBeforeAdjudicationPreventsMintingAndCompletion() {
    let context = Context()
    var adjudications: [() -> Void] = []
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() }, scheduleReply: { adjudications.append($0) })
    var callbacks = 0
    var validations = 0
    let attempt = factory.authenticate(tuple(), validate: { _ in validations += 1; return true }, completion: { _ in callbacks += 1 })
    context.reply?(true, nil)
    XCTAssertEqual(adjudications.count, 1)
    XCTAssertEqual(validations, 2)
    XCTAssertEqual(callbacks, 0)
    attempt.cancel()
    adjudications.forEach { $0() }
    XCTAssertEqual(callbacks, 0)
    XCTAssertEqual(context.invalidations, 1)
  }

  func testDuplicateCallbackIsRejectedBeforeAdjudicationHop() {
    let context = Context()
    var adjudications: [() -> Void] = []
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() }, scheduleReply: { adjudications.append($0) })
    var results: [OwnerAuthentication?] = []
    let attempt = factory.authenticate(tuple(), validate: { _ in true }, completion: { results.append($0) })
    context.reply?(true, nil)
    context.reply?(true, nil)
    XCTAssertEqual(adjudications.count, 1)
    XCTAssertEqual(results.count, 0)
    adjudications.forEach { $0() }
    context.reply?(false, NSError(domain: "late", code: 2))
    XCTAssertEqual(adjudications.count, 1)
    XCTAssertEqual(results.count, 1)
    XCTAssertTrue((results.first ?? nil)?.consume(matching: tuple()) == true)
    XCTAssertEqual(context.invalidations, 1)
    withExtendedLifetime(attempt) {}
  }

  func testRevalidationOccursOnAdjudicationHop() {
    let context = Context()
    var adjudications: [() -> Void] = []
    let factory = FreshPairingOwnerAuthenticator.testing(makeContext: { context }, schedule: { $0() }, scheduleReply: { adjudications.append($0) })
    var eligible = true
    var results: [OwnerAuthentication?] = []
    let attempt = factory.authenticate(tuple(), validate: { _ in eligible }, completion: { results.append($0) })
    context.reply?(true, nil)
    eligible = false
    adjudications.forEach { $0() }
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first ?? nil)
    XCTAssertEqual(context.invalidations, 1)
    withExtendedLifetime(attempt) {}
  }
}
