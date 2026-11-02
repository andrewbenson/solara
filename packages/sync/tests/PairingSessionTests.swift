import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingSessionTests: XCTestCase {
  typealias S = PairingSession
  typealias F = PairingFormat
  typealias C = PairingCrypto

  final class Time {
    var now: UInt64 = 1000
    func read() -> UInt64 { now }
  }

  final class Random {
    var counter: UInt64
    var sizes: [Int] = []
    var scripted: [Data] = []
    init(_ seed: UInt64) { counter = seed }
    func take(_ size: Int) throws -> Data {
      sizes.append(size)
      if !scripted.isEmpty {
        let value = scripted.removeFirst()
        XCTAssertEqual(value.count, size)
        return value
      }
      var value = Data()
      while value.count < size {
        counter += 1
        value += C.hash(F.u64(counter))
      }
      return Data(value.prefix(size))
    }
  }

  struct Pair {
    var j: S
    var t: S
    var time: Time
    var request: S.Entry
    var offer: S.Entry
    var selection: S.Entry
    var reservation: S.Accounting
    var reveal: S.Entry
    var handshakeKeys: C.Keys
  }

  let wall: UInt64 = 1793552400000
  func data(_ byte: UInt8, _ count: Int = 16) -> Data { Data(repeating: byte, count: count) }
  func cid() throws -> Data { try F.cid(SyncKeys(entropy: Data(count: 32)).chainTag) }
  func environment(_ role: F.Role) -> S.Environment {
    S.Environment(folderIdentity: data(9), entropyHandle: role == .trusted ? data(8) : nil, clockEpoch: data(1))
  }
  func session(_ role: F.Role, _ time: Time, seed: UInt64 = 1, accounting: S.Accounting? = nil, bits: Int = 30, env: S.Environment? = nil, rng: Random? = nil, name: String? = nil) throws -> S {
    let random = rng ?? Random(seed)
    return try S(role: role, cid: cid(), environment: env ?? environment(role), localName: name ?? (role == .joining ? "Andrew’s MacBook Pro" : "Hill Studio"), clock: time.read, random: random.take, restoration: accounting.map { .restored($0) } ?? .newInstallation, comparisonBits: bits)
  }
  func entry(_ wire: Data) throws -> S.Entry {
    let m = try F.decode(wire)
    return S.Entry(rid: m.rid, aid: m.aid == Data(count: 16) ? nil : m.aid, kind: try XCTUnwrap(S.Kind(rawValue: wire[5])), wire: wire)
  }
  func write(_ output: S.Output, _ kind: S.Kind, file: StaticString = #filePath, line: UInt = #line) throws -> S.Entry {
    try XCTUnwrap(output.writes.first(where: { $0.kind == kind }), "Missing expected \(kind) write", file: file, line: line)
  }
  func pair(seed: UInt64 = 10, bits: Int = 30) throws -> Pair {
    let time = Time(), j = try session(.joining, time, seed: seed, bits: bits), t = try session(.trusted, time, seed: seed + 100, bits: bits)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    _ = try t.arm()
    let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall + 1000), .offer)
    _ = try j.receive(offer)
    let selection = try write(j.selectOffer(offer, handle: j.handle), .select)
    let reserved = try t.receive(selection)
    XCTAssertTrue(reserved.writes.isEmpty)
    let accounting = try XCTUnwrap(reserved.accounting, "Reveal must reserve durable accounting first")
    let reveal = try write(t.persistedAccounting(accounting), .reveal)
    let fixtureRandom = Random(seed + 100)
    for _ in 0..<3 { _ = try fixtureRandom.take(16) }
    let privateKey = try fixtureRandom.take(32)
    let contribution = try fixtureRandom.take(32)
    let (_, joining, _, _) = try C.context(request: request.wire, offer: offer.wire)
    let transcript = try C.transcript(request: request.wire, offer: offer.wire, select: selection.wire, trustedRandom: contribution)
    let keys = try C.keys(secret: C.sharedSecret(privateKey, joining.publicKey), transcript: transcript)
    return Pair(j: j, t: t, time: time, request: request, offer: offer, selection: selection, reservation: accounting, reveal: reveal, handshakeKeys: keys)
  }
  func ready(_ p: Pair, earlyName: Bool = false) throws -> (S.Entry, S.Entry, S.Entry) {
    let opened = try p.j.receive(p.reveal)
    let confirm = try write(opened, .confirm), jName = try write(opened, .joiningName)
    XCTAssertNil(p.j.code)
    if earlyName {
      XCTAssertTrue(try p.t.receive(jName).writes.isEmpty)
      XCTAssertNil(p.t.peerName)
      XCTAssertNil(p.t.code)
    }
    var confirmed = try p.t.receive(confirm)
    if !earlyName { confirmed = try p.t.receive(jName) }
    let tName = try write(confirmed, .trustedName)
    _ = try p.j.receive(tName)
    XCTAssertEqual(p.j.code, p.t.code)
    XCTAssertEqual(p.j.peerName, "Hill Studio")
    XCTAssertEqual(p.t.peerName, "Andrew’s MacBook Pro")
    XCTAssertNotNil(p.j.code)
    XCTAssertNotNil(p.t.code)
    return (confirm, jName, tName)
  }
  func grant(_ p: Pair) throws -> Data {
    let (j, request, t, offer) = try C.context(request: p.request.wire, offer: p.offer.wire)
    return try C.sealApproval(C.Approval(entropy: Data(count: 32), cid: j.cid, rid: j.rid, aid: t.aid, joiningSession: request.session, trustedDevice: data(6), transcript: p.handshakeKeys.transcript, approvedMs: wall + 10000, expiresMs: offer.expiresMs), keys: p.handshakeKeys, rng: Random(700).take)
  }
  func acknowledge(_ p: Pair) throws -> S.Authorization {
    _ = try p.t.acknowledgeComparison(handle: p.t.handle, generation: p.t.comparisonGeneration)
    return try p.t.authorization()
  }
  func foreignCandidate(seed: UInt64 = 10) throws -> S.ValidatedApprovalCandidate {
    let p = try pair(seed: seed)
    _ = try ready(p)
    return try XCTUnwrap(p.j.receive(entry(grant(p))).approvalCandidate)
  }
  func corrupt(_ value: S.Entry, offset: Int) -> S.Entry {
    var value = value
    value.wire[offset] ^= 1
    return value
  }
  func failed(_ session: S, _ value: S.Entry, file: StaticString = #filePath, line: UInt = #line) throws {
    let result = try session.receive(value)
    XCTAssertEqual(session.phase, .ended, file: file, line: line)
    XCTAssertNil(session.code, file: file, line: line)
    XCTAssertNil(session.peerName, file: file, line: line)
    XCTAssertFalse(result.writes.contains(where: { [.confirm, .joiningName, .trustedName, .approval].contains($0.kind) }), file: file, line: line)
  }

  func testHonestRoundTripNamesComparisonAndOpaqueGrant() throws {
    let p = try pair()
    _ = try ready(p)
    XCTAssertEqual(p.j.code?.count, 6)
    XCTAssertThrowsError(try p.t.authorization())
    let tuple = try acknowledge(p), wire = try grant(p)
    let sent = try write(p.t.commitApproval(wire: wire, ownerAuthentication: SyntheticPairingOwnerAuthenticator.authenticated( tuple)), .approval)
    XCTAssertEqual(sent.wire, wire)
    let candidate = try p.j.receive(sent)
    XCTAssertTrue(candidate.approvalCandidate != nil)
    XCTAssertEqual(p.j.phase, .comparing)
    let context = try XCTUnwrap(p.j.cryptoContext)
    let opened = try C.openApproval(wire, request: context.request, offer: context.offer, keys: context.keys)
    XCTAssertEqual(opened.entropy, Data(count: 32))
    let validated = try XCTUnwrap(candidate.approvalCandidate)
    _ = try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: validated)
    XCTAssertEqual(p.j.phase, .installCommitted)
    let receipt = try write(p.j.installed(), .receipt)
    XCTAssertTrue(try p.t.receive(receipt).events.contains(.receipt))
    XCTAssertEqual(p.t.phase, .ended)
    XCTAssertThrowsError(try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: validated))
  }

  func testOneLiveJoiningRequestNoAutomaticRetry() throws {
    let time = Time(), j = try session(.joining, time)
    let first = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertThrowsError(try j.startJoining(createdMs: wall))
    XCTAssertTrue(try j.tick().writes.isEmpty)
    _ = try j.end(reason: .cancel)
    XCTAssertNil(j.code)
    let replacement = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertNotEqual(first.rid, replacement.rid)
    let next = try session(.joining, time, seed: 2)
    let second = try write(next.startJoining(createdMs: wall), .request)
    XCTAssertNotEqual(first.rid, second.rid)
    XCTAssertNotEqual(first.wire, second.wire)
  }

  func testUnarmedAndSuppressedRequestsNeverWrite() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertTrue(try t.receive(request).writes.isEmpty)
    XCTAssertTrue(t.suppressed)
    _ = try t.arm()
    _ = try t.end(reason: .deny)
    let another = try session(.joining, time, seed: 40)
    let second = try write(another.startJoining(createdMs: wall), .request)
    let quiet = try t.receive(second)
    XCTAssertEqual(quiet.events.filter { $0 == .quietIndicator }.count, 1)
    XCTAssertTrue(quiet.writes.isEmpty)
    XCTAssertFalse(try t.receive(second).events.contains(.quietIndicator))
    XCTAssertNil(t.code)
    XCTAssertNil(t.peerName)
  }

  func testDismissalSurvivesFailedWriteAndImmediateRestartConservatively() throws {
    let time = Time(), t = try session(.trusted, time)
    _ = try t.arm()
    _ = try t.dismissUnsolicited()
    XCTAssertTrue(t.suppressed)
    let restarted = try session(.trusted, time)
    let j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertFalse(try restarted.receive(request).events.contains(.quietIndicator))
    _ = try restarted.remount()
    XCTAssertTrue(restarted.suppressed)
    _ = try restarted.arm()
    XCTAssertFalse(restarted.suppressed)
  }

  func testArmWithoutRequestDoesNotAutomaticallySelectArrival() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    _ = try t.arm()
    let request = try write(j.startJoining(createdMs: wall), .request)
    let out = try t.receive(request)
    XCTAssertTrue(out.writes.isEmpty)
    XCTAssertEqual(t.phase, .armed)
    XCTAssertEqual(t.descriptors.count, 1)
    XCTAssertNil(t.code)
  }

  func testOccupiedArmCannotRefreshOrReplaceOfferedOrRevealedTarget() throws {
    let p = try pair()
    let handle = p.t.handle, deadline = p.t.deadline
    XCTAssertEqual(p.t.phase, .revealed)
    p.time.now += 1000
    XCTAssertThrowsError(try p.t.arm())
    XCTAssertEqual(p.t.handle, handle)
    XCTAssertEqual(p.t.deadline, deadline)
    let j2 = try session(.joining, p.time, seed: 2000)
    _ = try p.t.receive(write(j2.startJoining(createdMs: wall), .request))
    let descriptor = try XCTUnwrap(p.t.descriptors.last)
    XCTAssertThrowsError(try p.t.pin(descriptor, handle: p.t.handle, armGeneration: p.t.armGeneration, createdMs: wall))
    XCTAssertEqual(p.t.phase, .revealed)
  }

  func testCapturedDescriptorCannotBeSubstitutedByInsertionOrForgedHash() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let first = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(first)
    let captured = try XCTUnwrap(t.descriptors.first)
    let other = try session(.joining, time, seed: 800)
    _ = try t.receive(write(other.startJoining(createdMs: wall), .request))
    _ = try t.arm()
    let offer = try write(t.pin(captured, handle: t.handle, armGeneration: t.armGeneration, createdMs: wall), .offer)
    XCTAssertEqual(offer.rid, first.rid)
    let time2 = Time(), t2 = try session(.trusted, time2)
    _ = try t2.receive(first)
    _ = try t2.arm()
    var forged = try XCTUnwrap(t2.descriptors.first)
    forged.hash[0] ^= 1
    XCTAssertThrowsError(try t2.pin(forged, handle: t2.handle, armGeneration: t2.armGeneration, createdMs: wall))
    XCTAssertEqual(t2.phase, .ended)
  }

  func testChangedFirstSeenRequestBurnsCapturedArm() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    let captured = try XCTUnwrap(t.descriptors.first)
    _ = try t.arm()
    _ = try t.receive(corrupt(request, offset: 165))
    XCTAssertThrowsError(try t.pin(captured, handle: t.handle, armGeneration: t.armGeneration, createdMs: wall))
    XCTAssertEqual(t.phase, .ended)
  }

  func testFirstSeenDeadlineNotRefreshedByIdenticalRequest() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    time.now = 250000
    _ = try t.receive(request)
    XCTAssertEqual(t.descriptors.first?.firstSeen, 1000)
    _ = try t.arm()
    _ = try t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: 1)
    XCTAssertEqual(t.deadline, 301000)
    time.now = 301000
    _ = try t.tick()
    XCTAssertEqual(t.phase, .ended)
  }

  func testExactArmDeadlineRejectsLatePinAndCallbacks() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    _ = try t.arm()
    time.now = 121000
    XCTAssertThrowsError(try t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall))
    XCTAssertEqual(t.phase, .ended)
    XCTAssertTrue(try t.receive(request).writes.isEmpty)
  }

  func testJoiningDeadlineCountsSleepAndIgnoresRemoteWallHints() throws {
    let p = try pair()
    p.time.now = 300999
    XCTAssertFalse(try p.j.tick().events.contains(.ended(.expiry)))
    p.time.now = 301000
    XCTAssertTrue(try p.j.tick().events.contains(.ended(.expiry)))
    XCTAssertNil(p.j.code)
    XCTAssertTrue(try p.j.receive(p.reveal).writes.isEmpty)
  }

  func testClockRollbackFailsClosed() throws {
    let p = try pair()
    p.time.now = 999
    _ = try p.t.tick()
    XCTAssertEqual(p.t.phase, .ended)
    XCTAssertNil(p.t.code)
  }

  func testRevealWaitsForExactPersistedReservationAndCountsOnce() throws {
    let time = Time(), j = try session(.joining, time), t = try session(.trusted, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    _ = try t.arm()
    let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall), .offer)
    _ = try j.receive(offer)
    let select = try write(j.selectOffer(offer, handle: j.handle), .select)
    let reserved = try t.receive(select)
    XCTAssertEqual(t.phase, .awaitingPersistence)
    XCTAssertTrue(reserved.writes.isEmpty)
    let state = try XCTUnwrap(reserved.accounting)
    XCTAssertEqual(state.reveals.count, 1)
    var wrong = state
    wrong.revision += 1
    XCTAssertThrowsError(try t.persistedAccounting(wrong))
    XCTAssertTrue(try t.receive(select).writes.isEmpty)
    XCTAssertEqual(t.accounting.reveals.count, 1)
    let emitted = try t.persistedAccounting(state)
    XCTAssertEqual(emitted.writes.filter { $0.kind == .reveal }.count, 1)
    XCTAssertThrowsError(try t.persistedAccounting(state))
    XCTAssertTrue(try t.receive(select).writes.isEmpty)
    XCTAssertEqual(t.accounting.reveals.count, 1)
  }

  func testRestartPreservesSerializableRevealCountAndDestroysHandshake() throws {
    let p = try pair()
    let encoded = try JSONEncoder().encode(p.t.accounting)
    let restored = try JSONDecoder().decode(S.Accounting.self, from: encoded)
    let t = try session(.trusted, p.time, seed: 9000, accounting: restored)
    XCTAssertEqual(t.accounting.reveals.count, 1)
    XCTAssertNil(t.cryptoContext)
    XCTAssertNil(t.code)
    XCTAssertTrue(try t.receive(p.selection).writes.isEmpty)
    XCTAssertEqual(t.phase, .idle)
  }

  func testRollingThreeRevealCapPersistsAcrossRestartAndOverrideRetainsCounts() throws {
    let p = try pair()
    var state = p.t.accounting
    state.reveals = [1000, 1000, 1000]
    let t = try session(.trusted, p.time, accounting: state)
    XCTAssertThrowsError(try t.arm())
    XCTAssertEqual(t.accounting.reveals.count, 3)
    _ = try t.arm(override: true)
    XCTAssertEqual(t.accounting.reveals.count, 3)
    _ = try t.receive(p.request)
    let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall), .offer)
    var m = try F.decode(p.selection.wire)
    m.aid = try XCTUnwrap(offer.aid)
    m.body = .select(requestHash: C.hash(p.request.wire), offerHash: C.hash(offer.wire), random: Data(p.selection.wire.suffix(32)))
    let output = try t.receive(entry(F.encode(m)))
    XCTAssertEqual(output.accounting?.reveals.count, 4)
    XCTAssertTrue(output.writes.isEmpty)
  }

  func testTwentyDailyRevealsAndExactRollingWindows() throws {
    let time = Time()
    time.now = 20000000
    var a = S.Accounting(clockEpoch: data(1))
    a.lastTime = time.now
    a.reveals = (0..<20).map { time.now - 1000000 - UInt64($0 * 700000) }
    let t = try session(.trusted, time, accounting: a)
    XCTAssertThrowsError(try t.arm())
    time.now += 86400000
    _ = try t.arm()
    XCTAssertEqual(t.phase, .armed)
  }

  func testUnreadableAccountingChangedEpochAndRollbackQuarantine() throws {
    for mode in 0..<3 {
      let time = Time()
      var a = S.Accounting(clockEpoch: data(1))
      if mode == 0 { a.readable = false }
      if mode == 1 { a.clockEpoch = data(7) }
      if mode == 2 { a.lastTime = time.now + 1 }
      let t = try session(.trusted, time, accounting: a)
      XCTAssertThrowsError(try t.arm())
      time.now += 86400000
      _ = try t.arm()
      XCTAssertEqual(t.phase, .armed)
    }
  }

  func testRevealSelectHashOnlyMutationRejectsBeforeConfirmWithValidControl() throws {
    let p = try pair()
    let bad = corrupt(p.reveal, offset: 60)
    XCTAssertEqual(bad.wire.suffix(64), p.reveal.wire.suffix(64))
    let keys = p.handshakeKeys
    XCTAssertNoThrow(try C.transcript(request: p.request.wire, offer: p.offer.wire, select: p.selection.wire, trustedRandom: Data(bad.wire[92..<124])))
    XCTAssertEqual(try C.confirmation(role: .trusted, keys: keys), Data(bad.wire.suffix(32)))
    try failed(p.j, bad)
    let control = try pair()
    XCTAssertEqual(try control.j.receive(control.reveal).writes.filter { $0.kind == .confirm }.count, 1)
  }

  func testInvalidJoiningCommitmentNeverReservesOrReveals() throws {
    let time = Time(), j = try session(.joining, time), t = try session(.trusted, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    _ = try t.arm()
    let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall), .offer)
    _ = try j.receive(offer)
    let select = try write(j.selectOffer(offer, handle: j.handle), .select)
    let result = try t.receive(corrupt(select, offset: 124))
    XCTAssertEqual(t.phase, .ended)
    XCTAssertNil(result.accounting)
    XCTAssertTrue(result.writes.isEmpty)
    XCTAssertEqual(t.accounting.reveals.count, 0)
  }

  func testInvalidTrustedCommitmentAndConfirmationCannotOpenJoiningName() throws {
    for offset in [92, 124] {
      let p = try pair()
      try failed(p.j, corrupt(p.reveal, offset: offset))
    }
  }

  func testEarlyJoiningNameRemainsOpaqueUntilConfirmation() throws {
    let p = try pair()
    _ = try ready(p, earlyName: true)
  }

  func testInvalidJoiningConfirmationNeverOpensBufferedName() throws {
    let p = try pair()
    let output = try p.j.receive(p.reveal)
    _ = try p.t.receive(write(output, .joiningName))
    try failed(p.t, corrupt(try write(output, .confirm), offset: 92))
  }

  func testNameTamperWrongCommitmentReflectionAndRoleKeysFailClosed() throws {
    for offset in [60, 92, 104, 375] {
      let p = try pair()
      let output = try p.j.receive(p.reveal)
      _ = try p.t.receive(write(output, .confirm))
      try failed(p.t, corrupt(try write(output, .joiningName), offset: offset))
    }
    let p = try pair()
    let output = try p.j.receive(p.reveal)
    _ = try p.t.receive(write(output, .confirm))
    let replacement = try C.sealName(role: .joining, name: "Different Mac", salt: data(3, 32), cid: cid(), rid: p.request.rid, aid: XCTUnwrap(p.offer.aid), keys: p.handshakeKeys, rng: Random(88).take)
    try failed(p.t, entry(replacement))
    let q = try pair()
    let opened = try q.j.receive(q.reveal)
    _ = try q.t.receive(write(opened, .confirm))
    var reflected = try write(opened, .joiningName)
    reflected.kind = .trustedName
    reflected.wire[5] = 11
    try failed(q.t, reflected)
  }

  func testDifferentValidSecondNameCiphertextFailsWithoutChangingCode() throws {
    let p = try pair()
    let (_, name, _) = try ready(p)
    let oldCode = p.j.code
    XCTAssertTrue(try p.t.receive(name).writes.isEmpty)
    let context = try XCTUnwrap(p.t.cryptoContext)
    let payload = try C.open(name.wire, type: 10, cid: cid(), rid: p.request.rid, aid: XCTUnwrap(p.offer.aid), keys: context.keys, label: "name AAD", key: "name-j")
    let replacement = try C.seal(payload, type: 10, cid: cid(), rid: p.request.rid, aid: XCTUnwrap(p.offer.aid), keys: context.keys, label: "name AAD", key: "name-j", rng: Random(999).take)
    XCTAssertNotEqual(name.wire, replacement)
    XCTAssertEqual(try C.sas(context.keys), oldCode)
    try failed(p.t, entry(replacement))
  }

  func testNameWithheldDoesNotPermitComparisonOrAuthorization() throws {
    let p = try pair()
    let output = try p.j.receive(p.reveal)
    _ = try p.t.receive(write(output, .confirm))
    XCTAssertNil(p.t.code)
    XCTAssertNil(p.j.code)
    XCTAssertThrowsError(try p.t.acknowledgeComparison(handle: p.t.handle, generation: p.t.comparisonGeneration))
    XCTAssertThrowsError(try p.t.authorization())
    p.time.now = 121000
    _ = try p.t.tick()
    XCTAssertEqual(p.t.phase, .ended)
  }

  func testSelectedActivePeerLearnsNamesBeforeComparisonWithoutGrant() throws {
    let p = try pair()
    let (_, jName, tName) = try ready(p)
    let context = try XCTUnwrap(p.j.cryptoContext)
    let (_, request, t, offer) = try C.context(request: context.request, offer: context.offer)
    XCTAssertEqual(try C.openName(jName.wire, role: .joining, cid: cid(), rid: p.request.rid, aid: t.aid, commitment: request.nameCommitment, keys: context.keys), "Andrew’s MacBook Pro")
    XCTAssertEqual(try C.openName(tName.wire, role: .trusted, cid: cid(), rid: p.request.rid, aid: t.aid, commitment: offer.nameCommitment, keys: context.keys), "Hill Studio")
    XCTAssertThrowsError(try p.t.authorization())
    let end = try p.t.end(reason: .deny)
    XCTAssertFalse(end.writes.contains { $0.kind == .approval })
  }

  func testNoNamesSaltsCodeOrStableDeviceInClearHandshakePackets() throws {
    let p = try pair()
    _ = try ready(p)
    for entry in [p.request, p.offer, p.selection, p.reveal] {
      XCTAssertNil(entry.wire.range(of: Data("Hill Studio".utf8)))
      XCTAssertNil(entry.wire.range(of: Data("Andrew’s MacBook Pro".utf8)))
      XCTAssertNil(entry.wire.range(of: Data(try XCTUnwrap(p.j.code).utf8)))
      XCTAssertNil(entry.wire.range(of: try XCTUnwrap(p.j.cryptoContext?.joiningDevice)))
    }
  }

  func testEveryPinnedWireRejectsSamePathReplacement() throws {
    for kind in [S.Kind.request, .offer, .select, .reveal, .confirm, .joiningName, .trustedName] {
      let p = try pair()
      let (confirm, jName, tName) = try ready(p)
      let value: S.Entry
      let target: S
      switch kind {
      case .request: value = p.request; target = p.t
      case .offer: value = p.offer; target = p.j
      case .select: value = p.selection; target = p.t
      case .reveal: value = p.reveal; target = p.j
      case .confirm: value = confirm; target = p.t
      case .joiningName: value = jName; target = p.t
      default: value = tName; target = p.j
      }
      XCTAssertTrue(try target.receive(value).writes.isEmpty)
      try failed(target, corrupt(value, offset: value.wire.count - 1))
    }
  }

  func testPerMessagePathIDsKindAndReferenceEqualities() throws {
    for field in 0..<5 {
      let p = try pair()
      var bad = p.reveal
      if field == 0 { bad.rid[0] ^= 1 }
      if field == 1 { bad.aid = data(77) }
      if field == 2 { bad.kind = .confirm }
      if field == 3 { bad.wire[12] ^= 1 }
      if field == 4 { bad.wire[28] ^= 1 }
      try failed(p.j, bad)
    }
    for offset in [60, 92] {
      let p = try pair()
      let time = Time(), t = try session(.trusted, time, seed: 110)
      _ = try t.receive(p.request)
      _ = try t.arm()
      let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall + 1000), .offer)
      XCTAssertEqual(offer.wire, p.offer.wire)
      try failed(t, corrupt(p.selection, offset: offset))
    }
  }

  func testOfferRequestHashAndPathMismatchRejectBeforeSelection() throws {
    for field in 0..<4 {
      let p = try pair()
      let time = Time(), j = try session(.joining, time, seed: 10)
      _ = try j.startJoining(createdMs: wall)
      var offer = p.offer
      if field == 0 { offer.wire[60] ^= 1 }
      if field == 1 { offer.rid[0] ^= 1 }
      if field == 2 { offer.aid = nil }
      if field == 3 { offer.wire[44] ^= 1 }
      try failed(j, offer)
    }
  }

  func testCompetingOfferCannotSwitchSelectedTranscript() throws {
    let p = try pair()
    let t2 = try session(.trusted, p.time, seed: 321)
    _ = try t2.receive(p.request)
    _ = try t2.arm()
    let offer = try write(t2.pin(XCTUnwrap(t2.descriptors.first), handle: t2.handle, armGeneration: t2.armGeneration, createdMs: wall), .offer)
    let before = p.j.handle
    _ = try p.j.receive(offer)
    XCTAssertThrowsError(try p.j.selectOffer(offer, handle: p.j.handle))
    XCTAssertEqual(p.j.handle, before)
    XCTAssertEqual(p.j.phase, .selected)
    _ = try p.j.receive(p.reveal)
    XCTAssertNil(p.j.cryptoContext)
  }

  func testUnselectedTrustedResponderRetiresOnOtherSelect() throws {
    let p = try pair(), t = try session(.trusted, p.time, seed: 400)
    _ = try t.receive(p.request)
    _ = try t.arm()
    _ = try t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall)
    let result = try t.receive(p.selection)
    XCTAssertEqual(t.phase, .ended)
    XCTAssertTrue(result.writes.isEmpty)
    XCTAssertEqual(t.accounting.reveals.count, 0)
  }

  func testEarlyDuplicateCannotOverwriteBufferedName() throws {
    let p = try pair()
    let out = try p.j.receive(p.reveal), name = try write(out, .joiningName)
    XCTAssertTrue(try p.t.receive(name).writes.isEmpty)
    XCTAssertTrue(try p.t.receive(name).writes.isEmpty)
    try failed(p.t, corrupt(name, offset: 104))
  }

  func testEarlyForgedTerminalAndBadMACCannotEndLiveExchange() throws {
    let p = try pair()
    let terminal = try entry(C.terminal(role: .joining, reason: 1, cid: cid(), rid: p.request.rid, aid: XCTUnwrap(p.offer.aid), keys: p.handshakeKeys))
    XCTAssertTrue(try p.t.receive(corrupt(terminal, offset: 124)).writes.isEmpty)
    XCTAssertEqual(p.t.phase, .revealed)
    let time = Time(), t = try session(.trusted, time)
    XCTAssertTrue(try t.receive(terminal).writes.isEmpty)
    XCTAssertEqual(t.phase, .idle)
    _ = try p.t.receive(terminal)
    XCTAssertEqual(p.t.phase, .ended)
  }

  func testAuthenticatedDenialEndsJoiningBeforeInstall() throws {
    let p = try pair()
    _ = try ready(p)
    let terminal = try write(p.t.end(reason: .deny), .trustedTerminal)
    _ = try p.j.receive(terminal)
    XCTAssertEqual(p.j.phase, .ended)
    XCTAssertNil(p.j.code)
    XCTAssertThrowsError(try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreignCandidate()))
  }

  func testHideAndRemountInvalidateComparisonAndNeverAutoPresent() throws {
    let p = try pair()
    _ = try ready(p)
    let old = try acknowledge(p), generation = p.t.comparisonGeneration
    _ = try p.t.hide()
    XCTAssertGreaterThan(p.t.comparisonGeneration, generation)
    XCTAssertThrowsError(try p.t.validateAuthorization(old))
    XCTAssertThrowsError(try p.t.authorization())
    _ = try p.t.remount()
    XCTAssertThrowsError(try p.t.acknowledgeComparison(handle: p.t.handle, generation: p.t.comparisonGeneration))
    _ = try p.t.present(handle: p.t.handle, armGeneration: p.t.armGeneration)
    XCTAssertThrowsError(try p.t.authorization())
    _ = try p.t.acknowledgeComparison(handle: p.t.handle, generation: p.t.comparisonGeneration)
    XCTAssertNotEqual(try p.t.authorization(), old)
  }

  func testHiddenLateHandshakeHasNoComparisonReadyEventUntilExplicitPresent() throws {
    let p = try pair()
    _ = try p.t.hide()
    let output = try p.j.receive(p.reveal)
    XCTAssertFalse(try p.t.receive(write(output, .confirm)).events.contains(.comparisonReady))
    XCTAssertFalse(try p.t.receive(write(output, .joiningName)).events.contains(.comparisonReady))
    _ = try p.t.remount()
    XCTAssertThrowsError(try p.t.authorization())
    let shown = try p.t.present(handle: p.t.handle, armGeneration: p.t.armGeneration)
    XCTAssertTrue(shown.events.contains(.comparisonReady))
    XCTAssertThrowsError(try p.t.authorization())
  }

  func testClosedSurfaceConsumesArmAndDelayedProgressCannotRevive() throws {
    let p = try pair()
    _ = try p.t.end(reason: .cancel)
    let output = try p.j.receive(p.reveal)
    XCTAssertTrue(try p.t.receive(write(output, .confirm)).writes.isEmpty)
    XCTAssertTrue(try p.t.receive(write(output, .joiningName)).writes.isEmpty)
    XCTAssertThrowsError(try p.t.present(handle: p.t.handle, armGeneration: p.t.armGeneration))
    XCTAssertThrowsError(try p.t.authorization())
  }

  func testEveryAuthorizationTupleFieldIsChecked() throws {
    let p = try pair()
    _ = try ready(p)
    let tuple = try acknowledge(p)
    XCTAssertNoThrow(try p.t.validateAuthorization(tuple))
    for field in 0..<16 {
      var bad = tuple
      switch field {
      case 0: bad.handle[0] ^= 1
      case 1: bad.transcript[0] ^= 1
      case 2: bad.cid[0] ^= 1
      case 3: bad.rid[0] ^= 1
      case 4: bad.aid[0] ^= 1
      case 5: bad.folderIdentity[0] ^= 1
      case 6: bad.folderGeneration += 1
      case 7: bad.entropyHandle[0] ^= 1
      case 8: bad.entropyGeneration += 1
      case 9: bad.sessionGeneration += 1
      case 10: bad.comparisonGeneration += 1
      case 11: bad.armGeneration += 1
      case 12: bad.armDeadline += 1
      case 13: bad.requestDeadline += 1
      case 14: bad.nameCommitment[0] ^= 1
      default: bad.rid = data(0)
      }
      XCTAssertThrowsError(try p.t.validateAuthorization(bad), "Unchecked tuple field \(field)")
    }
  }

  func testStaleHandleAndComparisonGenerationCannotAcknowledge() throws {
    let p = try pair()
    _ = try ready(p)
    XCTAssertThrowsError(try p.t.acknowledgeComparison(handle: data(0), generation: p.t.comparisonGeneration))
    XCTAssertThrowsError(try p.t.acknowledgeComparison(handle: p.t.handle, generation: p.t.comparisonGeneration + 1))
    XCTAssertThrowsError(try p.t.authorization())
  }

  func testExpiryOrEnvironmentChangeRejectsDelayedAuthorization() throws {
    for field in 0..<7 {
      let p = try pair()
      _ = try ready(p)
      let tuple = try acknowledge(p), wire = try grant(p)
      if field == 0 { p.time.now = 121000 }
      else {
        var env = p.t.environment
        if field == 1 { env.folderIdentity[0] ^= 1 }
        if field == 2 { env.folderGeneration += 1 }
        if field == 3 { env.entropyHandle = data(77) }
        if field == 4 { env.entropyGeneration += 1 }
        if field == 5 { env.sessionGeneration += 1 }
        if field == 6 { env.eligible = false }
        _ = try p.t.invalidate(env)
      }
      XCTAssertThrowsError(try p.t.validateAuthorization(tuple))
      XCTAssertThrowsError(try p.t.commitApproval(wire: wire, ownerAuthentication: SyntheticPairingOwnerAuthenticator.authenticated( tuple)))
      XCTAssertEqual(p.t.phase, .ended)
    }
  }

  func testApprovalRetryIsExactAndOneAuthorizationCannotReleaseTwice() throws {
    let p = try pair()
    _ = try ready(p)
    let auth = SyntheticPairingOwnerAuthenticator.authenticated( try acknowledge(p)), wire = try grant(p)
    _ = try p.t.commitApproval(wire: wire, ownerAuthentication: auth)
    XCTAssertEqual(try write(p.t.retryApproval(), .approval).wire, wire)
    XCTAssertThrowsError(try p.t.commitApproval(wire: wire, ownerAuthentication: auth))
    XCTAssertThrowsError(try p.t.arm())
    p.time.now = 121000
    XCTAssertThrowsError(try p.t.retryApproval())
  }

  func testReceiptMustMatchReleasedApprovalAndBadReceiptIsIgnored() throws {
    let p = try pair()
    _ = try ready(p)
    let auth = SyntheticPairingOwnerAuthenticator.authenticated( try acknowledge(p)), wire = try grant(p)
    _ = try p.t.commitApproval(wire: wire, ownerAuthentication: auth)
    let context = try XCTUnwrap(p.t.cryptoContext)
    let receipt = try entry(C.receipt(approval: wire, keys: context.keys))
    _ = try p.t.receive(corrupt(receipt, offset: 92))
    XCTAssertEqual(p.t.phase, .released)
    _ = try p.t.receive(receipt)
    XCTAssertEqual(p.t.phase, .ended)
    XCTAssertTrue(try p.t.receive(receipt).writes.isEmpty)
  }

  func testTerminalAfterReleaseCannotRetractGrant() throws {
    let p = try pair()
    _ = try ready(p)
    let auth = SyntheticPairingOwnerAuthenticator.authenticated( try acknowledge(p)), wire = try grant(p)
    _ = try p.t.commitApproval(wire: wire, ownerAuthentication: auth)
    let cancel = try write(p.j.end(reason: .cancel), .joiningTerminal)
    _ = try p.t.receive(cancel)
    XCTAssertEqual(p.t.phase, .released)
    XCTAssertEqual(try write(p.t.retryApproval(), .approval).wire, wire)
  }

  func testCommittedInstallFinishesAfterExpiryAndTerminalCannotRollItBack() throws {
    let p = try pair()
    _ = try ready(p)
    let wire = try grant(p)
    let candidate = try XCTUnwrap(p.j.receive(entry(wire)).approvalCandidate)
    _ = try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: candidate)
    let terminal = try write(p.t.end(reason: .deny), .trustedTerminal)
    p.time.now = 900000
    _ = try p.j.receive(terminal)
    _ = try p.j.tick()
    XCTAssertEqual(p.j.phase, .installCommitted)
    XCTAssertEqual(try write(p.j.installed(), .receipt).kind, .receipt)
    XCTAssertEqual(p.j.phase, .installed)
  }

  func testOpaqueApprovalRequiresPinnedNameAndExactCandidateAtInstallAdmission() throws {
    let p = try pair()
    let wire = try grant(p)
    let foreign = try foreignCandidate()
    XCTAssertEqual(foreign.wire, wire)
    XCTAssertTrue(try p.j.receive(entry(wire)).writes.isEmpty)
    XCTAssertThrowsError(try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreign))
    let (_, _, name) = try ready(p)
    let q = try pair()
    _ = try q.j.receive(entry(wire))
    let opened = try q.j.receive(q.reveal)
    _ = try q.t.receive(write(opened, .confirm))
    _ = try q.t.receive(write(opened, .joiningName))
    let candidate = try XCTUnwrap(q.j.receive(name).approvalCandidate)
    XCTAssertThrowsError(try q.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreign))
    XCTAssertEqual(q.j.phase, .comparing)
    XCTAssertFalse(try q.j.receive(entry(wire)).approvalCandidate != nil)
    _ = try q.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: candidate)
    XCTAssertThrowsError(try q.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: candidate))
  }

  func testRestartCannotReplayNamesOrOldGrantIntoNewJoiningSession() throws {
    let p = try pair()
    let (_, _, name) = try ready(p)
    let wire = try grant(p), j = try session(.joining, p.time, seed: 990)
    _ = try j.startJoining(createdMs: wall)
    XCTAssertFalse(try j.receive(name).events.contains(.comparisonReady))
    XCTAssertFalse(try j.receive(entry(wire)).approvalCandidate != nil)
    XCTAssertThrowsError(try j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreignCandidate()))
  }

  func testPendingDescriptorsAndOffersAreBounded() throws {
    let time = Time(), t = try session(.trusted, time)
    for i in 0..<12 {
      let j = try session(.joining, time, seed: UInt64(i + 100))
      let result = try t.receive(write(j.startJoining(createdMs: wall), .request))
      XCTAssertTrue(result.writes.isEmpty)
    }
    XCTAssertLessThanOrEqual(t.descriptors.count, 8)
    let j = try session(.joining, time, seed: 8888)
    let request = try write(j.startJoining(createdMs: wall), .request)
    for i in 0..<12 {
      let responder = try session(.trusted, time, seed: UInt64(i + 80000))
      _ = try responder.receive(request)
      _ = try responder.arm()
      let offer = try write(responder.pin(XCTUnwrap(responder.descriptors.first), handle: responder.handle, armGeneration: responder.armGeneration, createdMs: wall), .offer)
      _ = try j.receive(offer)
    }
    XCTAssertLessThanOrEqual(j.offers.count, 8)
  }

  func testMissingRootOrIneligibleTrustedCannotArm() throws {
    let time = Time()
    var env = environment(.trusted)
    env.entropyHandle = nil
    let t = try session(.trusted, time, env: env)
    XCTAssertThrowsError(try t.arm())
    env.entropyHandle = data(8)
    env.eligible = false
    let locked = try session(.trusted, time, env: env)
    XCTAssertThrowsError(try locked.arm())
  }

  func testGeneratorUsesDistinctRandomDrawsAndRNGFailureDoesNotEmit() throws {
    let time = Time(), random = Random(55), j = try session(.joining, time, rng: random)
    let request = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertEqual(random.sizes, [16, 16, 16, 16, 32, 32, 32])
    let failing = try S(role: .joining, cid: cid(), environment: environment(.joining), localName: "Mac", clock: time.read, random: { _ in throw F.Failure.random }, restoration: .newInstallation)
    XCTAssertThrowsError(try failing.startJoining(createdMs: wall))
    XCTAssertNil(failing.code)
    XCTAssertNotEqual(request.wire.suffix(32), Data(request.wire[133..<165]))
  }

  func testCanonicalLocalNameAndNameSnapshotNeverUpdateInPlace() throws {
    let time = Time()
    XCTAssertThrowsError(try session(.joining, time, name: " Bad"))
    XCTAssertThrowsError(try session(.trusted, time, name: "\u{202e}Mac"))
    let j = try session(.joining, time, name: "Cafe\u{301}")
    let request = try write(j.startJoining(createdMs: wall), .request)
    guard case .request(let body) = try F.decode(request.wire).body else { return XCTFail("Expected request") }
    XCTAssertEqual(body.name, "New Mac")
    XCTAssertEqual(body.nameCommitment.count, 32)
  }

  func testEightBitComparisonInjectionKeepsProductionThirtyBitDefault() throws {
    let p = try pair(bits: 8)
    _ = try ready(p)
    XCTAssertEqual(p.j.code?.count, 2)
    let control = try pair()
    _ = try ready(control)
    XCTAssertEqual(control.j.code?.count, 6)
    XCTAssertThrowsError(try session(.joining, Time(), bits: 31))
  }

  struct Interval {
    var id: Int
    var device: Int
    var start: Int
    var end: Int
    var code: Int
  }
  func candidates(_ joining: [Interval], _ trusted: [Interval]) -> [(Int, Int)] {
    joining.flatMap { j in trusted.filter { max(j.start, $0.start) < min(j.end, $0.end) }.map { (j.code, $0.code) } }
  }
  func offsetsWithCollision(_ pairs: [(Int, Int)]) -> Int {
    (0..<256).filter { offset in pairs.contains { $0.0 == (($0.1 + offset) & 255) } }.count
  }

  func testEightBitOriginalNinePairSixRevealScheduleAndUnionBound() throws {
    let j = (0..<3).map { Interval(id: $0, device: 0, start: 20 + $0 * 10, end: 30 + $0 * 10, code: $0 * 3) }
    let pooled = (0..<3).map { Interval(id: $0, device: 0, start: $0, end: 100, code: $0) }
    let pairs = candidates(j, pooled)
    XCTAssertEqual(j.count + pooled.count, 6)
    XCTAssertEqual(pairs.count, 9)
    XCTAssertEqual(offsetsWithCollision(pairs), 9)
    XCTAssertEqual(Double(offsetsWithCollision(pairs)) / 256, 9.0 / 256)
    XCTAssertGreaterThan(offsetsWithCollision(pairs), 6)
    let p = try pair(bits: 8)
    XCTAssertThrowsError(try p.t.arm())
    XCTAssertEqual(p.t.phase, .revealed)
    XCTAssertEqual(p.t.accounting.reveals.count, 1)
  }

  func testEightBitReversedDisjointOverlappingAndAdaptiveStoppingSchedules() throws {
    let trusted = [Interval(id: 0, device: 0, start: 0, end: 100, code: 17)]
    let joining = (0..<3).map { Interval(id: $0, device: 0, start: $0 * 10 + 20, end: $0 * 10 + 30, code: 40 + $0) }
    let forward = candidates(joining, trusted), reverse = candidates(trusted, joining)
    XCTAssertEqual(forward.count, 3)
    XCTAssertEqual(reverse.count, 3)
    XCTAssertLessThanOrEqual(offsetsWithCollision(forward), 3)
    let disjoint = [Interval(id: 1, device: 0, start: 100, end: 200, code: 0)]
    XCTAssertTrue(candidates(trusted, disjoint).isEmpty)
    let many = (0..<3).map { Interval(id: $0, device: $0, start: 0, end: 100, code: $0) }
    let pairs = candidates(joining, many)
    XCTAssertEqual(pairs.count, 9)
    XCTAssertLessThanOrEqual(pairs.count, many.count * joining.count + many.count)
    XCTAssertLessThanOrEqual(Double(offsetsWithCollision(pairs)) / 256, 9.0 / 256)
    for offset in 0..<256 {
      let tested = pairs.prefix { $0.0 != (($0.1 + offset) & 255) }.count
      XCTAssertLessThanOrEqual(tested, 9)
    }
  }

  func testLiteralP1SessionWiresAndCode() throws {
    let time = Time(), jRandom = Random(1), tRandom = Random(2)
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/pairing-p1.json")
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
    func bytes(_ hex: String) throws -> Data {
      var result = Data(), index = hex.startIndex
      while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        result.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16)))
        index = end
      }
      return result
    }
    func expected(_ key: String) throws -> Data { try bytes(XCTUnwrap(fixture[key])) }
    func sequence(_ start: UInt8, _ count: Int) -> Data { Data((0..<count).map { start + UInt8($0) }) }
    jRandom.scripted = [data(9), data(5), data(3), data(1), try bytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"), sequence(0, 32), sequence(0x80, 32), sequence(0x50, 12)]
    tRandom.scripted = [data(9), data(2), data(4), try bytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"), sequence(0x20, 32), sequence(0xa0, 32), sequence(0x60, 12)]
    let j = try session(.joining, time, rng: jRandom), t = try session(.trusted, time, rng: tRandom)
    let request = try write(j.startJoining(createdMs: wall), .request)
    XCTAssertEqual(request.wire, try expected("request"))
    _ = try t.receive(request)
    _ = try t.arm()
    let offer = try write(t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall + 1000), .offer)
    XCTAssertEqual(offer.wire, try expected("offer"))
    _ = try j.receive(offer)
    let select = try write(j.selectOffer(offer, handle: j.handle), .select)
    XCTAssertEqual(select.wire, try expected("select"))
    let accounting = try XCTUnwrap(t.receive(select).accounting)
    let reveal = try write(t.persistedAccounting(accounting), .reveal)
    XCTAssertEqual(reveal.wire, try expected("reveal"))
    let opened = try j.receive(reveal)
    let confirm = try write(opened, .confirm), jName = try write(opened, .joiningName)
    XCTAssertEqual(confirm.wire, try expected("confirm"))
    XCTAssertEqual(jName.wire, try expected("j-name"))
    _ = try t.receive(jName)
    let tName = try write(t.receive(confirm), .trustedName)
    XCTAssertEqual(tName.wire, try expected("t-name"))
    _ = try j.receive(tName)
    XCTAssertEqual(j.code, "EJFQF1")
    XCTAssertEqual(t.code, "EJFQF1")
    XCTAssertTrue(jRandom.scripted.isEmpty)
    XCTAssertTrue(tRandom.scripted.isEmpty)
  }

  func testEarlyRevealConfirmAndNamesDrainOnlyAfterTheirGates() throws {
    let p = try pair()
    let time = Time(), j = try session(.joining, time, seed: 10)
    _ = try j.startJoining(createdMs: wall)
    _ = try j.receive(p.offer)
    XCTAssertTrue(try j.receive(p.reveal).writes.isEmpty)
    XCTAssertNil(j.code)
    let selection = try j.selectOffer(p.offer, handle: j.handle)
    XCTAssertEqual(try write(selection, .select), p.selection)
    XCTAssertEqual(selection.writes.filter { $0.kind == .confirm }.count, 1)
    XCTAssertNil(j.code)
  }

  func testEightBitRealUnconfirmedTargetsRetainMultipleDeviceFactor() throws {
    let targets = try (0..<3).map { try pair(seed: UInt64(100 + $0 * 1000), bits: 8) }
    var trusted: [Interval] = []
    for (index, target) in targets.enumerated() {
      XCTAssertEqual(target.t.phase, .revealed)
      XCTAssertThrowsError(try target.t.arm())
      let keys = target.handshakeKeys
      let sas = try C.mac(keys.key("sas"), F.frame("compare", keys.transcript))
      trusted.append(Interval(id: index, device: index, start: index, end: 100, code: Int(sas[0])))
      XCTAssertEqual(target.t.accounting.reveals.count, 1)
    }
    var joining: [Interval] = []
    for index in 0..<3 {
      let trial = try pair(seed: UInt64(5000 + index * 1000), bits: 8)
      _ = try ready(trial)
      let code = try XCTUnwrap(Int(XCTUnwrap(trial.j.code), radix: 16))
      joining.append(Interval(id: index, device: 0, start: 20 + index * 10, end: 30 + index * 10, code: code))
      _ = try trial.j.end(reason: .cancel)
      XCTAssertNil(trial.j.code)
      XCTAssertThrowsError(try trial.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreignCandidate()))
    }
    let comparisons = candidates(joining, trusted)
    XCTAssertEqual(comparisons.count, 9)
    XCTAssertLessThanOrEqual(offsetsWithCollision(comparisons), 9)
    XCTAssertLessThanOrEqual(comparisons.count, 3 * joining.count + trusted.count)
    let twoJoining = joining + joining.map { Interval(id: $0.id + 3, device: 1, start: $0.start, end: $0.end, code: ($0.code + 77) & 255) }
    let multiple = candidates(twoJoining, trusted)
    XCTAssertEqual(multiple.count, 18)
    XCTAssertLessThanOrEqual(multiple.count, 3 * twoJoining.count + 2 * trusted.count)
  }

  func testExpiredPersistenceAcknowledgmentNeverEmitsReveal() throws {
    let p = try pair()
    let time = Time(), t = try session(.trusted, time, seed: 110)
    _ = try t.receive(p.request)
    _ = try t.arm()
    _ = try t.pin(XCTUnwrap(t.descriptors.first), handle: t.handle, armGeneration: t.armGeneration, createdMs: wall + 1000)
    let state = try XCTUnwrap(t.receive(p.selection).accounting)
    time.now = 121000
    XCTAssertThrowsError(try t.persistedAccounting(state))
    XCTAssertEqual(t.phase, .ended)
    XCTAssertEqual(t.accounting.reveals.count, 1)
  }

  func testExactTenMinuteRevealCapBoundaryAndOverrideAfterRestart() throws {
    let time = Time()
    var a = S.Accounting(clockEpoch: data(1))
    a.reveals = [1000, 1000, 1000]
    a.lastTime = 1000
    let t = try session(.trusted, time, accounting: a)
    time.now = 600999
    XCTAssertThrowsError(try t.arm())
    time.now = 601000
    _ = try t.arm()
    XCTAssertEqual(t.phase, .armed)
    XCTAssertEqual(t.accounting.reveals.count, 3)
  }

  func testConfirmationTranscriptMismatchFailsBeforeNameResponse() throws {
    let p = try pair()
    let output = try p.j.receive(p.reveal)
    let name = try write(output, .joiningName)
    _ = try p.t.receive(name)
    try failed(p.t, corrupt(try write(output, .confirm), offset: 60))
  }

  func testDuplicateApprovalCandidateIsIdempotentAndReplacementFails() throws {
    let p = try pair()
    _ = try ready(p)
    let wire = try grant(p), value = try entry(wire)
    XCTAssertTrue(try p.j.receive(value).approvalCandidate != nil)
    XCTAssertFalse(try p.j.receive(value).approvalCandidate != nil)
    try failed(p.j, corrupt(value, offset: 104))
  }

  func testSecondRequestAfterEndNeverInheritsArmOrComparison() throws {
    for reason in [S.EndReason.deny, .protocolFailure, .expiry, .cancel] {
      let p = try pair()
      _ = try ready(p)
      _ = try acknowledge(p)
      _ = try p.t.end(reason: reason)
      let j = try session(.joining, p.time, seed: 999)
      let output = try p.t.receive(write(j.startJoining(createdMs: wall), .request))
      XCTAssertTrue(output.writes.isEmpty)
      XCTAssertNil(p.t.code)
      XCTAssertThrowsError(try p.t.authorization())
      let descriptor = try XCTUnwrap(p.t.descriptors.last)
      XCTAssertThrowsError(try p.t.pin(descriptor, handle: p.t.handle, armGeneration: p.t.armGeneration, createdMs: wall))
    }
  }

  func testMalformedAccountingCountIsBoundedAndCannotAuthorize() throws {
    let time = Time()
    var accounting = S.Accounting(clockEpoch: data(1))
    accounting.uncertainReveals = Int.max - 1
    accounting.reveals = [1000]
    accounting.lastTime = 1000
    accounting.clockEpoch = data(77)
    let t = try session(.trusted, time, accounting: accounting)
    XCTAssertLessThanOrEqual(t.accounting.uncertainReveals, 512)
    XCTAssertThrowsError(try t.arm())
  }

  func testRollbackAfterProgressQuarantinesFutureArms() throws {
    let p = try pair()
    p.time.now = 2000
    _ = try p.t.tick()
    p.time.now = 1500
    _ = try p.t.tick()
    XCTAssertEqual(p.t.phase, .ended)
    XCTAssertThrowsError(try p.t.arm())
    _ = try p.t.arm(override: true)
    XCTAssertGreaterThan(p.t.accounting.uncertainReveals, 0)
  }

  func testUnarmedFloodEmitsOnlyOneCoalescedQuietIndicator() throws {
    let time = Time(), t = try session(.trusted, time)
    _ = try t.arm()
    _ = try t.end(reason: .deny)
    var events: [S.Event] = []
    for seed in 100..<112 {
      let j = try session(.joining, time, seed: UInt64(seed))
      let output = try t.receive(write(j.startJoining(createdMs: wall), .request))
      events += output.events
      XCTAssertTrue(output.writes.isEmpty)
    }
    XCTAssertEqual(events, [.quietIndicator])
    XCTAssertLessThanOrEqual(t.descriptors.count, 8)
  }

  func testRemoteSelectionCannotEnterUnselectedJoiningState() throws {
    let p = try pair()
    let time = Time(), j = try session(.joining, time, seed: 10)
    _ = try j.startJoining(createdMs: wall)
    try failed(j, p.selection)
  }

  func testDelayedPinFromConsumedArmCannotBindNextArm() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let request = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(request)
    _ = try t.arm()
    let descriptor = try XCTUnwrap(t.descriptors.first)
    let capturedHandle = t.handle, capturedGeneration = t.armGeneration
    let delayed = { try t.pin(descriptor, handle: capturedHandle, armGeneration: capturedGeneration, createdMs: self.wall) }
    _ = try t.end(reason: .deny)
    _ = try t.arm()
    XCTAssertThrowsError(try delayed())
    XCTAssertEqual(t.phase, .armed)
  }

  func testDelayedOfferSelectionCannotBindReplacementJoiningHandle() throws {
    let p = try pair()
    let time = Time(), j = try session(.joining, time, seed: 10)
    _ = try j.startJoining(createdMs: wall)
    _ = try j.receive(p.offer)
    let capturedHandle = j.handle, capturedOffer = p.offer
    let delayed = { try j.selectOffer(capturedOffer, handle: capturedHandle) }
    _ = try j.end(reason: .cancel)
    let request = try write(j.startJoining(createdMs: wall), .request)
    var offer = try F.decode(p.offer.wire)
    offer.rid = request.rid
    guard case .offer(var body) = offer.body else { return XCTFail("Expected offer") }
    body.requestHash = C.hash(request.wire)
    offer.body = .offer(body)
    _ = try j.receive(entry(F.encode(offer)))
    XCTAssertThrowsError(try delayed())
    XCTAssertEqual(j.phase, .requestLive)
  }

  func testExpiredDescriptorCannotBeEvictedAndReplayedWithFreshFirstSeen() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let old = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(old)
    time.now = 301000
    let other = try session(.joining, time, seed: 999)
    _ = try t.receive(write(other.startJoining(createdMs: wall), .request))
    _ = try t.receive(old)
    _ = try t.arm()
    if let replayed = t.descriptors.first(where: { $0.rid == old.rid }) {
      XCTAssertEqual(replayed.firstSeen, 1000)
      XCTAssertThrowsError(try t.pin(replayed, handle: t.handle, armGeneration: t.armGeneration, createdMs: wall))
    } else {
      XCTAssertFalse(t.descriptors.contains { $0.rid == old.rid })
    }
  }

  func testEligibilityInvalidationCannotRefreshFirstSeenAfterLock() throws {
    let time = Time(), t = try session(.trusted, time), j = try session(.joining, time)
    let old = try write(j.startJoining(createdMs: wall), .request)
    _ = try t.receive(old)
    time.now = 301000
    var env = t.environment
    env.eligible = false
    _ = try t.invalidate(env)
    env.eligible = true
    _ = try t.invalidate(env)
    _ = try t.receive(old)
    _ = try t.arm()
    if let replayed = t.descriptors.first(where: { $0.rid == old.rid }) {
      XCTAssertEqual(replayed.firstSeen, 1000)
      XCTAssertThrowsError(try t.pin(replayed, handle: t.handle, armGeneration: t.armGeneration, createdMs: wall))
    }
    XCTAssertTrue(t.descriptors.allSatisfy { $0.rid != old.rid || $0.firstSeen == 1000 })
  }

}

