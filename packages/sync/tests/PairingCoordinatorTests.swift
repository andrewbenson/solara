import Foundation
import LocalAuthentication
import XCTest
@testable import SolaraLegacySyncCore

final class PairingCoordinatorTests: XCTestCase {
  typealias S = PairingSession

  final class Handoff<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
      get { lock.lock(); defer { lock.unlock() }; return stored }
      set { lock.lock(); stored = newValue; lock.unlock() }
    }
  }

  final class Mailbox: PairingCoordinatingMailbox {
    var pairingCID = SyncKeys(entropy: Data(count: 32)).chainTag
    var pairingFolderIdentity = Data([9])
    var pairingFolder = SyncTestDirectory.url
    let lock = NSLock()
    var entries: [S.Entry] = []
    private var disclosures: [S.Entry] = []
    private var finishedWrites: [S.Entry] = []
    var finishedPublications: [S.Entry] { lock.lock(); defer { lock.unlock() }; return finishedWrites }
    var everVisible: [S.Entry] { lock.lock(); defer { lock.unlock() }; return disclosures }
    var removals: [[S.Entry]] = []
    var holdRemoval = false
    var removalReached: (() -> Void)?
    let removalRelease = DispatchSemaphore(value: 0)
    func remove(expected: [S.Entry]) {
      if holdRemoval {
        removalReached?()
        guard removalRelease.wait(timeout: .now() + 5) == .success else { return }
      }
      lock.lock(); defer { lock.unlock() }
      removals.append(expected)
      entries.removeAll { expected.contains($0) }
    }
    var hold: S.Kind?
    var reached: (() -> Void)?
    var release = DispatchSemaphore(value: 0)
    var failure = false
    var failPoll = false
    var holdPoll = false
    var pollReached: (() -> Void)?
    var pollObserved: (() -> Void)?
    var pollRelease = DispatchSemaphore(value: 0)
    private var pollCount = 0
    var polls: Int { lock.lock(); defer { lock.unlock() }; return pollCount }
    var externallyVisible: [S.Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func poll(rids: Set<Data>) throws -> [S.Entry] {
      lock.lock(); pollCount += 1; lock.unlock()
      pollObserved?()
      if holdPoll {
        pollReached?()
        guard pollRelease.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      if failPoll { throw PairingCoordinator.Failure.unavailable }
      return externallyVisible
    }
    func publish(_ entry: S.Entry, admit: () -> Bool) throws -> PairingMailbox.WriteOutcome {
      defer { lock.lock(); finishedWrites.append(entry); lock.unlock() }
      if hold == entry.kind {
        reached?()
        guard release.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      guard admit() else { throw PairingCoordinator.Failure.stale }
      if failure { throw PairingCoordinator.Failure.unavailable }
      lock.lock(); defer { lock.unlock() }
      if entries.contains(entry) { return .identical }
      entries.append(entry)
      disclosures.append(entry)
      return .written
    }
  }

  final class Store: PairingAccountingStoring {
    private let ledgerHandoff = Handoff<S.Accounting?>(nil)
    private let consumedHandoff = Handoff<[PairingConsumedApproval]>([])
    var ledger: S.Accounting? {
      get { ledgerHandoff.value }
      set { ledgerHandoff.value = newValue }
    }
    var consumed: [PairingConsumedApproval] {
      get { consumedHandoff.value }
      set { consumedHandoff.value = newValue }
    }
    var failAccounting = false
    var holdAccounting = false
    var accountingReached: (() -> Void)?
    var accountingRelease = DispatchSemaphore(value: 0)
    var failConsumed = false
    var holdDecision = false
    var decisionReached: (() -> Void)?
    let decisionRelease = DispatchSemaphore(value: 0)
    var badDecisionReadback = false
    var failDecision = false
    var holdCancellation = false
    let cancellationRelease = DispatchSemaphore(value: 0)
    var cancellationReached: (() -> Void)?
    var admitted: [PairingInstallation] = []
    var cancelled: [PairingInstallation] = []
    var holdSuppression = false
    var suppressionReached: (() -> Void)?
    let suppressionRelease = DispatchSemaphore(value: 0)
    var suppressionObserved: (() -> Void)?
    var suppressed = true
    func validatePlacement(pairingFolder: URL) throws {}
    func cancelInstallation(_ installation: PairingInstallation) throws {
      if holdCancellation {
        cancellationReached?()
        guard cancellationRelease.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      if failDecision { throw PairingCoordinator.Failure.unavailable }
      if !cancelled.contains(installation) { cancelled.append(installation) }
    }
    func persistInstallationDecision(_ decision: PairingInstallationDecision) throws -> PairingInstallationDecision {
      if holdDecision {
        decisionReached?()
        guard decisionRelease.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      if failDecision { throw PairingCoordinator.Failure.unavailable }
      if decision.disposition == .admitted { admitted.append(decision.installation) }
      else { cancelled.append(decision.installation) }
      return decision
    }
    func installationDecision(for installation: PairingInstallation) throws -> PairingInstallationDecision? {
      if badDecisionReadback { throw PairingCoordinator.Failure.unavailable }
      if cancelled.contains(installation) { return .init(installation: installation, disposition: .cancelled) }
      if admitted.contains(installation) { return .init(installation: installation, disposition: .admitted) }
      return nil
    }
    func restoreAccounting(now: UInt64, epoch: Data) -> S.RestorationDisposition { ledger.map { .restored($0) } ?? .newInstallation }
    func persistAccounting(_ value: S.Accounting) throws -> S.Accounting {
      if holdAccounting {
        accountingReached?()
        guard accountingRelease.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      if failAccounting { throw PairingCoordinator.Failure.unavailable }
      ledger = value
      return value
    }
    func consumeApproval(_ record: PairingConsumedApproval) throws {
      if failConsumed { throw PairingCoordinator.Failure.unavailable }
      consumed.append(record)
    }
    func setSuppressed(_ value: Bool) throws {
      if holdSuppression {
        suppressionReached?()
        guard suppressionRelease.wait(timeout: .now() + 5) == .success else { throw PairingCoordinator.Failure.unavailable }
      }
      suppressed = value
      suppressionObserved?()
    }
  }

  final class Context: SyntheticPairingAuthenticationContext {
    var touchIDAuthenticationAllowableReuseDuration: TimeInterval = 100
    var available = true
    private let replyHandoff = Handoff<((Bool, Error?) -> Void)?>(nil)
    private let invalidatedHandoff = Handoff(false)
    var reply: ((Bool, Error?) -> Void)? {
      get { replyHandoff.value }
      set { replyHandoff.value = newValue }
    }
    var invalidated: Bool {
      get { invalidatedHandoff.value }
      set { invalidatedHandoff.value = newValue }
    }
    func canEvaluatePolicy(_ policy: LAPolicy) -> Bool { available }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void) { self.reply = reply }
    func invalidate() { invalidated = true }
  }

  final class Keys: PairingInstallationKeyStoring {
    var lookup: PairingKeyLookup = .absent
    var inserts = 0
    var failSave = false
    var readback: PairingKeyLookup?
    var holdInsert = false
    var insertReached: (() -> Void)?
    var insertRelease = DispatchSemaphore(value: 0)
    func pairingLookup(account: String) -> PairingKeyLookup { lookup }
    func pairingInsert(_ secret: Data, account: String) -> Bool {
      inserts += 1
      if holdInsert {
        insertReached?()
        guard insertRelease.wait(timeout: .now() + 5) == .success else { return false }
      }
      if failSave { return false }
      lookup = readback ?? .found(secret)
      return true
    }
  }

  final class Host: PairingInstallationHosting {
    var prepareResult = true
    var prepared: [PairingInstallation] = []
    var saved: [PairingInstallation] = []
    var pendingPrepare: ((Bool) -> Void)?
    var holdPrepare = false
    var holdKeySaved = false
    var heldKeySaved: (() -> Void)?
    var initialized: ((Bool) -> Void)?
    var ready: ((Bool) -> Void)?
    func prepare(_ installation: PairingInstallation, completion: @escaping (Bool) -> Void) {
      prepared.append(installation)
      if holdPrepare { pendingPrepare = completion } else { completion(prepareResult) }
    }
    func keySaved(_ installation: PairingInstallation, initialized: @escaping (Bool) -> Void, ready: @escaping (Bool) -> Void) {
      let finish = {
        self.saved.append(installation)
        self.initialized = initialized
        self.ready = ready
      }
      if holdKeySaved { heldKeySaved = finish } else { finish() }
    }
  }

  final class Rig {
    let mailbox = Mailbox(), store = Store(), keys = Keys(), host = Host()
    let time = PairingSessionTests.Time(), rng = PairingSessionTests.Random(120)
    private let eligibilityHandoff = Handoff<() -> Bool>({ true })
    var eligibility: () -> Bool {
      get { eligibilityHandoff.value }
      set { eligibilityHandoff.value = newValue }
    }
    var clockEpoch = Data([1])
    var durableStore: PairingAccountingStoring?
    private let contextHandoff = Handoff<[Context]>([])
    var contexts: [Context] {
      get { contextHandoff.value }
      set { contextHandoff.value = newValue }
    }
    var states: [PairingJoinState] = []
    var allCallbacksOnMain = true
    deinit {
      host.initialized = nil
      host.ready = nil
      host.pendingPrepare = nil
      host.heldKeySaved = nil
      for context in contexts { context.reply = nil }
    }
    var scheduleAuthentication: ((@escaping () -> Void) -> Void)?
    lazy var auth = SyntheticPairingOwnerAuthenticator(makeContext: { [unowned self] in
      let value = Context(); self.contexts.append(value); return value
    }, schedule: { [unowned self] work in
      if let scheduleAuthentication = self.scheduleAuthentication { scheduleAuthentication(work) }
      else { work() }
    })
    lazy var coordinator = PairingCoordinator(configuration: .init(cid: SyncKeys(entropy: Data(count: 32)).chainTag, environment: .init(folderIdentity: Data([9]), entropyHandle: Data([8]), clockEpoch: clockEpoch), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)), mailbox: mailbox, store: durableStore ?? store, authenticator: auth, keyStore: keys, host: host, clock: time.read, wall: { 1793552400000 }, random: rng.take, eligibility: { [eligibilityHandoff] in eligibilityHandoff.value() })
    func start() -> PairingJoinHandle {
      coordinator.start(cid: SyncKeys(entropy: Data(count: 32)).chainTag) { [weak self] state in
        self?.allCallbacksOnMain = (self?.allCallbacksOnMain ?? false) && Thread.isMainThread
        self?.states.append(state)
      }
    }
  }

  func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    let limit = Date().addingTimeInterval(3)
    while !condition(), Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    XCTAssertTrue(condition(), file: file, line: line)
    if !condition() { throw PairingCoordinator.Failure.unavailable }
  }

  func comparing(_ rig: Rig) throws -> (PairingJoinHandle, PairingTrustedHandle) {
    let control = rig.start()
    let arm = try rig.coordinator.armTrusted()
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
    rig.coordinator.poll()
    try wait { ((try? rig.coordinator.requests(arm)) ?? []).count == 1 }
    try rig.coordinator.pin(XCTUnwrap(rig.coordinator.requests(arm).first), handle: arm)
    for _ in 0..<12 {
      rig.coordinator.poll()
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try wait { rig.coordinator.poll(); return rig.coordinator.snapshot.trustedPhase == .comparing }
    return (control, arm)
  }

  func authPending(_ rig: Rig) throws -> (PairingJoinHandle, PairingTrustedHandle) {
    let pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    try rig.coordinator.allow(pair.1)
    try wait { rig.contexts.last?.reply != nil }
    return pair
  }

  func testInvalidateEntryDoesNotWaitForDurableCancellation() throws {
    let rig = Rig()
    rig.keys.holdInsert = true
    let insert = expectation(description: "insert")
    rig.keys.insertReached = { insert.fulfill() }
    _ = try receivedApproval(rig)
    wait(for: [insert], timeout: 3)
    rig.store.holdCancellation = true
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      rig.coordinator.invalidate(reason: .stop)
      returned.signal()
    }
    XCTAssertEqual(returned.wait(timeout: .now() + 0.2), .success, "entry invalidation waited on local durable cancellation")
    rig.store.cancellationRelease.signal()
    rig.keys.insertRelease.signal()
    try wait { !rig.coordinator.committedJoin { _ in } }
    XCTAssertFalse(rig.states.contains(.approved))
    XCTAssertTrue(rig.host.saved.isEmpty)
  }

  func testUnarmedObservationIsQuietAndDoesNotCreateIntent() throws {
    let rig = Rig()
    let fixture = PairingSessionTests()
    let session = try fixture.session(.joining, rig.time)
    let request = try fixture.write(session.startJoining(createdMs: fixture.wall), .request)
    rig.mailbox.entries = [request]
    rig.coordinator.poll()
    try wait { rig.mailbox.polls > 0 }
    try wait { rig.coordinator.quietRequests.count == 1 }
    XCTAssertEqual(rig.coordinator.quietRequests.first?.wire, request.wire)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertTrue(rig.mailbox.everVisible.isEmpty)
    XCTAssertTrue(rig.contexts.isEmpty)
    rig.coordinator.invalidate(reason: .lock)
    XCTAssertTrue(rig.coordinator.quietRequests.isEmpty)
  }

  func testInvalidateEntryDoesNotWaitForAdmissionRecordIO() throws {
    let rig = Rig(), reached = expectation(description: "admission record")
    rig.store.holdDecision = true
    rig.store.decisionReached = { reached.fulfill() }
    _ = try receivedApproval(rig)
    wait(for: [reached], timeout: 3)
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      rig.coordinator.invalidate(reason: .stop)
      returned.signal()
    }
    XCTAssertEqual(returned.wait(timeout: .now() + 0.2), .success, "entry invalidation waited for an admission fsync")
    XCTAssertFalse(rig.states.contains(.approved))
    rig.store.decisionRelease.signal()
  }

  func testDurableStopRetiresCommittedOwnerWithoutRewritingOldHandleHistory() throws {
    let rig = Rig()
    let pair = try receivedApproval(rig)
    try wait { rig.states.contains(.approved) }
    rig.coordinator.invalidate(reason: .stop)
    rig.coordinator.finishStop()
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
  }

  func testInvalidateEntryDoesNotWaitForAnExplicitCancellationIO() throws {
    let rig = Rig(), inserted = expectation(description: "insert"), cancellation = expectation(description: "cancel")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { inserted.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [inserted], timeout: 3)
    rig.store.holdCancellation = true
    rig.store.cancellationReached = { cancellation.fulfill() }
    DispatchQueue.global().async { _ = pair.0.cancel() }
    wait(for: [cancellation], timeout: 3)
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { rig.coordinator.invalidate(reason: .stop); returned.signal() }
    let result = returned.wait(timeout: .now() + 0.2)
    XCTAssertEqual(result, .success, "entry invalidation waited behind another handle's durable cancellation")
    rig.store.cancellationRelease.signal()
    rig.keys.insertRelease.signal()
    if result != .success { XCTAssertEqual(returned.wait(timeout: .now() + 3), .success) }
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
  }

  func testStaleConfigurationCannotPublishAfterStop() throws {
    let rig = Rig()
    let epoch = rig.coordinator.configurationEpoch
    let configuration = PairingCoordinator.Configuration(cid: rig.mailbox.pairingCID, environment: .init(folderIdentity: rig.mailbox.pairingFolderIdentity, entropyHandle: Data([8]), clockEpoch: rig.clockEpoch), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16))
    rig.coordinator.invalidate(reason: .stop)
    XCTAssertFalse(rig.coordinator.update(configuration: configuration, mailbox: rig.mailbox, expectedInvalidationEpoch: epoch))
    XCTAssertThrowsError(try rig.coordinator.armTrusted())
  }

  func testStableControlRestartThenCancel() throws {
    let rig = Rig(), h = rig.start()
    try wait { rig.coordinator.snapshot.joining }
    h.startAgain(); h.startAgain(); h.cancel()
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    try wait { rig.states.last == .failed(.cancelled) }
    XCTAssertTrue(rig.allCallbacksOnMain)
  }

  func testDetachedControlCannotCancelReplacement() throws {
    let rig = Rig(), old = rig.start(), current = rig.start()
    old.cancel(); old.startAgain()
    try wait { rig.coordinator.snapshot.joining }
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    current.cancel()
    XCTAssertFalse(rig.coordinator.snapshot.joining)
  }

  func testOneTrustedArmAndStaleHandle() throws {
    let rig = Rig(), arm = try rig.coordinator.armTrusted()
    XCTAssertThrowsError(try rig.coordinator.armTrusted())
    rig.coordinator.invalidate(reason: .stop)
    XCTAssertThrowsError(try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(arm)))
    XCTAssertThrowsError(try rig.coordinator.allow(arm))
  }

  func testAllowRequiresComparisonAndFreshAuthentication() throws {
    let rig = Rig(), pair = try comparing(rig)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertTrue(rig.contexts.isEmpty)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    try rig.coordinator.allow(pair.1)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
  }

  func testHideCancelsPendingContextBeforeAdmissionQueueResumes() throws {
    let rig = Rig(), pair = try authPending(rig)
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let comparisonFinished = DispatchSemaphore(value: 0)
    let hideFinished = DispatchSemaphore(value: 0)
    rig.eligibility = {
      entered.signal()
      _ = resume.wait(timeout: .now() + 3)
      return true
    }
    DispatchQueue.global().async {
      _ = try? rig.coordinator.comparison(pair.1)
      comparisonFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async {
      try? rig.coordinator.hide(pair.1)
      hideFinished.signal()
    }
    let deadline = Date().addingTimeInterval(0.2)
    while !rig.contexts[0].invalidated, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    XCTAssertTrue(rig.contexts[0].invalidated, "a real interruption must cancel LA before admission unblocks")
    resume.signal()
    resume.signal()
    XCTAssertEqual(comparisonFinished.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(hideFinished.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    withExtendedLifetime(pair.0) {}
  }

  func testGlobalLockCancelsPendingContextBeforeAdmissionQueueResumes() throws {
    let rig = Rig(), pair = try authPending(rig)
    let context = try XCTUnwrap(rig.contexts.first)
    let lateSuccess = try XCTUnwrap(context.reply)
    let chargedReveals = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(chargedReveals.count, 1)
    XCTAssertTrue(rig.coordinator.panelLive(pair.1))
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let comparisonFinished = DispatchSemaphore(value: 0)
    rig.eligibility = {
      entered.signal()
      _ = resume.wait(timeout: .now() + 3)
      return true
    }
    DispatchQueue.global().async {
      _ = try? rig.coordinator.comparison(pair.1)
      comparisonFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    rig.coordinator.invalidate(reason: .lock)
    XCTAssertTrue(context.invalidated, "global invalidation must cancel LA before admission unblocks")
    XCTAssertFalse(rig.coordinator.panelLive(pair.1), "global invalidation must clear panelLive before admission unblocks")
    rig.eligibility = { true }
    resume.signal()
    XCTAssertEqual(comparisonFinished.wait(timeout: .now() + 1), .success)
    lateSuccess(true, nil)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertTrue(rig.host.prepared.isEmpty)
    XCTAssertEqual(rig.store.ledger?.reveals, chargedReveals)
    withExtendedLifetime(pair.0) {}
  }

  func testPanelTailAfterReplyWithoutForegroundStillPublishes() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
    let validation = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) }, validatingSurface: { validation.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { validation.value != nil }
    for _ in 0..<3 {
      if !rig.coordinator.toleratesSoftLoss(pair.1, foreground: false) { try? rig.coordinator.hide(pair.1) }
    }
    _ = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true)
    validation.value?(true)
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } || !rig.coordinator.snapshot.trusted }
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .approval }.count, 1)
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyWithoutForegroundExpiresBeforeHeldPublication() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
    let reached = expectation(description: "approval held")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    rig.time.now += 2000
    rig.coordinator.poll()
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyDeadlineCrossedDuringFinalEligibilityRejectsApproval() throws {
    try replyDeadlineCrossedDuringFinalEligibility(hold: 0)
  }

  func testReplyDeadlineCrossedDuringHeldFinalEligibilityRejectsApproval() throws {
    try replyDeadlineCrossedDuringFinalEligibility(hold: 2.1)
  }

  private func replyDeadlineCrossedDuringFinalEligibility(hold: TimeInterval) throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    let reached = expectation(description: "approval waiting before final admission")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    let context = try XCTUnwrap(rig.contexts.first)
    context.reply?(true, nil)
    wait(for: [reached], timeout: 3)
    let crossedDeadline = Handoff(false)
    rig.eligibility = { [weak rig] in
      guard let rig else { return false }
      if !crossedDeadline.value {
        crossedDeadline.value = true
        rig.time.now += PairingCoordinator.foregroundRegainDeadlineMilliseconds + 1
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
      }
      return true
    }
    defer { rig.eligibility = { true } }
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    try wait {
      let snapshot = rig.coordinator.snapshot
      return !snapshot.trusted || snapshot.trustedPhase == .released
    }
    XCTAssertTrue(crossedDeadline.value)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertTrue(context.invalidated)
    XCTAssertEqual(rig.store.consumed.count, 1)
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testInterruptionDuringFinalEligibilityRejectsApproval() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    let reached = expectation(description: "approval waiting before final admission")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    let regained = Handoff(false)
    let interrupted = Handoff(false)
    rig.eligibility = { [weak rig] in
      guard let rig else { return false }
      if !interrupted.value {
        regained.value = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true)
        interrupted.value = !rig.coordinator.toleratesSoftLoss(pair.1, foreground: false)
      }
      return true
    }
    defer { rig.eligibility = { true } }
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    try wait {
      let snapshot = rig.coordinator.snapshot
      return !snapshot.trusted || snapshot.trustedPhase == .released
    }
    XCTAssertTrue(regained.value)
    XCTAssertTrue(interrupted.value)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertEqual(rig.store.consumed.count, 1)
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyForegroundAndRegainedForegroundBothCancelANewLoss() throws {
    for initialForeground in [false, true] {
      let rig = Rig(), pair = try comparing(rig)
      try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
      let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
      let validation = Handoff<((Bool) -> Void)?>(nil)
      try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(initialForeground) }, validatingSurface: { validation.value = $0 })
      try wait { rig.contexts.last?.reply != nil }
      rig.contexts[0].reply?(true, nil)
      try wait { validation.value != nil }
      if !initialForeground { _ = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true) }
      XCTAssertFalse(rig.coordinator.toleratesSoftLoss(pair.1, foreground: false))
      try? rig.coordinator.hide(pair.1)
      validation.value?(true)
      XCTAssertFalse(rig.coordinator.snapshot.trusted)
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
      XCTAssertEqual(rig.store.ledger?.reveals, charged)
      withExtendedLifetime(pair.0) {}
    }
  }

  func testHardLossCancelsBeforeReplyWithoutForegroundAndAfterRegain() throws {
    for point in ["panel", "tail", "foreground", "regained"] {
      let rig = Rig(), pair = try comparing(rig)
      try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
      let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
      let validation = Handoff<((Bool) -> Void)?>(nil)
      try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(point == "foreground") }, validatingSurface: { validation.value = $0 })
      try wait { rig.contexts.last?.reply != nil }
      if point != "panel" {
        rig.contexts[0].reply?(true, nil)
        try wait { validation.value != nil }
      }
      if point == "regained" { _ = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true) }
      try rig.coordinator.hide(pair.1)
      rig.contexts[0].reply?(true, nil)
      validation.value?(true)
      XCTAssertFalse(rig.coordinator.snapshot.trusted)
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
      XCTAssertEqual(rig.store.ledger?.reveals, charged)
      withExtendedLifetime(pair.0) {}
    }
  }

  func testReplyWithoutForegroundPublishesWithoutWaitingAndIgnoresLaterDeadline() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.everVisible.contains { $0.kind == .approval } }
    rig.time.now += 2000
    rig.coordinator.poll()
    XCTAssertEqual(rig.coordinator.snapshot.trustedPhase, .released)
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .approval }.count, 1)
    withExtendedLifetime(pair.0) {}
  }

  func testRegainRetiresDeadlineBeforeHeldPublication() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let reached = expectation(description: "approval held")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    rig.time.now += 1999
    _ = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true)
    rig.time.now += 10000
    rig.coordinator.poll()
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .approval }.count, 1)
    withExtendedLifetime(pair.0) {}
  }

  func testHardLossAtEveryReplyPointCancelsHeldMailboxAdmission() throws {
    for point in ["tail", "foreground", "regained"] {
      let rig = Rig(), pair = try comparing(rig)
      try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
      let charged = try XCTUnwrap(rig.store.ledger).reveals
      XCTAssertEqual(charged.count, 1)
      let reached = expectation(description: "approval held")
      rig.mailbox.hold = .approval
      rig.mailbox.reached = { reached.fulfill() }
      try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(point == "foreground") })
      try wait { rig.contexts.last?.reply != nil }
      rig.contexts[0].reply?(true, nil)
      wait(for: [reached], timeout: 3)
      if point == "regained" { _ = rig.coordinator.toleratesSoftLoss(pair.1, foreground: true) }
      try rig.coordinator.hide(pair.1)
      rig.mailbox.release.signal()
      try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
      XCTAssertEqual(rig.store.ledger?.reveals, charged)
      withExtendedLifetime(pair.0) {}
    }
  }

  func testReplyDeadlineAutomaticallyCancelsWhileMailboxIsHeld() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
    let reached = expectation(description: "approval held")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { $0(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    rig.time.now += 2000
    try wait { !rig.coordinator.snapshot.trusted }
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testGainBeforeDelayedReplySnapshotStillMakesNextLossCancel() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let snapshot = Handoff<((Bool) -> Void)?>(nil)
    let validation = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { snapshot.value = $0 }, validatingSurface: { validation.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { snapshot.value != nil }
    XCTAssertFalse(rig.coordinator.panelLive(pair.1))
    XCTAssertTrue(rig.coordinator.toleratesSoftLoss(pair.1, foreground: false))
    XCTAssertTrue(rig.coordinator.toleratesSoftLoss(pair.1, foreground: true))
    snapshot.value?(false)
    snapshot.value?(false)
    try wait { validation.value != nil }
    XCTAssertFalse(rig.coordinator.toleratesSoftLoss(pair.1, foreground: false))
    validation.value?(true)
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    withExtendedLifetime(pair.0) {}
  }

  func testHardLossWhileReplySnapshotIsPendingRejectsLateSnapshot() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let snapshot = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { snapshot.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { snapshot.value != nil }
    try rig.coordinator.hide(pair.1)
    snapshot.value?(true)
    snapshot.value?(false)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    withExtendedLifetime(pair.0) {}
  }

  func testForegroundGainBeforeEvaluationDoesNotCancelPendingAuthentication() throws {
    let rig = Rig()
    let evaluation = Handoff<(() -> Void)?>(nil)
    rig.scheduleAuthentication = { evaluation.value = $0 }
    let pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    try rig.coordinator.allow(pair.1)
    XCTAssertNotNil(evaluation.value)
    XCTAssertTrue(rig.contexts.isEmpty)
    XCTAssertTrue(rig.coordinator.toleratesSoftLoss(pair.1, foreground: true))
    evaluation.value?()
    XCTAssertEqual(rig.contexts.count, 1)
    XCTAssertTrue(rig.coordinator.panelLive(pair.1))
    try? rig.coordinator.hide(pair.1)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyDeadlineCancelsPendingSnapshotContextBeforeAdmissionResumes() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let charged = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(charged.count, 1)
    let snapshot = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, observingSurfaceAtReply: { snapshot.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    let context = try XCTUnwrap(rig.contexts.first)
    context.reply?(true, nil)
    try wait { snapshot.value != nil }
    XCTAssertFalse(context.invalidated)
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let comparisonFinished = DispatchSemaphore(value: 0)
    rig.eligibility = {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
      return true
    }
    defer { rig.eligibility = { true }; resume.signal(); snapshot.value?(false) }
    DispatchQueue.global().async {
      _ = try? rig.coordinator.comparison(pair.1)
      comparisonFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(context.invalidated)
    rig.time.now += 2000
    try wait { context.invalidated }
    XCTAssertFalse(rig.coordinator.panelLive(pair.1))
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    rig.eligibility = { true }
    resume.signal()
    XCTAssertEqual(comparisonFinished.wait(timeout: .now() + 1), .success)
    snapshot.value?(false)
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    withExtendedLifetime(pair.0) {}
  }

  func testFinalSurfaceAdmissionWaitsForVisibleReplyWithoutRestoredFocus() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let reply = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, validatingSurface: { reply.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { reply.value != nil }
    XCTAssertTrue(rig.store.consumed.isEmpty, "approval waits for the final visible-surface reply")
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    reply.value?(true)
    reply.value?(true)
    try wait { rig.mailbox.everVisible.contains { $0.kind == .approval } }
    XCTAssertEqual(rig.coordinator.snapshot.trustedPhase, .released)
    XCTAssertEqual(rig.store.consumed.count, 1, "duplicate surface replies cannot consume two approvals")
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .approval }.count, 1)
    withExtendedLifetime(pair.0) {}
  }

  func testFinalSurfaceAdmissionRejectsHardLossAfterSuccessfulAuthentication() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let chargedReveals = rig.store.ledger?.reveals
    let checks = Handoff(0)
    try rig.coordinator.allow(pair.1, validatingSurface: { reply in checks.value += 1; reply(false) })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertEqual(checks.value, 1, "successful LA requires a final visible-surface check")
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, chargedReveals)
    XCTAssertTrue(rig.contexts[0].invalidated)
    withExtendedLifetime(pair.0) {}
  }

  func testFinalSurfaceAdmissionRejectsLateVisibleReplyAfterHide() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.acknowledgeComparison(rig.coordinator.comparison(pair.1))
    let chargedReveals = rig.store.ledger?.reveals
    let reply = Handoff<((Bool) -> Void)?>(nil)
    try rig.coordinator.allow(pair.1, validatingSurface: { reply.value = $0 })
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts[0].reply?(true, nil)
    try wait { reply.value != nil }
    try rig.coordinator.hide(pair.1)
    reply.value?(true)
    reply.value?(true)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, chargedReveals)
    XCTAssertTrue(rig.contexts[0].invalidated)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyThenInterruptionWhileApprovalMailboxHeldPreventsGrantAndKeepsRevealCharged() throws {
    let rig = Rig(), pair = try authPending(rig)
    let charged = rig.store.ledger?.reveals
    let reached = expectation(description: "approval publication held")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    XCTAssertFalse(rig.coordinator.panelLive(pair.1))
    try rig.coordinator.hide(pair.1)
    rig.mailbox.release.signal()
    try wait { rig.mailbox.finishedPublications.contains { $0.kind == .approval } }
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, charged)
    withExtendedLifetime(pair.0) {}
  }

  func testReplyThenNoLossWhileApprovalMailboxHeldPublishesOnce() throws {
    let rig = Rig(), pair = try authPending(rig)
    let reached = expectation(description: "approval publication held")
    rig.mailbox.hold = .approval
    rig.mailbox.reached = { reached.fulfill() }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    XCTAssertFalse(rig.coordinator.panelLive(pair.1))
    rig.mailbox.release.signal()
    try wait { rig.mailbox.everVisible.contains { $0.kind == .approval } }
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .approval }.count, 1)
    try rig.coordinator.hide(pair.1)
    XCTAssertEqual(rig.coordinator.snapshot.trustedPhase, .released)
    withExtendedLifetime(pair.0) {}
  }

  func testPanelStateCannotTransferToReplacementArm() throws {
    let rig = Rig(), pair = try authPending(rig)
    XCTAssertTrue(rig.coordinator.panelLive(pair.1))
    try rig.coordinator.hide(pair.1)
    let replacement = try rig.coordinator.armTrusted()
    XCTAssertFalse(rig.coordinator.panelLive(pair.1))
    XCTAssertFalse(rig.coordinator.panelLive(replacement))
    rig.contexts[0].reply?(true, nil)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    withExtendedLifetime(pair.0) {}
  }

  func testAuthenticationFailureBurnsArm() throws {
    let rig = Rig(), pair = try authPending(rig)
    rig.contexts[0].reply?(false, nil)
    try wait { !rig.coordinator.snapshot.trusted }
    rig.contexts[0].reply?(true, nil)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertTrue(rig.store.consumed.isEmpty)
  }

  func testInvalidateIsSynchronousBeforeAnyDiskOrJSWork() throws {
    let rig = Rig(), pair = try authPending(rig)
    rig.coordinator.invalidate(reason: .stop)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertTrue(rig.contexts[0].invalidated)
    rig.contexts[0].reply?(true, nil)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertTrue(rig.store.consumed.isEmpty)
  }

  func testEveryInvalidationDiscardsLateAuth() throws {
    for reason in [PairingCoordinator.InvalidationReason.lock, .safeMode, .key, .folder, .surface, .shutdown] {
      let rig = Rig(), pair = try authPending(rig)
      rig.coordinator.invalidate(reason: reason)
      XCTAssertFalse(rig.coordinator.snapshot.trusted)
      XCTAssertTrue(rig.contexts[0].invalidated)
      XCTAssertFalse(rig.coordinator.panelLive(pair.1))
      rig.contexts[0].reply?(true, nil)
      XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    }
  }

  func testHideRemountDoesNotInheritComparisonOrAuthLease() throws {
    let rig = Rig(), pair = try authPending(rig)
    try rig.coordinator.hide(pair.1)
    rig.contexts[0].reply?(true, nil)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertNil(rig.coordinator.snapshot.code)
  }

  func testHideDuringAuthenticationEndsArmAndLateSuccessCannotReleaseOrBlockRearming() throws {
    let rig = Rig(), pair = try authPending(rig)
    let context = try XCTUnwrap(rig.contexts.first)
    let lateSuccess = try XCTUnwrap(context.reply)
    let chargedReveals = try XCTUnwrap(rig.store.ledger).reveals
    XCTAssertEqual(chargedReveals.count, 1)

    try rig.coordinator.hide(pair.1)
    XCTAssertTrue(context.invalidated)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertNil(rig.coordinator.snapshot.trustedPhase)
    XCTAssertNil(rig.coordinator.snapshot.code)
    XCTAssertThrowsError(try rig.coordinator.comparison(pair.1))
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))

    let replacement = try rig.coordinator.armTrusted()
    try wait { (try? rig.coordinator.requests(replacement)) != nil }
    lateSuccess(true, nil)
    XCTAssertTrue(rig.coordinator.snapshot.trusted)
    XCTAssertEqual(rig.coordinator.snapshot.trustedPhase, .armed)
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertTrue(rig.host.prepared.isEmpty)
    XCTAssertEqual(rig.store.ledger?.reveals, chargedReveals)
    XCTAssertFalse(rig.states.contains(.approved))

    rig.time.now += 300000
    rig.coordinator.poll()
    try wait { rig.states.last == .failed(.expired) }
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals, chargedReveals)
  }

  func testRearmingAfterAuthenticationAbortComparesFreshRequestBesideStalePeerPackets() throws {
    let rig = Rig(), pair = try authPending(rig)
    let lateSuccess = try XCTUnwrap(rig.contexts.first?.reply)
    let stale = rig.mailbox.externallyVisible.filter { [.select, .confirm, .joiningName].contains($0.kind) }
    XCTAssertFalse(stale.isEmpty)
    try rig.coordinator.hide(pair.1)
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    try wait { !rig.mailbox.externallyVisible.contains { stale.contains($0) } }
    rig.mailbox.lock.lock(); rig.mailbox.entries.append(contentsOf: stale); rig.mailbox.lock.unlock()

    let replacement = try rig.coordinator.armTrusted()
    let fixture = PairingSessionTests()
    let peer = try fixture.session(.joining, rig.time, seed: 900)
    let request = try fixture.write(peer.startJoining(createdMs: fixture.wall), .request)
    rig.mailbox.lock.lock(); rig.mailbox.entries.append(request); rig.mailbox.lock.unlock()
    try wait { rig.coordinator.poll(); return ((try? rig.coordinator.requests(replacement)) ?? []).contains { $0.descriptor.rid == request.rid } }
    let selected = try XCTUnwrap(rig.coordinator.requests(replacement).first { $0.descriptor.rid == request.rid })
    try rig.coordinator.pin(selected, handle: replacement)
    try wait {
      rig.coordinator.poll()
      for entry in rig.mailbox.externallyVisible where entry.rid == request.rid && [.offer, .reveal, .trustedName].contains(entry.kind) {
        if let output = try? peer.receive(entry) {
          rig.mailbox.lock.lock()
          for write in output.writes where !rig.mailbox.entries.contains(write) { rig.mailbox.entries.append(write) }
          rig.mailbox.lock.unlock()
        }
      }
      if peer.phase == .requestLive, let offer = peer.offers.first, let output = try? peer.selectOffer(offer, handle: peer.handle) {
        rig.mailbox.lock.lock(); rig.mailbox.entries.append(contentsOf: output.writes); rig.mailbox.lock.unlock()
      }
      return rig.coordinator.snapshot.trustedPhase == .comparing && peer.phase == .comparing
    }
    lateSuccess(true, nil)
    XCTAssertEqual(try rig.coordinator.comparison(replacement).code.replacingOccurrences(of: " ", with: ""), peer.code)
    XCTAssertTrue(rig.store.consumed.isEmpty)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    XCTAssertEqual(rig.store.ledger?.reveals.count, 2)
  }

  func testExpiredAuthAtEqualityDoesNotRelease() throws {
    let rig = Rig(), pair = try authPending(rig)
    rig.time.now += 120000
    rig.contexts[0].reply?(true, nil)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    XCTAssertTrue(rig.store.consumed.isEmpty)
  }

  func testGrantInvisibleWhileProviderWaitsAndStopWins() throws {
    let rig = Rig(), pair = try authPending(rig)
    let reached = expectation(description: "provider ready")
    rig.mailbox.hold = .approval; rig.mailbox.reached = { reached.fulfill() }
    rig.contexts[0].reply?(true, nil)
    wait(for: [reached], timeout: 3)
    XCTAssertEqual(rig.store.consumed.count, 1)
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
    rig.coordinator.invalidate(reason: .stop)
    rig.mailbox.release.signal()
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
  }

  func testGrantAfterAdmissionIsAlreadyCommittedAndRetriesExactBytes() throws {
    let rig = Rig(), pair = try authPending(rig)
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    let wire = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .approval }?.wire)
    XCTAssertEqual(rig.coordinator.snapshot.trustedPhase, .released)
    try rig.coordinator.retryApproval(pair.1)
    XCTAssertEqual(rig.store.consumed.count, 1)
    XCTAssertEqual(rig.store.consumed[0].sealedApproval, wire)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
  }

  func testConsumedDurabilityFailurePreventsFirstGrantByte() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.store.failConsumed = true
    rig.contexts[0].reply?(true, nil)
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
  }

  func testRevealGateAfterDurableAcknowledgmentKeepsReservationCharged() throws {
    for stop in [false, true] {
      let rig = Rig(), _ = rig.start(), arm = try rig.coordinator.armTrusted()
      try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
      rig.coordinator.poll()
      try wait { ((try? rig.coordinator.requests(arm)) ?? []).count == 1 }
      try rig.coordinator.pin(XCTUnwrap(rig.coordinator.requests(arm).first), handle: arm)
      let reached = expectation(description: "reveal waiting")
      rig.mailbox.hold = .reveal; rig.mailbox.reached = { reached.fulfill() }
      for _ in 0..<4 { rig.coordinator.poll(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
      wait(for: [reached], timeout: 3)
      XCTAssertEqual(rig.store.ledger?.reveals.count, 1)
      if stop { rig.coordinator.invalidate(reason: .lock) } else { rig.time.now += 120000 }
      rig.mailbox.release.signal()
      rig.coordinator.poll()
      try wait { !rig.coordinator.snapshot.trusted }
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .reveal })
      XCTAssertEqual(rig.store.ledger?.reveals.count, 1)
    }
  }

  func testOutboundRequestGateAfterReplacement() throws {
    let rig = Rig(), reached = expectation(description: "request waiting")
    rig.mailbox.hold = .request; rig.mailbox.reached = { reached.fulfill() }
    let old = rig.start()
    wait(for: [reached], timeout: 3)
    old.cancel()
    rig.mailbox.hold = nil; rig.mailbox.release.signal()
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    try wait { rig.states.last == .failed(.cancelled) }
    XCTAssertTrue(rig.mailbox.everVisible.isEmpty)
  }

  func testInstallNeedsKeyReadbackAndBootstrapReady() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.saved.count == 1 }
    XCTAssertEqual(rig.keys.inserts, 1)
    XCTAssertFalse(rig.states.contains(.installed))
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .receipt })
    rig.host.initialized?(true)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
    XCTAssertFalse(rig.states.contains(.installed))
    rig.host.ready?(true)
    try wait { rig.states.last == .installed }
    XCTAssertTrue(rig.allCallbacksOnMain)
  }

  func testKeychainFailureIsNeverAbsenceOrOverwrite() throws {
    for lookup in [PairingKeyLookup.failure, .found(Data([1])), .found(Data(repeating: 2, count: 32))] {
      let rig = Rig(), _ = try authPending(rig)
      rig.keys.lookup = lookup
      rig.contexts[0].reply?(true, nil)
      try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
      rig.coordinator.poll()
      try wait { !rig.coordinator.snapshot.joining || rig.coordinator.committedJoin { _ in } }
      XCTAssertFalse(rig.coordinator.committedJoin { _ in })
      XCTAssertEqual(rig.keys.inserts, 0)
      XCTAssertTrue(rig.host.saved.isEmpty)
    }
  }

  func testInstallAdmissionCancelledWhileHostPrepares() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.host.holdPrepare = true
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.pendingPrepare != nil }
    rig.coordinator.invalidate(reason: .stop)
    rig.host.pendingPrepare?(true)
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertTrue(rig.host.saved.isEmpty)
  }

  func testQueuedCallbacksFromOldGenerationStayInert() throws {
    let rig = Rig(), old = rig.start()
    old.startAgain(); old.cancel()
    try wait { rig.states.last == .failed(.cancelled) }
    XCTAssertFalse(rig.states.contains { if case .waiting = $0 { return true }; return false })
    XCTAssertTrue(rig.allCallbacksOnMain)
  }
  func testCancelBeforeInstallAdmissionRemovesPreparingAttempt() throws {
    let rig = Rig(), pair = try authPending(rig)
    rig.host.holdPrepare = true
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.pendingPrepare != nil }
    pair.0.cancel()
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    rig.host.pendingPrepare?(true)
    try wait { rig.states.last == .failed(.cancelled) }
    XCTAssertEqual(rig.keys.inserts, 0)
  }

  func testOldPrepareCannotCrossFolderReplacement() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.host.holdPrepare = true
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.pendingPrepare != nil }
    rig.coordinator.update(configuration: .init(cid: SyncKeys(entropy: Data(count: 32)).chainTag, environment: .init(folderIdentity: Data([10]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)))
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    rig.host.pendingPrepare?(true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertTrue(rig.host.saved.isEmpty)
  }

  func testCancelThenRestartCannotReviveQueuedCancelledCallback() throws {
    let rig = Rig(), h = rig.start()
    h.cancel(); h.startAgain()
    try wait { rig.states.contains { if case .waiting = $0 { return true }; return false } }
    XCTAssertFalse(rig.states.contains(.failed(.cancelled)))
    XCTAssertTrue(rig.coordinator.snapshot.joining)
  }

  func testExpiryAtAccessDetachesOwnerWithoutWaitingForAnotherTick() throws {
    let rig = Rig(), arm = try rig.coordinator.armTrusted()
    try wait { (try? rig.coordinator.requests(arm)) != nil }
    rig.time.now += 120000
    XCTAssertThrowsError(try rig.coordinator.requests(arm))
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertNoThrow(try rig.coordinator.armTrusted())
  }

  func testDisplayCodeUsesOnboardingProtocolSpacing() throws {
    let rig = Rig(), _ = try comparing(rig)
    try wait { rig.states.contains { if case .comparing = $0 { return true }; return false } }
    for state in rig.states {
      if case .comparing(let code, _) = state {
        XCTAssertEqual(code.count, 7)
        XCTAssertEqual(code.dropFirst(3).first, " ")
      }
    }
  }

  func testCommittedCallbacksContinueCapturedInstallAfterStopAndReconfigure() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.saved.count == 1 }
    rig.coordinator.update(configuration: .init(cid: SyncKeys(entropy: Data(count: 32)).chainTag, environment: .init(folderIdentity: Data([10]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)))
    rig.host.initialized?(true); rig.host.ready?(true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(rig.states.contains(.installed))
    XCTAssertEqual(rig.host.saved.count, 1)
    XCTAssertEqual(rig.host.saved.first?.folderIdentity, Data([9]))
  }

  func testRepeatedRestartsBehindProviderHaveBoundedPendingWork() throws {
    let rig = Rig(), reached = expectation(description: "blocked request")
    rig.mailbox.hold = .request; rig.mailbox.reached = { reached.fulfill() }
    let control = rig.start()
    wait(for: [reached], timeout: 3)
    for _ in 0..<100 { control.startAgain() }
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    try wait { rig.states.last == .failed(.folderUnavailable) }
    rig.mailbox.hold = nil; rig.mailbox.release.signal()
  }

  func testAuthenticatedDenialUsesFixedFailureCase() throws {
    let rig = Rig(), _ = try comparing(rig)
    let helper = PairingSessionTests()
    let request = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .request })
    let offer = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .offer })
    let select = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .select })
    let reveal = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .reveal })
    let message = try PairingFormat.decode(reveal.wire)
    guard case .reveal(_, let opening, _) = message.body else { return XCTFail("reveal") }
    let j = try PairingFormat.decode(request.wire)
    guard case .request(let jBody) = j.body else { return XCTFail("request") }
    let transcript = try PairingCrypto.transcript(request: request.wire, offer: offer.wire, select: select.wire, trustedRandom: opening)
    let random = PairingSessionTests.Random(120)
    for _ in 0..<4 { _ = try random.take(16) }
    let privateKey = try random.take(32)
    let keys = try PairingCrypto.keys(secret: PairingCrypto.sharedSecret(privateKey, try PairingCrypto.context(request: request.wire, offer: offer.wire).3.publicKey), transcript: transcript)
    _ = jBody
    let terminal = try helper.entry(PairingCrypto.terminal(role: .trusted, reason: 2, cid: j.cid, rid: j.rid, aid: try XCTUnwrap(offer.aid), keys: keys))
    rig.mailbox.lock.lock(); rig.mailbox.entries.append(terminal); rig.mailbox.lock.unlock()
    rig.coordinator.poll()
    try wait { rig.states.contains(.failed(.denied)) }
  }

  func testDuplicatePrepareCompletionCannotDestroyCommittedInstall() throws {
    let rig = Rig(), _ = try authPending(rig)
    rig.host.holdPrepare = true
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    try wait { rig.host.pendingPrepare != nil }
    rig.host.pendingPrepare?(true); rig.host.pendingPrepare?(true)
    try wait { rig.host.saved.count == 1 }
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    XCTAssertEqual(rig.keys.inserts, 1)
  }

  func testOldComparisonCannotAcknowledgeRemountedSurface() throws {
    let rig = Rig(), pair = try comparing(rig)
    let old = try rig.coordinator.comparison(pair.1)
    try rig.coordinator.hide(pair.1)
    try rig.coordinator.present(pair.1)
    XCTAssertThrowsError(try rig.coordinator.acknowledgeComparison(old))
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    let current = try rig.coordinator.comparison(pair.1)
    XCTAssertNoThrow(try rig.coordinator.acknowledgeComparison(current))
  }

  func testNativeDenyAndSuppressionEndWithoutRearming() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.deny(pair.1)
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
    XCTAssertThrowsError(try rig.coordinator.allow(pair.1))
    rig.coordinator.dismissUnsolicited()
    try wait { rig.store.suppressed }
  }

  func receivedApproval(_ rig: Rig) throws -> (PairingJoinHandle, PairingTrustedHandle) {
    let pair = try authPending(rig)
    rig.contexts[0].reply?(true, nil)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .approval } }
    rig.coordinator.poll()
    return pair
  }

  func testApprovedRequiresKeyWrittenAndInstallAdmission() throws {
    let rig = Rig()
    rig.host.holdPrepare = true
    let pair = try receivedApproval(rig)
    try wait { rig.host.pendingPrepare != nil }
    XCTAssertFalse(rig.states.contains(.approved))
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    rig.host.pendingPrepare?(true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertFalse(rig.states.contains(.approved))
  }

  func testCancelDuringKeyWriteWinsBeforeAdmission() throws {
    let rig = Rig()
    let reached = expectation(description: "key write held")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { reached.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [reached], timeout: 3)
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertFalse(rig.states.contains(.approved))
    rig.keys.insertRelease.signal()
    try wait { if case .found = rig.keys.lookup { return true }; return false }
    XCTAssertTrue(rig.host.saved.isEmpty)
    XCTAssertFalse(rig.states.contains(.approved))
    let installation = try XCTUnwrap(rig.host.prepared.first)
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: rig.store), .orphan)
    XCTAssertFalse(rig.coordinator.committedJoin { _ in XCTFail("cancelled key is not admitted") })
  }

  func testCancelAfterAdmissionReportsCommittedBeforeMainActorDelivery() throws {
    let rig = Rig()
    let pair = try receivedApproval(rig)
    let limit = Date().addingTimeInterval(3)
    while rig.host.saved.isEmpty && Date() < limit { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(rig.host.saved.count, 1)
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    try wait { rig.states.contains(.approved) }
    XCTAssertFalse(rig.states.contains(.failed(.cancelled)))
  }

  func testCommittedJoinAttachesWithoutHandleAndTracksReady() throws {
    let rig = Rig()
    XCTAssertFalse(rig.coordinator.committedJoin { _ in XCTFail("uncommitted observer") })
    var handle: PairingJoinHandle? = try receivedApproval(rig).0
    try wait { rig.host.saved.count == 1 }
    handle = nil
    XCTAssertNil(handle)
    var observer: [PairingJoinState] = []
    XCTAssertTrue(rig.coordinator.committedJoin { observer.append($0) })
    try wait { observer == [.approved] }
    rig.host.ready?(true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(observer, [.approved])
    rig.host.initialized?(true)
    try wait { observer == [.approved, .installed] }
    var resumed: [PairingJoinState] = []
    XCTAssertTrue(rig.coordinator.committedJoin { resumed.append($0) })
    try wait { resumed == [.installed] }
  }

  func testStartAgainAfterCommittedAdmissionIsIgnored() throws {
    let rig = Rig(), pair = try receivedApproval(rig)
    try wait { rig.host.saved.count == 1 }
    let requests = rig.mailbox.externallyVisible.filter { $0.kind == .request }
    pair.0.startAgain()
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    rig.host.initialized?(true); rig.host.ready?(true)
    try wait { rig.states.last == .installed }
    XCTAssertEqual(rig.mailbox.externallyVisible.filter { $0.kind == .request }, requests)
    XCTAssertEqual(rig.keys.inserts, 1)
  }

  func testDelayedOldApprovalCannotInstallReplacement() throws {
    let rig = Rig()
    rig.host.holdPrepare = true
    let pair = try receivedApproval(rig)
    try wait { rig.host.pendingPrepare != nil }
    let callback = rig.host.pendingPrepare
    rig.states = []
    pair.0.startAgain()
    callback?(true)
    try wait { rig.states.contains { if case .waiting = $0 { return true }; return false } }
    XCTAssertFalse(rig.states.contains(.approved))
    XCTAssertFalse(rig.states.contains(.installed))
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
  }

  func testBlockedProviderDoesNotBlockDurableAccountingLane() throws {
    let rig = Rig(), reached = expectation(description: "request blocked")
    rig.mailbox.hold = .request
    rig.mailbox.reached = { reached.fulfill() }
    _ = rig.start()
    wait(for: [reached], timeout: 3)
    defer { rig.mailbox.hold = nil; rig.mailbox.release.signal() }
    let arm = try rig.coordinator.armTrusted()
    try wait { (try? rig.coordinator.requests(arm)) != nil }
    XCTAssertNotNil(rig.store.ledger)
  }

  func testCommittedJoinContinuesAfterSurfaceDisposalAndLock() throws {
    let rig = Rig(), pair = try receivedApproval(rig)
    try wait { rig.host.saved.count == 1 }
    rig.coordinator.invalidate(reason: .surface)
    rig.coordinator.invalidate(reason: .lock)
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    var resumed: [PairingJoinState] = []
    XCTAssertTrue(rig.coordinator.committedJoin { resumed.append($0) })
    rig.host.initialized?(true); rig.host.ready?(true)
    try wait { resumed.last == .installed }
  }

  func testPeriodicPollCadenceUsesTwoSecondsJoiningAndFiveTrusted() throws {
    for joining in [true, false] {
      let rig = Rig()
      if joining {
        _ = rig.start()
        rig.coordinator.tick()
      } else {
        let arm = try rig.coordinator.armTrusted()
        try wait { (try? rig.coordinator.requests(arm)) != nil }
      }
      try wait { rig.mailbox.polls == 1 }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      for _ in 0..<10 { rig.coordinator.tick() }
      RunLoop.current.run(until: Date().addingTimeInterval(0.03))
      XCTAssertEqual(rig.mailbox.polls, 1)
      rig.time.now += joining ? 1999 : 4999
      rig.coordinator.tick()
      RunLoop.current.run(until: Date().addingTimeInterval(0.03))
      XCTAssertEqual(rig.mailbox.polls, 1)
      rig.time.now += 1
      rig.coordinator.tick()
      try wait { rig.mailbox.polls == 2 }
    }
  }

  func testBlockedPollCoalescesHintsIntoOneFollowup() throws {
    let rig = Rig(), reached = expectation(description: "poll held")
    _ = rig.start()
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
    rig.mailbox.holdPoll = true
    rig.mailbox.pollReached = { reached.fulfill() }
    rig.coordinator.poll()
    wait(for: [reached], timeout: 3)
    for _ in 0..<100 { rig.coordinator.poll() }
    XCTAssertEqual(rig.mailbox.polls, 1)
    let followup = expectation(description: "coalesced followup")
    rig.mailbox.pollObserved = { if rig.mailbox.polls == 2 { followup.fulfill() } }
    rig.mailbox.holdPoll = false
    rig.mailbox.pollRelease.signal()
    wait(for: [followup], timeout: 0.2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    XCTAssertEqual(rig.mailbox.polls, 2)
  }

  func testUnavailableMailboxEndsAttemptWithFolderFailure() throws {
    let rig = Rig()
    _ = rig.start()
    rig.mailbox.failPoll = true
    rig.coordinator.poll()
    try wait { rig.states.last == .failed(.folderUnavailable) }
    XCTAssertFalse(rig.coordinator.snapshot.joining)
  }

  func testQueuedOldAttemptStatesAreFilteredNatively() throws {
    let rig = Rig(), control = rig.start()
    control.startAgain()
    try wait { rig.states.count >= 2 }
    XCTAssertEqual(rig.states.count, 2)
    XCTAssertEqual(rig.states.first, .preparing)
    XCTAssertTrue(rig.allCallbacksOnMain)
    XCTAssertEqual(control.cancel(), .cancelled)
  }

  func testEveryGrantProviderWaitRechecksAdmission() throws {
    for schedule in 0..<5 {
      let rig = Rig(), _ = try authPending(rig)
      let reached = expectation(description: "grant held")
      rig.mailbox.hold = .approval
      rig.mailbox.reached = { reached.fulfill() }
      rig.contexts[0].reply?(true, nil)
      wait(for: [reached], timeout: 3)
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
      switch schedule {
      case 0: rig.coordinator.invalidate(reason: .stop)
      case 1: rig.coordinator.invalidate(reason: .lock)
      case 2: rig.time.now += 120000
      case 3: rig.coordinator.invalidate(reason: .key)
      default: rig.coordinator.invalidate(reason: .surface)
      }
      rig.mailbox.release.signal()
      try wait { !rig.coordinator.snapshot.trusted }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
      XCTAssertEqual(rig.store.consumed.count, 1)
    }
  }

  func testEveryRevealProviderWaitRechecksChargedReservation() throws {
    for schedule in 0..<4 {
      let rig = Rig(), _ = rig.start(), arm = try rig.coordinator.armTrusted()
      try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
      rig.coordinator.poll()
      try wait { ((try? rig.coordinator.requests(arm)) ?? []).count == 1 }
      try rig.coordinator.pin(XCTUnwrap(rig.coordinator.requests(arm).first), handle: arm)
      let reached = expectation(description: "reveal held")
      rig.mailbox.hold = .reveal
      rig.mailbox.reached = { reached.fulfill() }
      for _ in 0..<4 { rig.coordinator.poll(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
      wait(for: [reached], timeout: 3)
      switch schedule {
      case 0: rig.coordinator.invalidate(reason: .stop)
      case 1: rig.coordinator.invalidate(reason: .lock)
      case 2: rig.time.now += 120000
      default:
        rig.coordinator.update(configuration: .init(cid: SyncKeys(entropy: Data(count: 32)).chainTag, environment: .init(folderIdentity: Data([10]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)))
      }
      rig.mailbox.release.signal()
      try wait { !rig.coordinator.snapshot.trusted }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .reveal })
      XCTAssertEqual(rig.store.ledger?.reveals.count, 1)
      if case .restored(let charged) = rig.store.restoreAccounting(now: rig.time.read(), epoch: Data([1])) { XCTAssertEqual(charged.reveals.count, 1) }
      else { XCTFail("reservation must survive restart") }
    }
  }

  func testCancelCleansOnlyExactOwnedPackets() throws {
    let rig = Rig(), handle = rig.start()
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
    let request = try XCTUnwrap(rig.mailbox.externallyVisible.first)
    let replacement = S.Entry(rid: request.rid, aid: request.aid, kind: request.kind, wire: Data(repeating: 7, count: request.wire.count))
    rig.mailbox.lock.lock(); rig.mailbox.entries = [replacement]; rig.mailbox.lock.unlock()
    handle.cancel()
    try wait { !rig.mailbox.removals.isEmpty }
    XCTAssertEqual(rig.mailbox.externallyVisible, [replacement])
    XCTAssertEqual(rig.mailbox.removals.flatMap { $0 }, [request])
  }

  func testReceiptRetainsSixtySecondGraceThenCleansOwnedPackets() throws {
    let rig = Rig(), _ = try receivedApproval(rig)
    try wait { rig.host.saved.count == 1 }
    rig.host.initialized?(true); rig.host.ready?(true)
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
    rig.time.now += 59999
    rig.coordinator.tick()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    XCTAssertTrue(rig.mailbox.externallyVisible.contains { $0.kind == .receipt })
    rig.time.now += 1
    rig.coordinator.tick()
    try wait { !rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
    XCTAssertEqual(rig.states.last, .installed)
  }

  func testTrustedReadinessRescansRequestSkippedDuringDurableCheckpoint() throws {
    let rig = Rig(), reached = expectation(description: "accounting held")
    _ = rig.start()
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
    rig.store.holdAccounting = true
    rig.store.accountingReached = { reached.fulfill() }
    let arm = try rig.coordinator.armTrusted()
    wait(for: [reached], timeout: 3)
    rig.coordinator.poll()
    try wait { rig.mailbox.polls == 1 }
    rig.store.holdAccounting = false
    rig.store.accountingRelease.signal()
    let limit = Date().addingTimeInterval(0.2)
    while ((try? rig.coordinator.requests(arm)) ?? []).isEmpty, Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    XCTAssertEqual(try rig.coordinator.requests(arm).count, 1)
  }

  func testReceiptGraceBeginsAfterProviderDelivery() throws {
    let rig = Rig(), _ = try receivedApproval(rig)
    try wait { rig.host.saved.count == 1 }
    let reached = expectation(description: "receipt held")
    rig.mailbox.hold = .receipt
    rig.mailbox.reached = { reached.fulfill() }
    rig.host.initialized?(true); rig.host.ready?(true)
    wait(for: [reached], timeout: 3)
    rig.time.now += 60000
    rig.coordinator.tick()
    rig.mailbox.hold = nil
    rig.mailbox.release.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    XCTAssertTrue(rig.mailbox.externallyVisible.contains { $0.kind == .receipt })
    rig.time.now += 59999
    rig.coordinator.tick()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertTrue(rig.mailbox.externallyVisible.contains { $0.kind == .receipt })
    rig.time.now += 1
    rig.coordinator.tick()
    try wait { !rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
  }

  func testRejectedPollDoesNotPermanentlyWedgeFuturePolling() throws {
    let rig = Rig()
    let providerReached = expectation(description: "held request")
    let accountingReached = expectation(description: "held accounting")
    rig.mailbox.hold = .request
    rig.mailbox.reached = { providerReached.fulfill() }
    rig.store.holdAccounting = true
    rig.store.accountingReached = { accountingReached.fulfill() }
    let control = rig.start()
    wait(for: [providerReached], timeout: 3)
    _ = try rig.coordinator.armTrusted()
    wait(for: [accountingReached], timeout: 3)
    for _ in 0..<15 { control.startAgain() }
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    rig.coordinator.poll()
    try wait { !rig.coordinator.snapshot.joining }
    rig.mailbox.hold = nil
    rig.store.holdAccounting = false
    rig.mailbox.release.signal()
    rig.store.accountingRelease.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    _ = rig.start()
    try wait { rig.mailbox.externallyVisible.contains { $0.kind == .request } }
    rig.coordinator.poll()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertGreaterThan(rig.mailbox.polls, 0)
  }

  func testNativeDenyDeliversAuthenticatedFailureToJoiningPeer() throws {
    let rig = Rig(), pair = try comparing(rig)
    try rig.coordinator.deny(pair.1)
    try wait { rig.mailbox.everVisible.contains { $0.kind == .trustedTerminal } }
    rig.coordinator.poll()
    try wait { rig.states.last == .failed(.denied) }
    XCTAssertFalse(rig.coordinator.snapshot.trusted)
  }

  func testNativeCancelDeliversAuthenticatedTerminalWithoutGrant() throws {
    let rig = Rig(), pair = try comparing(rig)
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    try wait { rig.mailbox.everVisible.contains { $0.kind == .joiningTerminal } }
    rig.coordinator.poll()
    try wait { !rig.coordinator.snapshot.trusted }
    XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .approval })
  }

  func testTerminalProviderWaitFiltersStopAndReplacement() throws {
    for replace in [false, true] {
      let rig = Rig(), pair = try comparing(rig)
      let reached = expectation(description: "terminal held")
      rig.mailbox.hold = .trustedTerminal
      rig.mailbox.reached = { reached.fulfill() }
      try rig.coordinator.deny(pair.1)
      wait(for: [reached], timeout: 0.2)
      if replace { _ = rig.start() } else { rig.coordinator.invalidate(reason: .stop) }
      rig.mailbox.hold = nil
      rig.mailbox.release.signal()
      RunLoop.current.run(until: Date().addingTimeInterval(0.03))
      XCTAssertFalse(rig.mailbox.everVisible.contains { $0.kind == .trustedTerminal })
    }
  }

  func testAuthenticatedApprovalWithWrongRootNeverPreparesOrSaves() throws {
    let rig = Rig(), _ = try comparing(rig)
    let request = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .request })
    let offer = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .offer })
    let select = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .select })
    let reveal = try XCTUnwrap(rig.mailbox.externallyVisible.first { $0.kind == .reveal })
    let message = try PairingFormat.decode(reveal.wire)
    guard case .reveal(_, let opening, _) = message.body else { return XCTFail("reveal") }
    let transcript = try PairingCrypto.transcript(request: request.wire, offer: offer.wire, select: select.wire, trustedRandom: opening)
    let random = PairingSessionTests.Random(120)
    for _ in 0..<4 { _ = try random.take(16) }
    let privateKey = try random.take(32)
    let (j, joining, t, trusted) = try PairingCrypto.context(request: request.wire, offer: offer.wire)
    let keys = try PairingCrypto.keys(secret: PairingCrypto.sharedSecret(privateKey, trusted.publicKey), transcript: transcript)
    let wrongRoot = Data(repeating: 55, count: 32)
    XCTAssertNotEqual(SyncKeys(entropy: wrongRoot).chainTag, SyncKeys(entropy: Data(count: 32)).chainTag)
    let payload = PairingCrypto.Approval(entropy: wrongRoot, cid: j.cid, rid: j.rid, aid: try XCTUnwrap(t.aid), joiningSession: joining.session, trustedDevice: Data(repeating: 6, count: 16), transcript: transcript, approvedMs: 1793552400000, expiresMs: trusted.expiresMs)
    let wire = try PairingCrypto.seal(PairingCrypto.approvalPlaintext(payload), type: 6, cid: j.cid, rid: j.rid, aid: try XCTUnwrap(t.aid), keys: keys, label: "approval AAD", key: "approval", rng: random.take)
    let entry = S.Entry(rid: j.rid, aid: t.aid, kind: .approval, wire: wire)
    rig.mailbox.lock.lock(); rig.mailbox.entries.append(entry); rig.mailbox.lock.unlock()
    rig.coordinator.poll()
    try wait { rig.states.contains(.failed(.invalidPeer)) || !rig.host.prepared.isEmpty }
    XCTAssertTrue(rig.host.prepared.isEmpty)
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertFalse(rig.states.contains(.approved))
  }

  func testHostPrepareRefusalBlocksVanishedSelectedCIDBeforeKeyWrite() throws {
    let rig = Rig()
    rig.host.prepareResult = false
    _ = try receivedApproval(rig)
    try wait { rig.states.last == .failed(.invalidPeer) }
    XCTAssertEqual(rig.host.prepared.count, 1)
    XCTAssertEqual(rig.keys.inserts, 0)
    XCTAssertTrue(rig.host.saved.isEmpty)
    XCTAssertFalse(rig.states.contains(.approved))
  }

  func testFolderReplacementRejectsOldTransportForNewAttempts() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    let rig = Rig(), cid = SyncKeys(entropy: Data(count: 32)).chainTag
    let mailbox = try PairingMailbox(folder: old, cid: cid)
    var config = PairingCoordinator.Configuration(cid: cid, environment: .init(folderIdentity: Data([9]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16))
    config.environment.folderIdentity = mailbox.folderIdentity
    let owner = PairingCoordinator(configuration: config, mailbox: mailbox, store: rig.store, authenticator: rig.auth, keyStore: rig.keys, host: rig.host, clock: rig.time.read, wall: { 1793552400000 }, random: rig.rng.take)
    config.environment.folderIdentity = Data([10])
    config.environment.folderGeneration += 1
    owner.update(configuration: config)
    let handle = owner.start(cid: cid) { _ in }
    defer { handle.cancel() }
    guard let arm = try? owner.armTrusted() else {
      RunLoop.current.run(until: Date().addingTimeInterval(0.03))
      XCTAssertTrue(mailbox.poll(rids: []).entries.isEmpty)
      return
    }
    try wait { mailbox.poll(rids: []).entries.contains { $0.kind == .request } }
    owner.poll()
    try wait { ((try? owner.requests(arm)) ?? []).count == 1 }
    try owner.pin(XCTUnwrap(owner.requests(arm).first), handle: arm)
    for _ in 0..<12 {
      owner.poll()
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try wait { owner.snapshot.trustedPhase == .comparing }
    try owner.acknowledgeComparison(owner.comparison(arm))
    try owner.allow(arm)
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts.last?.reply?(true, nil)
    try wait { mailbox.poll(rids: []).entries.contains { $0.kind == .approval } }
    XCTAssertTrue(try PairingMailbox(folder: new, cid: cid).poll(rids: []).entries.isEmpty)
    XCTAssertFalse(mailbox.poll(rids: []).entries.contains { $0.kind == .approval }, "fresh attempt bound to replacement folder releases a decryptable grant into the old provider")
  }

  func testInitializationRetryPublishesAncestorBeforeAnyCommittedObserver() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote")
    let parent = local.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let barriers = PairingDurableStoreTests.DirectoryBarriers(failedParent: parent)
    let io = PairingPOSIXDurableIO(barriers: barriers)
    let evidence = PairingFirstInstallationEvidence(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: true)
    let epoch = Data(repeating: 1, count: 16)
    let original = try PairingDurableStore(dataDirectory: local, syncFolder: remote, firstInstallation: evidence, io: io)
    guard case .unreadable = original.restoreAccounting(now: 100, epoch: epoch) else { return XCTFail("initial parent barrier did not fail restoreAccounting") }
    XCTAssertTrue(barriers.parentFailed)
    XCTAssertFalse(barriers.parentSucceeded)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.directory.path))
    let reopened = try PairingDurableStore(dataDirectory: local, syncFolder: remote, firstInstallation: evidence, io: io)
    let rig = Rig()
    rig.mailbox.pairingFolder = remote
    rig.clockEpoch = epoch
    rig.durableStore = reopened
    rig.host.holdKeySaved = true
    let pair = try receivedApproval(rig)
    try wait { rig.states.contains(.approved) && rig.host.heldKeySaved != nil }
    XCTAssertTrue(barriers.parentSucceeded, "approved observed before failed ancestor publication was repaired")
    var resumed: [PairingJoinState] = []
    XCTAssertTrue(rig.coordinator.committedJoin { state in
      XCTAssertTrue(barriers.parentSucceeded)
      resumed.append(state)
    })
    try wait { resumed == [.approved] }
    XCTAssertTrue(barriers.parentSucceeded, "committedJoin acknowledged an unpublished ancestor")
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    XCTAssertTrue(barriers.parentSucceeded, "alreadyCommitted acknowledged an unpublished ancestor")
    XCTAssertTrue(rig.host.saved.isEmpty)
    let installation = try XCTUnwrap(rig.host.prepared.first)
    XCTAssertEqual(try reopened.installationDecision(for: installation)?.disposition, .admitted)
  }

  func testDurableAdmissionPrecedesCommittedVisibilityWithHeldHost() throws {
    let rig = Rig()
    rig.host.holdKeySaved = true
    let pair = try receivedApproval(rig)
    try wait { rig.host.heldKeySaved != nil }
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    XCTAssertTrue(rig.coordinator.committedJoin { _ in })
    XCTAssertTrue(rig.host.saved.isEmpty)
    XCTAssertEqual(rig.store.admitted, rig.host.prepared)
    XCTAssertEqual(rig.store.admitted.count, 1)
    let installation = try XCTUnwrap(rig.host.prepared.first)
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: rig.store), .saved)
  }

  func testCancellationCrashCutKeepsSavedKeyAsOrphan() throws {
    let rig = Rig(), reached = expectation(description: "insert underway")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { reached.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [reached], timeout: 3)
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    rig.keys.insertRelease.signal()
    try wait { if case .found = rig.keys.lookup { return true }; return false }
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertTrue(rig.host.saved.isEmpty)
    XCTAssertEqual(rig.store.cancelled, rig.host.prepared)
    let installation = try XCTUnwrap(rig.host.prepared.first)
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: rig.store), .orphan)
  }

  func testQueuedKeyWorkRevalidatesCancelExpiryAndFolderReplacement() throws {
    for schedule in 0..<3 {
      let rig = Rig()
      rig.host.holdPrepare = true
      let pair = try receivedApproval(rig)
      try wait { rig.host.pendingPrepare != nil }
      let blocked = expectation(description: "local lane held")
      rig.store.holdAccounting = true
      rig.store.accountingReached = { blocked.fulfill() }
      try rig.coordinator.deny(pair.1)
      wait(for: [blocked], timeout: 3)
      rig.host.pendingPrepare?(true)
      _ = rig.coordinator.snapshot
      switch schedule {
      case 0: XCTAssertEqual(pair.0.cancel(), .cancelled)
      case 1: rig.time.now += 300000
      default:
        rig.coordinator.update(configuration: .init(cid: SyncKeys(entropy: Data(count: 32)).chainTag, environment: .init(folderIdentity: Data([10]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16)))
      }
      XCTAssertEqual(rig.keys.inserts, 0)
      let drained = expectation(description: "local lane drained")
      rig.store.suppressionObserved = { drained.fulfill() }
      rig.coordinator.dismissUnsolicited()
      rig.store.holdAccounting = false
      rig.store.accountingRelease.signal()
      wait(for: [drained], timeout: 3)
      XCTAssertEqual(rig.keys.inserts, 0, "write must not start after local wait invalidates attempt")
      XCTAssertTrue(rig.host.saved.isEmpty)
      XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    }
  }

  func testPostInsertReadbackMustMatchAndRemainAccessible() throws {
    for readback in [PairingKeyLookup.found(Data(repeating: 7, count: 32)), .absent, .failure] {
      let rig = Rig()
      rig.keys.readback = readback
      _ = try receivedApproval(rig)
      try wait { rig.states.last == .failed(.invalidPeer) || rig.coordinator.committedJoin { _ in } }
      XCTAssertEqual(rig.keys.inserts, 1)
      XCTAssertFalse(rig.coordinator.committedJoin { _ in })
      XCTAssertFalse(rig.states.contains(.approved))
      XCTAssertTrue(rig.host.saved.isEmpty)
    }
  }

  func testAdmissionReadbackPrecedesEveryCommittedObserver() throws {
    let rig = Rig(), held = expectation(description: "decision held")
    rig.store.holdDecision = true
    rig.store.decisionReached = { held.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [held], timeout: 3)
    XCTAssertEqual(pair.0.cancel(), .unavailable)
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertFalse(rig.states.contains(.approved))
    rig.store.decisionRelease.signal()
    try wait { rig.states.contains(.approved) }
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    XCTAssertTrue(rig.coordinator.committedJoin { _ in })
    XCTAssertEqual(rig.store.admitted.count, 1)
  }

  func testAdmissionPersistenceOrReadbackFailureNeverReportsCommitted() throws {
    for badReadback in [false, true] {
      let rig = Rig()
      rig.store.failDecision = !badReadback
      rig.store.badDecisionReadback = badReadback
      let pair = try receivedApproval(rig)
      try wait { rig.states.last == .failed(.folderUnavailable) }
      XCTAssertTrue(rig.coordinator.snapshot.joining)
      XCTAssertFalse(rig.coordinator.committedJoin { _ in })
      XCTAssertEqual(pair.0.cancel(), .unavailable)
      rig.store.failDecision = false
      rig.store.badDecisionReadback = false
      XCTAssertEqual(pair.0.cancel(), .cancelled)
      XCTAssertFalse(rig.states.contains(.approved))
      XCTAssertTrue(rig.host.saved.isEmpty)
      XCTAssertEqual(rig.keys.inserts, 1)
    }
  }

  func testCommittedReceiptAndCleanupKeepCapturedTransportAfterFolderChange() throws {
    let rig = Rig(), pair = try receivedApproval(rig)
    try wait { rig.host.saved.count == 1 }
    let replacement = Mailbox()
    replacement.pairingFolderIdentity = Data([10])
    let config = PairingCoordinator.Configuration(cid: replacement.pairingCID, environment: .init(folderIdentity: Data([10]), entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16))
    rig.coordinator.update(configuration: config, mailbox: replacement)
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    rig.host.initialized?(true)
    rig.host.ready?(true)
    try wait { rig.states.last == .installed && rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
    XCTAssertTrue(replacement.externallyVisible.isEmpty)
    rig.time.now += 60000
    rig.coordinator.tick()
    try wait { !rig.mailbox.externallyVisible.contains { $0.kind == .receipt } }
    XCTAssertTrue(replacement.removals.isEmpty)
  }

  func testReplacementMailboxUsesActualNewFolderAndRejectsWrongCID() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let rig = Rig(), cid = SyncKeys(entropy: Data(count: 32)).chainTag
    let old = try PairingMailbox(folder: a, cid: cid), selected = try PairingMailbox(folder: b, cid: cid)
    var config = PairingCoordinator.Configuration(cid: cid, environment: .init(folderIdentity: old.folderIdentity, entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16))
    let owner = PairingCoordinator(configuration: config, mailbox: old, store: rig.store, authenticator: rig.auth, keyStore: rig.keys, host: rig.host, clock: rig.time.read, wall: { 1793552400000 }, random: rig.rng.take)
    config.environment.folderIdentity = selected.folderIdentity
    config.environment.folderGeneration += 1
    owner.update(configuration: config, mailbox: selected)
    let handle = owner.start(cid: cid) { _ in }
    defer { handle.cancel() }
    let arm = try owner.armTrusted()
    try wait { selected.poll(rids: []).entries.contains { $0.kind == .request } }
    owner.poll()
    try wait { ((try? owner.requests(arm)) ?? []).count == 1 }
    try owner.pin(XCTUnwrap(owner.requests(arm).first), handle: arm)
    for _ in 0..<12 { owner.poll(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try wait { owner.snapshot.trustedPhase == .comparing }
    try owner.acknowledgeComparison(owner.comparison(arm))
    try owner.allow(arm)
    try wait { rig.contexts.last?.reply != nil }
    rig.contexts.last?.reply?(true, nil)
    try wait { selected.poll(rids: []).entries.contains { $0.kind == .approval } }
    XCTAssertTrue(old.poll(rids: []).entries.isEmpty)
    owner.invalidate(reason: .stop)
    let otherCID = SyncKeys(entropy: Data(repeating: 1, count: 32)).chainTag
    config.cid = otherCID
    owner.update(configuration: config, mailbox: selected)
    XCTAssertThrowsError(try owner.armTrusted())
    var states: [PairingJoinState] = []
    _ = owner.start(cid: otherCID) { states.append($0) }
    try wait { states.contains(.failed(.invalidPeer)) }
  }

  func testNewSelectedFolderCannotContainPrivateDurableStore() throws {
    let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    let rig = Rig(), cid = SyncKeys(entropy: Data(count: 32)).chainTag
    let old = try PairingMailbox(folder: a, cid: cid), replacement = try PairingMailbox(folder: root, cid: cid)
    let store = try PairingDurableStore(dataDirectory: root.appendingPathComponent("private"), syncFolder: a, firstInstallation: .init(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: true))
    var config = PairingCoordinator.Configuration(cid: cid, environment: .init(folderIdentity: old.folderIdentity, entropyHandle: Data([8]), clockEpoch: Data([1])), localName: "Fixture Mac", entropy: Data(count: 32), trustedDevice: Data(repeating: 6, count: 16))
    let owner = PairingCoordinator(configuration: config, mailbox: old, store: store, authenticator: rig.auth, keyStore: rig.keys, host: rig.host, clock: rig.time.read, wall: { 1793552400000 }, random: rig.rng.take)
    XCTAssertNoThrow(try owner.armTrusted())
    config.environment.folderIdentity = replacement.folderIdentity
    owner.update(configuration: config, mailbox: replacement)
    XCTAssertThrowsError(try owner.armTrusted())
    _ = owner.start(cid: cid) { _ in }
    XCTAssertFalse(owner.snapshot.joining)
    XCTAssertTrue(old.poll(rids: []).entries.isEmpty)
    XCTAssertTrue(replacement.poll(rids: []).entries.isEmpty)
  }

  func testUncertainAdmissionCannotReportCancelledBeforeDurableResolution() throws {
    let rig = Rig()
    rig.store.badDecisionReadback = true
    let pair = try receivedApproval(rig)
    try wait { !rig.store.admitted.isEmpty }
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertEqual(pair.0.cancel(), .unavailable)
    XCTAssertFalse(rig.states.contains(.approved))
    let installation = try XCTUnwrap(rig.host.prepared.first)
    rig.store.badDecisionReadback = false
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: rig.store), .orphan)
  }

  func testUnavailableCancellationKeepsNativeOwnerDespiteCallerTreatingItAsCancelled() throws {
    let rig = Rig()
    rig.store.badDecisionReadback = true
    let pair = try receivedApproval(rig)
    try wait { rig.states.last == .failed(.folderUnavailable) }
    let installation = try XCTUnwrap(rig.host.prepared.first)
    let savedKey = rig.keys.lookup
    XCTAssertEqual(rig.store.admitted, [installation])
    rig.store.failDecision = true
    let result = pair.0.cancel()
    let callerWouldLeaveSetup = result != .alreadyCommitted
    XCTAssertTrue(callerWouldLeaveSetup)
    XCTAssertEqual(result, .unavailable)
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    let initialRequests = rig.mailbox.everVisible.filter { $0.kind == .request }
    pair.0.startAgain()
    var replacementStates: [PairingJoinState] = []
    let replacement = rig.coordinator.start(cid: rig.mailbox.pairingCID) { replacementStates.append($0) }
    try wait { replacementStates.last == .failed(.folderUnavailable) }
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    XCTAssertEqual(rig.mailbox.everVisible.filter { $0.kind == .request }, initialRequests)
    XCTAssertEqual(rig.host.prepared, [installation])
    XCTAssertEqual(rig.store.admitted, [installation])
    XCTAssertTrue(rig.store.cancelled.isEmpty)
    XCTAssertEqual(rig.keys.lookup, savedKey)
    var resumed: [PairingJoinState] = []
    let hasCommittedJoin = rig.coordinator.committedJoin { resumed.append($0) }
    let consumerState: PairingJoinState? = hasCommittedJoin ? nil : .failed(.folderUnavailable)
    XCTAssertFalse(hasCommittedJoin)
    XCTAssertEqual(consumerState, .failed(.folderUnavailable))
    XCTAssertTrue(resumed.isEmpty)
    XCTAssertFalse(rig.states.contains(.approved))
    XCTAssertTrue(rig.coordinator.snapshot.joining)
    rig.store.badDecisionReadback = false
    rig.store.failDecision = false
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
    XCTAssertEqual(rig.store.cancelled, [installation])
    XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: rig.store), .orphan)
    withExtendedLifetime(replacement) {}
  }

  func testCancellationPersistenceFailureCannotClaimCancellation() throws {
    let rig = Rig(), held = expectation(description: "insert in flight")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { held.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [held], timeout: 3)
    rig.store.failDecision = true
    XCTAssertEqual(pair.0.cancel(), .unavailable)
    rig.keys.insertRelease.signal()
    try wait { if case .found = rig.keys.lookup { return true }; return false }
    XCTAssertFalse(rig.coordinator.committedJoin { _ in })
    XCTAssertFalse(rig.states.contains(.approved))
    pair.0.startAgain()
    _ = rig.start()
    XCTAssertEqual(rig.keys.inserts, 1)
    rig.store.failDecision = false
    XCTAssertEqual(pair.0.cancel(), .cancelled)
    XCTAssertFalse(rig.coordinator.snapshot.joining)
  }

  func testHeldHostCrashCutsReopenDurableAdmissionAndCancellation() throws {
    for cancelled in [false, true] {
      let root = SyncTestDirectory.url.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
      try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
      let evidence = PairingFirstInstallationEvidence(noPairingEraSyncState: true, noJoinOrStopMarker: true, keyStateKnown: true)
      let store = try PairingDurableStore(dataDirectory: local, syncFolder: remote, firstInstallation: evidence)
      let rig = Rig(), reached = expectation(description: "crash cut")
      rig.mailbox.pairingFolder = remote
      rig.clockEpoch = Data(repeating: 1, count: 16)
      rig.durableStore = store
      rig.host.holdKeySaved = true
      rig.keys.holdInsert = cancelled
      rig.keys.insertReached = { reached.fulfill() }
      let pair = try receivedApproval(rig)
      if cancelled {
        wait(for: [reached], timeout: 3)
        XCTAssertEqual(pair.0.cancel(), .cancelled)
        rig.keys.insertRelease.signal()
        try wait { if case .found = rig.keys.lookup { return true }; return false }
      } else {
        reached.fulfill()
        wait(for: [reached], timeout: 3)
        try wait { rig.host.heldKeySaved != nil }
        XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
      }
      XCTAssertTrue(rig.host.saved.isEmpty)
      let installation = try XCTUnwrap(rig.host.prepared.first)
      let reopened = try PairingDurableStore(dataDirectory: local, syncFolder: remote, firstInstallation: evidence)
      XCTAssertEqual(try reopened.installationDecision(for: installation)?.disposition, cancelled ? .cancelled : .admitted)
      XCTAssertEqual(PairingInstallationRecovery.reconcile(stage: .prepared, selectedCID: try PairingFormat.cid(installation.cid), account: installation.device, keys: rig.keys, installation: installation, store: reopened), cancelled ? .orphan : .saved)
      XCTAssertEqual(rig.coordinator.committedJoin { _ in }, !cancelled)
    }
  }

  func testDetachedHandlePreservesCommittedAndUncertainCancellationResults() throws {
    for uncertain in [false, true] {
      var rig: Rig? = Rig()
      rig!.store.badDecisionReadback = uncertain
      let pair = try receivedApproval(rig!)
      try wait { uncertain ? rig!.states.last == .failed(.folderUnavailable) : rig!.host.saved.count == 1 }
      weak var owner = rig!.coordinator
      rig = nil
      try wait { owner == nil }
      XCTAssertEqual(pair.0.cancel(), uncertain ? .unavailable : .alreadyCommitted)
    }
  }


  func testCommittedHostDispatchSurvivesOrdinaryQueueCapacity() throws {
    let rig = Rig(), held = expectation(description: "key work in flight")
    rig.keys.holdInsert = true
    rig.keys.insertReached = { held.fulfill() }
    let pair = try receivedApproval(rig)
    wait(for: [held], timeout: 3)
    let lane = expectation(description: "accounting holds lane")
    rig.store.holdAccounting = true
    rig.store.accountingReached = { lane.fulfill() }
    let provider = expectation(description: "provider cleanup holds lane")
    rig.mailbox.holdRemoval = true
    rig.mailbox.removalReached = { provider.fulfill() }
    rig.coordinator.dismissUnsolicited()
    wait(for: [provider], timeout: 3)
    defer { rig.mailbox.holdRemoval = false; rig.mailbox.removalRelease.signal() }
    for _ in 0..<27 { rig.coordinator.dismissUnsolicited() }
    rig.keys.insertRelease.signal()
    wait(for: [lane], timeout: 3)
    try wait { rig.coordinator.committedJoin { _ in } }
    XCTAssertEqual(pair.0.cancel(), .alreadyCommitted)
    let drained = expectation(description: "local work drained")
    drained.expectedFulfillmentCount = 29
    rig.store.suppressionObserved = { drained.fulfill() }
    rig.coordinator.dismissUnsolicited()
    rig.store.holdAccounting = false
    rig.store.accountingRelease.signal()
    wait(for: [drained], timeout: 3)
    XCTAssertEqual(rig.host.saved.count, 1)
  }
}