extension PairingSessionTests {
  func testReviewCorruptApprovalNeverReportsCandidateOrCommitsInstall() throws {
    let p = try pair()
    _ = try ready(p)
    var bad = try grant(p)
    bad[bad.count - 1] ^= 1
    let result = try p.j.receive(entry(bad))
    XCTAssertFalse(result.approvalCandidate != nil)
    XCTAssertEqual(p.j.phase, .ended)
    XCTAssertThrowsError(try p.j.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: foreignCandidate()))
  }

  func testReviewApprovalReleaseRequiresOwnerAuthenticationCapability() throws {
    let p = try pair()
    _ = try ready(p)
    let tuple = try acknowledge(p)
    var different = tuple
    different.handle[0] ^= 1
    let authentication = SyntheticPairingOwnerAuthenticator.authenticated( different)
    XCTAssertThrowsError(try p.t.commitApproval(wire: grant(p), ownerAuthentication: authentication))
    XCTAssertEqual(p.t.phase, .comparing)
    let exact = SyntheticPairingOwnerAuthenticator.authenticated( tuple)
    XCTAssertEqual(try write(p.t.commitApproval(wire: grant(p), ownerAuthentication: exact), .approval).kind, .approval)
  }

  func testReviewEarlyApprovalEventCarriesPinnedCandidate() throws {
    let p = try pair()
    let wire = try grant(p)
    XCTAssertTrue(try p.j.receive(entry(wire)).events.isEmpty)
    let opened = try p.j.receive(p.reveal)
    _ = try p.t.receive(write(opened, .confirm))
    let name = try write(p.t.receive(write(opened, .joiningName)), .trustedName)
    let result = try p.j.receive(name)
    let candidate = try XCTUnwrap(result.approvalCandidate)
    XCTAssertEqual(candidate.wire, wire)
    XCTAssertEqual(candidate.payload.entropy, Data(count: 32))
    XCTAssertEqual(result.events.filter { if case .approvalReceived = $0 { return true }; return false }.count, 1)
    XCTAssertTrue(result.writes.isEmpty)
  }

  func testReviewHandshakeKeysUnavailableBeforeComparisonReadiness() throws {
    let p = try pair()
    XCTAssertNil(p.t.cryptoContext)
    XCTAssertNil(p.j.cryptoContext)
    let opened = try p.j.receive(p.reveal)
    XCTAssertNil(p.j.cryptoContext)
    _ = try p.t.receive(write(opened, .confirm))
    XCTAssertNil(p.t.cryptoContext)
  }

  func testReviewUnreadableRestorationCannotBecomeFreshAccounting() throws {
    let time = Time()
    let t = try S(role: .trusted, cid: cid(), environment: environment(.trusted), localName: "Mac", clock: time.read, random: Random(1).take, restoration: .unreadable)
    XCTAssertThrowsError(try t.arm())
    XCTAssertGreaterThan(t.accounting.uncertainReveals, 0)
  }

  func testReviewWrongApprovalTranscriptRejectedAtRelease() throws {
    let p = try pair()
    _ = try ready(p)
    var wire = try grant(p)
    wire[60] ^= 1
    XCTAssertThrowsError(try p.t.commitApproval(wire: wire, ownerAuthentication: SyntheticPairingOwnerAuthenticator.authenticated( acknowledge(p))))
    XCTAssertEqual(p.t.phase, .comparing)
  }

  func testReviewWrongApprovalTranscriptRejectedAtCandidateReception() throws {
    let p = try pair()
    _ = try ready(p)
    var wire = try grant(p)
    wire[60] ^= 1
    try failed(p.j, entry(wire))
  }
}


extension PairingSessionTests {
  func accountingSelection(_ trusted: S, _ time: Time, seed: UInt64, override: Bool = false, armTime: UInt64? = nil, selectTime: UInt64? = nil) throws -> S.Entry {
    let joining = try session(.joining, time, seed: seed)
    let request = try write(joining.startJoining(createdMs: wall), .request)
    _ = try trusted.receive(request)
    if let armTime { time.now = armTime }
    _ = try trusted.arm(override: override)
    let descriptor = try XCTUnwrap(trusted.descriptors.first(where: { $0.rid == request.rid }))
    let offer = try write(trusted.pin(descriptor, handle: trusted.handle, armGeneration: trusted.armGeneration, createdMs: wall), .offer)
    _ = try joining.receive(offer)
    if let selectTime { time.now = selectTime }
    return try write(joining.selectOffer(offer, handle: joining.handle), .select)
  }

  func accountingReservation(_ trusted: S, _ time: Time, seed: UInt64, override: Bool = false, armTime: UInt64? = nil, selectTime: UInt64? = nil) throws -> S.Accounting {
    let selection = try accountingSelection(trusted, time, seed: seed, override: override, armTime: armTime, selectTime: selectTime)
    let output = try trusted.receive(selection)
    XCTAssertTrue(output.writes.isEmpty)
    XCTAssertEqual(trusted.phase, .awaitingPersistence)
    return try XCTUnwrap(output.accounting)
  }

  func serializedAccounting(_ accounting: S.Accounting) throws -> S.Accounting {
    try JSONDecoder().decode(S.Accounting.self, from: JSONEncoder().encode(accounting))
  }

  func testReservationUsesOriginalArmDeadlineWhenItPrecedesRequestDeadline() throws {
    let time = Time(), trusted = try session(.trusted, time, seed: 100)
    let accounting = try accountingReservation(trusted, time, seed: 1000, armTime: 2000, selectTime: 4000)
    XCTAssertEqual(accounting.reveals, [122000])
    XCTAssertEqual(accounting.lastTime, 4000)
    time.now = 121999
    XCTAssertEqual(try write(trusted.persistedAccounting(serializedAccounting(accounting)), .reveal).kind, .reveal)
  }

  func testReservationUsesOriginalFirstSeenDeadlineWhenItPrecedesArmDeadline() throws {
    let time = Time(), trusted = try session(.trusted, time, seed: 100)
    let accounting = try accountingReservation(trusted, time, seed: 1000, armTime: 250000, selectTime: 250001)
    XCTAssertEqual(accounting.reveals, [301000])
    XCTAssertEqual(accounting.lastTime, 250001)
    time.now = 300999
    XCTAssertEqual(try write(trusted.persistedAccounting(serializedAccounting(accounting)), .reveal).kind, .reveal)
  }

  func testPersistenceAcknowledgementAtEitherLatestReleaseDeadlineNeverDiscloses() throws {
    for (armTime, deadline) in [(UInt64(1000), UInt64(121000)), (250000, 301000)] {
      let time = Time(), trusted = try session(.trusted, time, seed: 100)
      let reserved = try accountingReservation(trusted, time, seed: 1000, armTime: armTime)
      time.now = deadline
      XCTAssertThrowsError(try trusted.persistedAccounting(serializedAccounting(reserved)))
      XCTAssertEqual(trusted.phase, .ended)
      XCTAssertEqual(trusted.accounting.reveals.count, 1)
      XCTAssertThrowsError(try trusted.persistedAccounting(serializedAccounting(reserved)))
    }
  }

  func testDelayedPersistenceCannotProduceReviewerFourthTenMinuteDisclosure() throws {
    let time = Time(), trusted = try session(.trusted, time, seed: 100)
    var releases: [UInt64] = []
    for (index, schedule) in [(UInt64(1000), UInt64(120000)), (120001, 120001), (120002, 120002)].enumerated() {
      time.now = schedule.0
      let reserved = try accountingReservation(trusted, time, seed: UInt64(1000 + index * 100))
      time.now = schedule.1
      _ = try write(trusted.persistedAccounting(serializedAccounting(reserved)), .reveal)
      releases.append(time.now)
      _ = try trusted.end(reason: .cancel)
    }
    XCTAssertEqual(releases, [120000, 120001, 120002])
    XCTAssertEqual(trusted.accounting.reveals, [121000, 240001, 240002])
    time.now = 601000
    let restarted = try session(.trusted, time, accounting: serializedAccounting(trusted.accounting))
    XCTAssertThrowsError(try restarted.arm())
    XCTAssertEqual(restarted.accounting.uncertainReveals, 0)
    XCTAssertThrowsError(try trusted.arm())
    XCTAssertEqual(trusted.accounting.reveals.count, 3)
    _ = try trusted.end(reason: .cancel)
    time.now = 720999
    XCTAssertThrowsError(try trusted.arm())
    _ = try trusted.end(reason: .cancel)
    time.now = 721000
    _ = try trusted.arm()
    XCTAssertEqual(trusted.phase, .armed)
  }

  func testDelayedPersistenceCannotProduceReviewerTwentyFirstDailyDisclosure() throws {
    let time = Time(), trusted = try session(.trusted, time, seed: 300)
    var releases: [UInt64] = []
    for index in 0..<20 {
      time.now = index == 0 ? 1000 : 120001 + UInt64(index - 1) * 700000
      let reserved = try accountingReservation(trusted, time, seed: UInt64(10000 + index * 100))
      if index == 0 { time.now = 120000 }
      _ = try write(trusted.persistedAccounting(serializedAccounting(reserved)), .reveal)
      releases.append(time.now)
      _ = try trusted.end(reason: .cancel)
    }
    XCTAssertEqual(releases.count, 20)
    XCTAssertEqual(releases.first, 120000)
    XCTAssertEqual(trusted.accounting.reveals.first, 121000)
    time.now = 86401000
    let restarted = try session(.trusted, time, accounting: serializedAccounting(trusted.accounting))
    XCTAssertThrowsError(try restarted.arm())
    XCTAssertEqual(restarted.accounting.uncertainReveals, 0)
    XCTAssertThrowsError(try trusted.arm())
    XCTAssertEqual(trusted.accounting.reveals.count, 20)
    _ = try trusted.end(reason: .cancel)
    time.now = 86520999
    XCTAssertThrowsError(try trusted.arm())
    _ = try trusted.end(reason: .cancel)
    time.now = 86521000
    _ = try trusted.arm()
    XCTAssertEqual(trusted.accounting.reveals.count, 19)
  }

  func testRestartRetainsFutureReleaseBoundAndRequiresNewDurableRevision() throws {
    let time = Time(), original = try session(.trusted, time, seed: 100)
    let reserved = try accountingReservation(original, time, seed: 1000, armTime: 250000, selectTime: 250001)
    XCTAssertEqual(reserved.reveals, [301000])
    let restored = try serializedAccounting(reserved)
    time.now = 250002
    let restarted = try session(.trusted, time, seed: 200, accounting: restored)
    XCTAssertEqual(restarted.accounting, restored)
    XCTAssertNil(restarted.cryptoContext)
    XCTAssertThrowsError(try restarted.persistedAccounting(restored))
    let next = try accountingReservation(restarted, time, seed: 2000)
    XCTAssertEqual(next.reveals, [301000, 370002])
    XCTAssertEqual(next.revision, restored.revision + 1)
    XCTAssertThrowsError(try restarted.persistedAccounting(restored))
    _ = try write(restarted.persistedAccounting(serializedAccounting(next)), .reveal)
  }

  func testOverrideAcceptsReservation512AndRefusesReservation513() throws {
    let time = Time()
    var initial = S.Accounting(clockEpoch: data(1))
    initial.lastTime = time.now
    initial.reveals = Array(repeating: time.now, count: 511)
    let trusted = try session(.trusted, time, seed: 100, accounting: initial)
    let accepted = try accountingReservation(trusted, time, seed: 1000, override: true)
    XCTAssertEqual(accepted.reveals.count, 512)
    XCTAssertEqual(accepted.revision, initial.revision + 1)
    _ = try write(trusted.persistedAccounting(accepted), .reveal)
    _ = try trusted.end(reason: .cancel)
    let selection = try accountingSelection(trusted, time, seed: 2000, override: true)
    let refused = try trusted.receive(selection)
    XCTAssertNil(refused.accounting)
    XCTAssertFalse(refused.writes.contains(where: { $0.kind == .reveal }))
    XCTAssertEqual(trusted.phase, .ended)
    XCTAssertEqual(trusted.accounting.reveals.count, 512)
  }

  func testRevisionMaximumCanBeReservedOnceButCannotWrap() throws {
    let time = Time()
    var initial = S.Accounting(clockEpoch: data(1))
    initial.lastTime = time.now
    initial.revision = UInt64.max - 1
    let trusted = try session(.trusted, time, seed: 100, accounting: initial)
    let finalRevision = try accountingReservation(trusted, time, seed: 1000)
    XCTAssertEqual(finalRevision.revision, UInt64.max)
    _ = try write(trusted.persistedAccounting(finalRevision), .reveal)
    _ = try trusted.end(reason: .cancel)
    let selection = try accountingSelection(trusted, time, seed: 2000)
    let refused = try trusted.receive(selection)
    XCTAssertNil(refused.accounting)
    XCTAssertFalse(refused.writes.contains(where: { $0.kind == .reveal }))
    XCTAssertEqual(trusted.phase, .ended)
    XCTAssertEqual(trusted.accounting.revision, UInt64.max)
  }

  func testIneligibleJoiningSessionCannotSelectOtherwiseValidOffer() throws {
    let time = Time()
    var ineligible = environment(.joining)
    ineligible.eligible = false
    let joining = try session(.joining, time, seed: 1000, env: ineligible)
    let trusted = try session(.trusted, time, seed: 100)
    let request = try write(joining.startJoining(createdMs: wall), .request)
    _ = try trusted.receive(request)
    _ = try trusted.arm()
    let offer = try write(trusted.pin(XCTUnwrap(trusted.descriptors.first), handle: trusted.handle, armGeneration: trusted.armGeneration, createdMs: wall), .offer)
    _ = try joining.receive(offer)
    XCTAssertEqual(joining.offers, [offer])
    XCTAssertThrowsError(try joining.selectOffer(offer, handle: joining.handle))
    XCTAssertEqual(joining.phase, .requestLive)
    XCTAssertNil(joining.cryptoContext)
  }

  func testObservedRequestHistoryAccepts512AndRefuses513AfterDescriptorEviction() throws {
    let time = Time()
    var env = environment(.trusted)
    let trusted = try session(.trusted, time, seed: 100, env: env)
    for index in 0..<511 {
      let joining = try session(.joining, time, seed: UInt64(10000 + index * 100))
      let request = try write(joining.startJoining(createdMs: wall), .request)
      _ = try trusted.receive(request)
      XCTAssertEqual(trusted.descriptors.map(\.rid), [request.rid])
      env.sessionGeneration += 1
      _ = try trusted.invalidate(env)
      XCTAssertTrue(trusted.descriptors.isEmpty)
    }
    let acceptedJoining = try session(.joining, time, seed: 1000000)
    let accepted = try write(acceptedJoining.startJoining(createdMs: wall), .request)
    _ = try trusted.receive(accepted)
    XCTAssertEqual(trusted.descriptors.map(\.rid), [accepted.rid])
    env.sessionGeneration += 1
    _ = try trusted.invalidate(env)
    let refusedJoining = try session(.joining, time, seed: 2000000)
    let refused = try write(refusedJoining.startJoining(createdMs: wall), .request)
    XCTAssertTrue(try trusted.receive(refused).writes.isEmpty)
    XCTAssertTrue(trusted.descriptors.isEmpty)
    _ = try trusted.receive(accepted)
    XCTAssertEqual(trusted.descriptors.map(\.rid), [accepted.rid])
    XCTAssertEqual(trusted.descriptors.first?.firstSeen, 1000)
  }

  func testUncertaintyAlonePreventsAdmissionWithoutBlockedUntilMaskingIt() throws {
    let time = Time()
    var initial = S.Accounting(clockEpoch: data(1))
    initial.lastTime = time.now
    initial.uncertainReveals = 1
    let trusted = try session(.trusted, time, accounting: initial)
    XCTAssertEqual(trusted.accounting.blockedUntil, 0)
    XCTAssertTrue(trusted.accounting.reveals.isEmpty)
    XCTAssertEqual(trusted.accounting.uncertainReveals, 1)
    XCTAssertThrowsError(try trusted.arm())
    XCTAssertEqual(trusted.phase, .idle)
    _ = try trusted.arm(override: true)
    XCTAssertEqual(trusted.accounting.uncertainReveals, 1)
    initial.uncertainReveals = 0
    let certain = try session(.trusted, time, accounting: initial)
    _ = try certain.arm()
    XCTAssertEqual(certain.phase, .armed)
  }
}

extension PairingSessionTests {
  func testWrongApprovalTranscriptRejectedBeforeNameCanReleaseCandidate() throws {
    let p = try pair()
    _ = try p.j.receive(p.reveal)
    var wire = try grant(p)
    wire[60] ^= 1
    try failed(p.j, entry(wire))
  }

  func testFailedApprovalAttemptConsumesAuthenticationAndNewExactProofCanRelease() throws {
    let p = try pair()
    _ = try ready(p)
    let tuple = try acknowledge(p)
    let authentication = SyntheticPairingOwnerAuthenticator.authenticated( tuple)
    var bad = try grant(p)
    bad[60] ^= 1
    XCTAssertThrowsError(try p.t.commitApproval(wire: bad, ownerAuthentication: authentication))
    XCTAssertEqual(p.t.phase, .comparing)
    XCTAssertThrowsError(try p.t.commitApproval(wire: grant(p), ownerAuthentication: authentication))
    let replacement = SyntheticPairingOwnerAuthenticator.authenticated( tuple)
    _ = try write(p.t.commitApproval(wire: grant(p), ownerAuthentication: replacement), .approval)
  }

  func testAuthenticationSnapshotCannotFollowRecomparison() throws {
    let p = try pair()
    _ = try ready(p)
    var tuple = try acknowledge(p)
    let authentication = SyntheticPairingOwnerAuthenticator.authenticated( tuple)
    _ = try p.t.remount()
    _ = try p.t.present(handle: p.t.handle, armGeneration: p.t.armGeneration)
    tuple = try acknowledge(p)
    XCTAssertThrowsError(try p.t.commitApproval(wire: grant(p), ownerAuthentication: authentication))
    XCTAssertEqual(p.t.phase, .comparing)
    _ = try write(p.t.commitApproval(wire: grant(p), ownerAuthentication: SyntheticPairingOwnerAuthenticator.authenticated( tuple)), .approval)
  }

  func testUnreadableDispositionQuarantineSurvivesSerializedRestart() throws {
    let time = Time()
    let original = try S(role: .trusted, cid: cid(), environment: environment(.trusted), localName: "Mac", clock: time.read, random: Random(1).take, restoration: .unreadable)
    let durable = try serializedAccounting(original.accounting)
    XCTAssertEqual(durable.blockedUntil, 86401000)
    time.now = 51000
    let restarted = try session(.trusted, time, accounting: durable)
    XCTAssertEqual(restarted.accounting.blockedUntil, 86401000)
    XCTAssertThrowsError(try restarted.arm())
    time.now = 86401000
    _ = try restarted.arm()
    XCTAssertEqual(restarted.accounting.uncertainReveals, 0)
  }
  func testAccountingCheckpointAdvancesRevisionAndObservationTime() throws {
    let time = Time(), trusted = try session(.trusted, Time())
    let initial = trusted.accounting
    let first = try trusted.checkpointAccounting()
    XCTAssertEqual(first.revision, initial.revision + 1)
    XCTAssertEqual(first.lastTime, time.now)
    let clocked = try session(.trusted, time)
    _ = try clocked.arm()
    time.now += 500
    let armed = try clocked.checkpointAccounting()
    XCTAssertEqual(armed.lastTime, time.now)
    _ = try clocked.end(reason: .cancel)
    time.now += 500
    let ended = try clocked.checkpointAccounting()
    XCTAssertEqual(ended.revision, armed.revision + 1)
    XCTAssertEqual(ended.lastTime, time.now)
  }

  func testAccountingCheckpointPersistsRollbackQuarantineWithoutRenewingIt() throws {
    let time = Time(), trusted = try session(.trusted, Time())
    var record = trusted.accounting
    record.lastTime = time.now
    record.revision = 6
    let restored = try session(.trusted, time, accounting: record)
    time.now -= 1
    let quarantined = try restored.checkpointAccounting()
    XCTAssertEqual(quarantined.revision, 7)
    XCTAssertEqual(quarantined.lastTime, time.now)
    XCTAssertEqual(quarantined.blockedUntil, time.now + 86400000)
    XCTAssertGreaterThanOrEqual(quarantined.uncertainReveals, 20)
    let restarted = try session(.trusted, time, accounting: quarantined)
    time.now += 10
    let again = try restarted.checkpointAccounting()
    XCTAssertEqual(again.blockedUntil, quarantined.blockedUntil)
    XCTAssertEqual(again.revision, 8)
    XCTAssertEqual(again.lastTime, time.now)
  }

}
