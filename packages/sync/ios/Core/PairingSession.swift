import Foundation

final class PairingSession {
  typealias Role = PairingFormat.Role
  typealias Clock = () -> UInt64

  enum Failure: Error, Equatable {
    case state
    case expired
    case protocolViolation
    case accounting
    case authorization
  }

  enum Kind: UInt8, Codable, CaseIterable {
    case request = 1
    case offer = 2
    case select = 3
    case reveal = 4
    case confirm = 5
    case approval = 6
    case receipt = 7
    case joiningTerminal = 8
    case trustedTerminal = 9
    case joiningName = 10
    case trustedName = 11
  }

  enum Phase: Equatable {
    case idle
    case requestLive
    case armed
    case offered
    case selected
    case awaitingPersistence
    case revealed
    case confirmed
    case comparing
    case released
    case installCommitted
    case installed
    case ended
  }

  enum EndReason: UInt8, Equatable {
    case cancel = 1
    case deny = 2
    case expiry = 3
    case protocolFailure = 4
    case complete = 5
    case invalidated = 6
  }

  enum Event: Equatable {
    case quietIndicator
    case requestsChanged
    case offersChanged
    case comparisonReady
    case approvalReceived(ValidatedApprovalCandidate)
    case installed
    case receipt
    case overflow
    case ended(EndReason)
  }

  struct Entry: Equatable {
    var rid: Data
    var aid: Data?
    var kind: Kind
    var wire: Data
  }

  struct Environment: Equatable {
    var folderIdentity: Data
    var folderGeneration: UInt64 = 1
    var entropyHandle: Data? = nil
    var entropyGeneration: UInt64 = 1
    var sessionGeneration: UInt64 = 1
    var clockEpoch: Data
    var eligible: Bool = true
  }

  struct Accounting: Codable, Equatable {
    var version: UInt8 = 1
    var clockEpoch: Data
    var reveals: [UInt64] = []
    var lastTime: UInt64 = 0
    var blockedUntil: UInt64 = 0
    var revision: UInt64 = 0
    var readable: Bool = true
    var uncertainReveals: Int = 0
  }

  enum RestorationDisposition {
    case newInstallation
    case restored(Accounting)
    case unreadable
  }

  final class OwnerAuthentication {
    fileprivate let authorization: Authorization
    fileprivate var consumed = false

    init(authorizationAfterOwnerAuthentication: Authorization) {
      authorization = authorizationAfterOwnerAuthentication
    }
  }

  final class ValidatedApprovalCandidate: Equatable {
    let wire: Data
    let payload: PairingCrypto.Approval
    fileprivate var consumed = false

    fileprivate init(wire: Data, payload: PairingCrypto.Approval) {
      self.wire = wire
      self.payload = payload
    }

    static func == (lhs: ValidatedApprovalCandidate, rhs: ValidatedApprovalCandidate) -> Bool {
      lhs === rhs
    }
  }

  struct Descriptor: Equatable {
    var rid: Data
    var wire: Data
    var hash: Data
    var firstSeen: UInt64
    var folderGeneration: UInt64
  }

  struct Authorization: Equatable {
    var handle: Data
    var transcript: Data
    var cid: Data
    var rid: Data
    var aid: Data
    var folderIdentity: Data
    var folderGeneration: UInt64
    var entropyHandle: Data
    var entropyGeneration: UInt64
    var sessionGeneration: UInt64
    var comparisonGeneration: UInt64
    var armGeneration: UInt64
    var armDeadline: UInt64
    var requestDeadline: UInt64
    var nameCommitment: Data
  }

  struct CryptoContext {
    var request: Data
    var offer: Data
    var select: Data
    var keys: PairingCrypto.Keys
    var joiningDevice: Data?
  }

  struct Output: Equatable {
    var writes: [Entry] = []
    var events: [Event] = []
    var accounting: Accounting? = nil

    var approvalCandidate: ValidatedApprovalCandidate? {
      for event in events {
        if case .approvalReceived(let candidate) = event { return candidate }
      }
      return nil
    }
  }

  let role: Role
  let cid: Data
  private(set) var environment: Environment
  private(set) var phase: Phase = .idle
  private(set) var handle = Data()
  private(set) var descriptors: [Descriptor] = []
  private(set) var offers: [Entry] = []
  private(set) var code: String?
  private(set) var peerName: String?
  private(set) var comparisonGeneration: UInt64 = 0
  private(set) var armGeneration: UInt64 = 0
  private(set) var deadline: UInt64?
  private(set) var accounting: Accounting
  private(set) var suppressed = true

  private let clock: Clock
  private let random: PairingCrypto.Random
  private let localName: String
  private let comparisonBits: Int
  private var lastObserved: UInt64
  private var privateKey: Data?
  private var contribution: Data?
  private var nameSalt: Data?
  private var joiningDevice: Data?
  private var request: Entry?
  private var offer: Entry?
  private var selection: Entry?
  private var keys: PairingCrypto.Keys?
  private var validatedName: String?
  private var sasValue: String?
  private var visible = false
  private var compared = false
  private var quietEmitted = false
  private var armDeadline: UInt64?
  private var requestDeadline: UInt64?
  private var overrideCurrent = false
  private var taintedRequests: Set<Data> = []
  private var observedRequests: [Data: Observation] = [:]
  private var pinned: [Slot: Data] = [:]
  private var early: [Slot: Entry] = [:]
  private var reservation: Accounting?
  private var pendingReveal: Entry?
  private var approval: Entry?
  private var approvalCandidate: ValidatedApprovalCandidate?

  private struct Observation {
    var hash: Data
    var firstSeen: UInt64
    var folderGeneration: UInt64
  }

  private struct Slot: Hashable {
    var rid: Data
    var aid: Data?
    var kind: Kind
    init(_ entry: Entry) {
      rid = entry.rid
      aid = entry.aid
      kind = entry.kind
    }
  }

  var cryptoContext: CryptoContext? {
    guard validatedName != nil, sasValue != nil, let request, let offer, let selection, let keys else { return nil }
    return CryptoContext(request: request.wire, offer: offer.wire, select: selection.wire, keys: keys, joiningDevice: joiningDevice)
  }

  init(role: Role, cid: Data, environment: Environment, localName: String, clock: @escaping Clock, random: @escaping PairingCrypto.Random, restoration: RestorationDisposition, comparisonBits: Int = 30) throws {
    #if DEBUG
    guard [8, 30].contains(comparisonBits) else { throw Failure.state }
    #else
    guard comparisonBits == 30 else { throw Failure.state }
    #endif
    guard cid.count == 16, !environment.folderIdentity.isEmpty, !environment.clockEpoch.isEmpty else { throw Failure.state }
    self.role = role
    self.cid = cid
    self.environment = environment
    self.localName = try PairingUnicode.canonicalName(Data(localName.utf8), normalizeLocal: true)
    self.clock = clock
    self.random = random
    self.comparisonBits = comparisonBits
    switch restoration {
    case .newInstallation:
      accounting = Accounting(clockEpoch: environment.clockEpoch)
    case .restored(let record):
      accounting = record
    case .unreadable:
      accounting = Accounting(clockEpoch: environment.clockEpoch, readable: false)
    }
    lastObserved = clock()
    normalizeAccounting(now: lastObserved)
  }

  private func added(_ value: UInt64, _ interval: UInt64) throws -> UInt64 {
    let (result, overflow) = value.addingReportingOverflow(interval)
    guard !overflow else { throw Failure.expired }
    return result
  }

  private func fresh(_ count: Int) throws -> Data {
    let value = try PairingCrypto.randomBytes(count, using: random)
    if count == 16 { try PairingFormat.session(value) }
    return value
  }

  private func clearAttempt() {
    privateKey = nil
    contribution = nil
    nameSalt = nil
    joiningDevice = nil
    request = nil
    offer = nil
    selection = nil
    keys = nil
    validatedName = nil
    sasValue = nil
    code = nil
    peerName = nil
    compared = false
    visible = false
    pinned.removeAll()
    early.removeAll()
    reservation = nil
    pendingReveal = nil
    approval = nil
    approvalCandidate = nil
    deadline = nil
    requestDeadline = nil
    armDeadline = nil
    offers.removeAll()
  }

  private func emit(_ wire: Data, kind: Kind) throws -> Entry {
    let message = try PairingFormat.decode(wire)
    let value = Entry(rid: message.rid, aid: kind == .request ? nil : message.aid, kind: kind, wire: wire)
    pinned[Slot(value)] = wire
    return value
  }

  private func packet(_ body: PairingFormat.Body, kind: Kind) throws -> Entry {
    guard let request, let aid = offer?.aid else { throw Failure.state }
    return try emit(PairingFormat.encode(.init(cid: cid, rid: request.rid, aid: aid, body: body)), kind: kind)
  }

  func startJoining(createdMs: UInt64) throws -> Output {
    guard role == .joining, phase == .idle || phase == .ended else { throw Failure.state }
    clearAttempt()
    do {
      let now = clock()
      guard now >= lastObserved else { throw Failure.expired }
      lastObserved = now
      deadline = try added(now, 300000)
      requestDeadline = deadline
      handle = try fresh(16)
      joiningDevice = try fresh(16)
      let session = try fresh(16), rid = try fresh(16)
      let secret = try fresh(32), opening = try fresh(32), salt = try fresh(32)
      guard !PairingCrypto.equal(opening, salt) else { throw PairingFormat.Failure.random }
      privateKey = secret
      contribution = opening
      nameSalt = salt
      var body = PairingFormat.Request(session: session, publicKey: try PairingCrypto.publicKey(secret), name: "New Mac", createdMs: createdMs, expiresMs: try added(createdMs, 300000), nameCommitment: try PairingCrypto.nameCommitment(role: .joining, name: localName, salt: salt), commitment: Data(count: 32))
      var message = PairingFormat.Message(cid: cid, rid: rid, aid: Data(count: 16), body: .request(body))
      body.commitment = try PairingCrypto.commitment(role: .joining, core: PairingFormat.core(message), random: opening)
      message.body = .request(body)
      let value = try emit(PairingFormat.encode(message), kind: .request)
      request = value
      visible = true
      comparisonGeneration += 1
      phase = .requestLive
      return Output(writes: [value])
    } catch {
      _ = finish(.protocolFailure, notify: false)
      throw error
    }
  }

  private func normalizeAccounting(now: UInt64) {
    let malformed = accounting.version != 1 || accounting.reveals.count > 512 || !(0...512).contains(accounting.uncertainReveals) || accounting.reveals.contains(where: { $0 > ((try? added(accounting.lastTime, 120000)) ?? UInt64.max) })
    if !accounting.readable || malformed || accounting.clockEpoch != environment.clockEpoch || now < accounting.lastTime {
      accounting.uncertainReveals = min(max(accounting.uncertainReveals, 0), 512) + min(accounting.reveals.count, 512)
      accounting.uncertainReveals = min(accounting.uncertainReveals, 512)
      if !accounting.readable || malformed { accounting.uncertainReveals = max(accounting.uncertainReveals, 20) }
      accounting.reveals = []
      accounting.clockEpoch = environment.clockEpoch
      accounting.lastTime = now
      accounting.blockedUntil = (try? added(now, 86400000)) ?? UInt64.max
      accounting.readable = true
      accounting.version = 1
    }
    if accounting.blockedUntil > 0 && now >= accounting.blockedUntil {
      accounting.blockedUntil = 0
      accounting.uncertainReveals = 0
    }
    accounting.reveals = accounting.reveals.filter { now < $0 || now - $0 < 86400000 }.sorted()
  }

  private func permitsReveal(now: UInt64) -> Bool {
    normalizeAccounting(now: now)
    return accounting.blockedUntil <= now && accounting.uncertainReveals == 0 && accounting.reveals.count < 20 && accounting.reveals.filter { now < $0 || now - $0 < 600000 }.count < 3
  }

  func arm(override: Bool = false) throws -> Output {
    guard role == .trusted, phase == .idle || phase == .ended else { throw Failure.state }
    guard environment.eligible, environment.entropyHandle != nil else { throw Failure.authorization }
    let now = clock()
    normalizeAccounting(now: now)
    guard override || permitsReveal(now: now) else { throw Failure.accounting }
    clearAttempt()
    do {
      guard now >= lastObserved else {
        accounting.readable = false
        normalizeAccounting(now: now)
        throw Failure.accounting
      }
      lastObserved = now
      armDeadline = try added(now, 120000)
      deadline = armDeadline
      handle = try fresh(16)
      armGeneration += 1
      comparisonGeneration += 1
      overrideCurrent = override
      suppressed = false
      quietEmitted = false
      visible = true
      phase = .armed
      return Output()
    } catch {
      _ = finish(.protocolFailure, notify: false)
      throw error
    }
  }

  private func requireLive() throws {
    let output = try tick()
    guard output.events.isEmpty, phase != .ended, phase != .idle else { throw Failure.expired }
    guard environment.eligible else { throw Failure.authorization }
  }

  func pin(_ descriptor: Descriptor, handle: Data, armGeneration: UInt64, createdMs: UInt64) throws -> Output {
    guard role == .trusted, phase == .armed else { throw Failure.state }
    guard self.handle == handle, self.armGeneration == armGeneration else { throw Failure.authorization }
    try requireLive()
    do {
      guard !taintedRequests.contains(descriptor.rid), let current = descriptors.first(where: { $0.rid == descriptor.rid }), current.firstSeen == descriptor.firstSeen, current.folderGeneration == descriptor.folderGeneration, descriptor.folderGeneration == environment.folderGeneration, PairingCrypto.equal(current.hash, descriptor.hash), PairingCrypto.equal(current.wire, descriptor.wire), PairingCrypto.equal(descriptor.hash, PairingCrypto.hash(descriptor.wire)) else { throw Failure.protocolViolation }
      let now = clock()
      requestDeadline = try added(descriptor.firstSeen, 300000)
      guard let armDeadline, let requestDeadline, now < armDeadline, now < requestDeadline else { throw Failure.expired }
      deadline = min(armDeadline, requestDeadline)
      let incoming = try checked(Entry(rid: descriptor.rid, aid: nil, kind: .request, wire: descriptor.wire))
      guard case .request = incoming.body else { throw Failure.protocolViolation }
      request = try emit(descriptor.wire, kind: .request)
      let aid = try fresh(16), session = try fresh(16), secret = try fresh(32), opening = try fresh(32), salt = try fresh(32)
      guard !PairingCrypto.equal(opening, salt) else { throw PairingFormat.Failure.random }
      privateKey = secret
      contribution = opening
      nameSalt = salt
      var body = PairingFormat.Offer(requestHash: descriptor.hash, session: session, publicKey: try PairingCrypto.publicKey(secret), name: "Trusted Mac", createdMs: createdMs, expiresMs: try added(createdMs, 300000), nameCommitment: try PairingCrypto.nameCommitment(role: .trusted, name: localName, salt: salt), commitment: Data(count: 32))
      var message = PairingFormat.Message(cid: cid, rid: descriptor.rid, aid: aid, body: .offer(body))
      body.commitment = try PairingCrypto.commitment(role: .trusted, core: PairingFormat.core(message), random: opening)
      message.body = .offer(body)
      let value = try emit(PairingFormat.encode(message), kind: .offer)
      offer = value
      phase = .offered
      return Output(writes: [value])
    } catch {
      _ = finish(.protocolFailure)
      throw error
    }
  }

  private func checked(_ entry: Entry) throws -> PairingFormat.Message {
    let message = try PairingFormat.decode(entry.wire)
    guard entry.wire[5] == entry.kind.rawValue, message.cid == cid, message.rid == entry.rid else { throw Failure.protocolViolation }
    if entry.kind == .request {
      guard entry.aid == nil else { throw Failure.protocolViolation }
    } else {
      guard let aid = entry.aid, aid == message.aid else { throw Failure.protocolViolation }
    }
    return message
  }

  private func observeRequest(_ entry: Entry) throws -> Output {
    guard entry.wire.count <= 8192 else { throw Failure.protocolViolation }
    let hash = PairingCrypto.hash(entry.wire)
    if let observed = observedRequests[entry.rid], !PairingCrypto.equal(observed.hash, hash) {
      taintedRequests.insert(entry.rid)
      if phase != .idle && phase != .ended { return finish(.protocolFailure) }
      return Output()
    }
    let message = try checked(entry)
    guard case .request = message.body else { throw Failure.protocolViolation }
    let now = clock()
    descriptors.removeAll { now >= $0.firstSeen && now - $0.firstSeen >= 300000 }
    let descriptor: Descriptor
    if let observed = observedRequests[entry.rid] {
      guard now >= observed.firstSeen, now - observed.firstSeen < 300000 else { return Output() }
      descriptor = Descriptor(rid: entry.rid, wire: entry.wire, hash: observed.hash, firstSeen: observed.firstSeen, folderGeneration: observed.folderGeneration)
    } else {
      guard observedRequests.count < 512 else { return Output() }
      descriptor = Descriptor(rid: entry.rid, wire: entry.wire, hash: hash, firstSeen: now, folderGeneration: environment.folderGeneration)
      observedRequests[entry.rid] = Observation(hash: hash, firstSeen: now, folderGeneration: environment.folderGeneration)
    }
    guard !descriptors.contains(where: { $0.rid == entry.rid }), descriptors.count < 8 else { return Output() }
    descriptors.append(descriptor)
    if phase == .armed { return Output(events: [.requestsChanged]) }
    guard (phase == .idle || phase == .ended), !suppressed, !quietEmitted else { return Output() }
    quietEmitted = true
    return Output(events: [.quietIndicator])
  }

  func receive(_ entry: Entry) throws -> Output {
    if phase == .installCommitted || phase == .installed { return Output() }
    if role == .trusted && entry.kind == .request {
      if phase != .idle && phase != .ended {
        let expired = try tick()
        if !expired.events.isEmpty { return expired }
      }
      do {
        if let existing = pinned[Slot(entry)] {
          guard PairingCrypto.equal(existing, entry.wire) else { return finish(.protocolFailure) }
          return Output()
        }
        return try observeRequest(entry)
      } catch {
        return phase == .idle || phase == .ended ? Output() : finish(.protocolFailure)
      }
    }
    guard phase != .ended && phase != .idle else { return Output() }
    let expired = try tick()
    if !expired.events.isEmpty { return expired }
    if entry.kind == .joiningTerminal || entry.kind == .trustedTerminal { return terminal(entry) }
    if entry.kind == .receipt { return receipt(entry) }
    do {
      let message = try checked(entry)
      if let existing = pinned[Slot(entry)] {
        guard PairingCrypto.equal(existing, entry.wire) else { throw Failure.protocolViolation }
        return Output()
      }
      if let existing = early[Slot(entry)] {
        guard PairingCrypto.equal(existing.wire, entry.wire) else { throw Failure.protocolViolation }
        return Output()
      }
      if role == .joining && entry.kind == .offer {
        guard let request, message.rid == request.rid, case .offer(let body) = message.body, PairingCrypto.equal(body.requestHash, PairingCrypto.hash(request.wire)) else { throw Failure.protocolViolation }
        if offer != nil { return Output() }
        guard offers.count < 8 else { return Output(events: [.overflow]) }
        offers.append(entry)
        pinned[Slot(entry)] = entry.wire
        return Output(events: [.offersChanged])
      }
      guard let request, message.rid == request.rid else { throw Failure.protocolViolation }
      if role == .trusted && entry.kind == .select && message.aid != offer?.aid {
        guard case .select(let requestHash, _, _) = message.body, PairingCrypto.equal(requestHash, PairingCrypto.hash(request.wire)) else { throw Failure.protocolViolation }
        return finish(.cancel, notify: false)
      }
      if let aid = offer?.aid { guard message.aid == aid else { throw Failure.protocolViolation } }
      let allowed: [Kind] = role == .joining ? [.reveal, .trustedName, .approval] : [.select, .confirm, .joiningName]
      guard allowed.contains(entry.kind) else { throw Failure.protocolViolation }
      guard early.count < 8 else { return finish(.protocolFailure) }
      if entry.kind == .approval, keys != nil { try checkEnvelope(entry.wire, kind: .approval) }
      early[Slot(entry)] = entry
      return try drain()
    } catch {
      return finish(.protocolFailure)
    }
  }

  func selectOffer(_ capturedOffer: Entry, handle: Data) throws -> Output {
    guard role == .joining, phase == .requestLive, offer == nil else { throw Failure.state }
    guard self.handle == handle else { throw Failure.authorization }
    try requireLive()
    do {
      guard let value = offers.first(where: { $0.rid == capturedOffer.rid && $0.aid == capturedOffer.aid && $0.kind == capturedOffer.kind && PairingCrypto.equal($0.wire, capturedOffer.wire) }), let aid = value.aid, let request, let contribution else { throw Failure.state }
      offer = value
      let selected = try packet(.select(requestHash: PairingCrypto.hash(request.wire), offerHash: PairingCrypto.hash(value.wire), random: contribution), kind: .select)
      selection = selected
      phase = .selected
      early = early.filter { $0.key.aid == aid }
      var output = Output(writes: [selected])
      output.merge(try drain())
      return output
    } catch {
      _ = finish(.protocolFailure)
      throw error
    }
  }

  private func take(_ kind: Kind) -> Entry? {
    guard let request, let aid = offer?.aid else { return nil }
    let slot = Slot(Entry(rid: request.rid, aid: aid, kind: kind, wire: Data()))
    return early.removeValue(forKey: slot)
  }

  private func accept(_ entry: Entry) {
    pinned[Slot(entry)] = entry.wire
  }

  private func drain() throws -> Output {
    var output = Output()
    if role == .trusted, phase == .offered, let selected = take(.select) {
      guard let request, let offer, let contribution, let privateKey else { throw Failure.state }
      let transcript = try PairingCrypto.transcript(request: request.wire, offer: offer.wire, select: selected.wire, trustedRandom: contribution)
      let (_, j, _, _) = try PairingCrypto.context(request: request.wire, offer: offer.wire)
      keys = try PairingCrypto.keys(secret: PairingCrypto.sharedSecret(privateKey, j.publicKey), transcript: transcript)
      selection = selected
      accept(selected)
      let now = clock()
      normalizeAccounting(now: now)
      guard overrideCurrent || permitsReveal(now: now), accounting.reveals.count < 512 else { throw Failure.accounting }
      accounting.lastTime = now
      guard let deadline else { throw Failure.state }
      accounting.reveals.append(deadline)
      let (revision, overflow) = accounting.revision.addingReportingOverflow(1)
      guard !overflow else { throw Failure.accounting }
      accounting.revision = revision
      reservation = accounting
      guard let keys else { throw Failure.state }
      let wire = try PairingFormat.encode(.init(cid: cid, rid: request.rid, aid: try requiredAid(), body: .reveal(selectHash: PairingCrypto.hash(selected.wire), random: contribution, confirmation: PairingCrypto.confirmation(role: .trusted, keys: keys))))
      pendingReveal = Entry(rid: request.rid, aid: offer.aid, kind: .reveal, wire: wire)
      phase = .awaitingPersistence
      output.accounting = accounting
    }
    if role == .joining, phase == .selected, let revealed = take(.reveal) {
      guard let request, let offer, let selection, let privateKey else { throw Failure.state }
      let message = try checked(revealed)
      guard case .reveal(let selectHash, let opening, _) = message.body, PairingCrypto.equal(selectHash, PairingCrypto.hash(selection.wire)) else { throw Failure.protocolViolation }
      let transcript = try PairingCrypto.transcript(request: request.wire, offer: offer.wire, select: selection.wire, trustedRandom: opening)
      let (_, _, _, t) = try PairingCrypto.context(request: request.wire, offer: offer.wire)
      let derived = try PairingCrypto.keys(secret: PairingCrypto.sharedSecret(privateKey, t.publicKey), transcript: transcript)
      try PairingCrypto.validateReveal(revealed.wire, request: request.wire, offer: offer.wire, select: selection.wire, keys: derived)
      keys = derived
      accept(revealed)
      let confirm = try packet(.confirm(transcript: transcript, confirmation: PairingCrypto.confirmation(role: .joining, keys: derived)), kind: .confirm)
      guard let nameSalt else { throw Failure.state }
      let name = try emit(PairingCrypto.sealName(role: .joining, name: localName, salt: nameSalt, cid: cid, rid: request.rid, aid: requiredAid(), keys: derived, rng: random), kind: .joiningName)
      phase = .confirmed
      output.writes += [confirm, name]
    }
    if role == .trusted, phase == .revealed, let confirmed = take(.confirm) {
      guard let request, let offer, let keys else { throw Failure.state }
      try PairingCrypto.validateConfirmation(confirmed.wire, request: request.wire, offer: offer.wire, keys: keys)
      accept(confirmed)
      phase = .confirmed
    }
    if phase == .confirmed, let name = take(role == .joining ? .trustedName : .joiningName) {
      guard let request, let offer, let keys else { throw Failure.state }
      let (_, j, _, t) = try PairingCrypto.context(request: request.wire, offer: offer.wire)
      let nameRole: Role = role == .joining ? .trusted : .joining
      validatedName = try PairingCrypto.openName(name.wire, role: nameRole, cid: cid, rid: request.rid, aid: requiredAid(), commitment: nameRole == .joining ? j.nameCommitment : t.nameCommitment, keys: keys)
      accept(name)
      if role == .trusted {
        guard let nameSalt else { throw Failure.state }
        output.writes.append(try emit(PairingCrypto.sealName(role: .trusted, name: localName, salt: nameSalt, cid: cid, rid: request.rid, aid: requiredAid(), keys: keys, rng: random), kind: .trustedName))
      }
      let mac = try PairingCrypto.mac(keys.key("sas"), PairingFormat.frame("compare", keys.transcript))
      sasValue = comparisonBits == 30 ? try PairingCrypto.sasBits(mac) : String(format: "%02X", mac[0])
      phase = .comparing
      if visible {
        code = sasValue
        peerName = validatedName
        output.events.append(.comparisonReady)
      }
    }
    if role == .joining, phase == .comparing, let candidate = take(.approval) {
      try checkEnvelope(candidate.wire, kind: .approval)
      guard let request, let offer, let keys else { throw Failure.state }
      let opened = try PairingCrypto.openApproval(candidate.wire, request: request.wire, offer: offer.wire, keys: keys)
      let validated = ValidatedApprovalCandidate(wire: candidate.wire, payload: opened)
      accept(candidate)
      approval = candidate
      approvalCandidate = validated
      output.events.append(.approvalReceived(validated))
    }
    return output
  }

  private func requiredAid() throws -> Data {
    guard let aid = offer?.aid else { throw Failure.state }
    return aid
  }

  func persistedAccounting(_ value: Accounting) throws -> Output {
    guard role == .trusted, phase == .awaitingPersistence, let reservation, value == reservation, let pendingReveal else { throw Failure.accounting }
    try requireLive()
    accept(pendingReveal)
    self.pendingReveal = nil
    self.reservation = nil
    phase = .revealed
    var output = Output(writes: [pendingReveal])
    do { output.merge(try drain()) }
    catch { output.merge(finish(.protocolFailure)) }
    return output
  }

  func tick() throws -> Output {
    if phase == .installCommitted || phase == .installed { return Output() }
    let now = clock()
    if now < lastObserved {
      accounting.readable = false
      normalizeAccounting(now: now)
      lastObserved = now
      return phase == .idle || phase == .ended ? Output() : finish(.invalidated)
    }
    lastObserved = now
    guard phase != .idle && phase != .ended else { return Output() }
    if let deadline, now >= deadline { return finish(.expiry) }
    return Output()
  }

  func hide() throws -> Output {
    let expired = try tick()
    visible = false
    compared = false
    comparisonGeneration += 1
    code = nil
    peerName = nil
    return expired
  }

  func remount() throws -> Output { try hide() }

  func present(handle: Data, armGeneration: UInt64) throws -> Output {
    try requireLive()
    guard self.handle == handle, self.armGeneration == armGeneration else { throw Failure.authorization }
    visible = true
    compared = false
    comparisonGeneration += 1
    if phase == .comparing {
      code = sasValue
      peerName = validatedName
      return Output(events: [.comparisonReady])
    }
    return Output()
  }

  func acknowledgeComparison(handle: Data, generation: UInt64) throws -> Output {
    try requireLive()
    guard role == .trusted, phase == .comparing, visible, self.handle == handle, comparisonGeneration == generation, validatedName != nil, code != nil else { throw Failure.authorization }
    compared = true
    return Output()
  }

  func authorization() throws -> Authorization {
    try requireLive()
    guard role == .trusted, phase == .comparing, visible, compared, let keys, let request, let aid = offer?.aid, let entropyHandle = environment.entropyHandle, let armDeadline, let requestDeadline, let peer = try? PairingFormat.decode(request.wire), case .request(let body) = peer.body else { throw Failure.authorization }
    return Authorization(handle: handle, transcript: keys.transcript, cid: cid, rid: request.rid, aid: aid, folderIdentity: environment.folderIdentity, folderGeneration: environment.folderGeneration, entropyHandle: entropyHandle, entropyGeneration: environment.entropyGeneration, sessionGeneration: environment.sessionGeneration, comparisonGeneration: comparisonGeneration, armGeneration: armGeneration, armDeadline: armDeadline, requestDeadline: requestDeadline, nameCommitment: body.nameCommitment)
  }

  func validateAuthorization(_ value: Authorization) throws {
    let current = try authorization()
    guard PairingCrypto.equal(current.transcript, value.transcript), PairingCrypto.equal(current.nameCommitment, value.nameCommitment), current.handle == value.handle, current.cid == value.cid, current.rid == value.rid, current.aid == value.aid, current.folderIdentity == value.folderIdentity, current.folderGeneration == value.folderGeneration, current.entropyHandle == value.entropyHandle, current.entropyGeneration == value.entropyGeneration, current.sessionGeneration == value.sessionGeneration, current.comparisonGeneration == value.comparisonGeneration, current.armGeneration == value.armGeneration, current.armDeadline == value.armDeadline, current.requestDeadline == value.requestDeadline else { throw Failure.authorization }
  }

  private func checkEnvelope(_ wire: Data, kind: Kind) throws {
    guard let request, let keys else { throw Failure.state }
    let entry = Entry(rid: request.rid, aid: try requiredAid(), kind: kind, wire: wire)
    let message = try checked(entry)
    guard case .encrypted(let type, let transcript, _, _, _) = message.body, type == kind.rawValue, PairingCrypto.equal(transcript, keys.transcript) else { throw Failure.protocolViolation }
  }

  func commitApproval(wire: Data, ownerAuthentication: OwnerAuthentication) throws -> Output {
    guard !ownerAuthentication.consumed else { throw Failure.authorization }
    ownerAuthentication.consumed = true
    try validateAuthorization(ownerAuthentication.authorization)
    try checkEnvelope(wire, kind: .approval)
    let entry = try emit(wire, kind: .approval)
    approval = entry
    phase = .released
    compared = false
    return Output(writes: [entry])
  }

  func retryApproval() throws -> Output {
    try requireLive()
    guard role == .trusted, phase == .released, let approval else { throw Failure.state }
    return Output(writes: [approval])
  }

  func commitInstall(coordinatorValidatedRootCIDSessionAndDevice candidate: ValidatedApprovalCandidate) throws -> Output {
    try requireLive()
    guard role == .joining, phase == .comparing, let approval, approvalCandidate === candidate, !candidate.consumed, PairingCrypto.equal(approval.wire, candidate.wire), validatedName != nil else { throw Failure.authorization }
    candidate.consumed = true
    phase = .installCommitted
    compared = false
    code = nil
    peerName = nil
    return Output()
  }

  func installed() throws -> Output {
    guard role == .joining, phase == .installCommitted, let approval, let keys else { throw Failure.state }
    let receipt = try emit(PairingCrypto.receipt(approval: approval.wire, keys: keys), kind: .receipt)
    clearAttempt()
    phase = .installed
    return Output(writes: [receipt], events: [.installed])
  }

  private func terminal(_ entry: Entry) -> Output {
    guard phase != .released, let request, let keys, let aid = offer?.aid else { return Output() }
    let peer: Role = role == .joining ? .trusted : .joining
    guard entry.kind == (peer == .joining ? .joiningTerminal : .trustedTerminal), let message = try? checked(entry), message.rid == request.rid, message.aid == aid else { return Output() }
    do {
      try PairingCrypto.validateTerminal(entry.wire, role: peer, cid: cid, rid: request.rid, aid: aid, keys: keys)
      guard case .terminal(_, _, let reason, _) = message.body else { return Output() }
      return finish(EndReason(rawValue: reason) ?? .protocolFailure, notify: false)
    } catch { return Output() }
  }

  private func receipt(_ entry: Entry) -> Output {
    guard role == .trusted, phase == .released, let approval, let keys else { return Output() }
    do {
      _ = try checked(entry)
      try PairingCrypto.validateReceipt(entry.wire, approval: approval.wire, keys: keys)
      var output = finish(.complete, notify: false)
      output.events.insert(.receipt, at: 0)
      return output
    } catch { return Output() }
  }

  private func finish(_ reason: EndReason, notify: Bool = true) -> Output {
    guard phase != .installCommitted && phase != .installed else { return Output() }
    let committed = phase == .released
    var output = Output(events: [.ended(reason)])
    if notify && !committed, let keys, let request, let aid = offer?.aid {
      let terminalReason: UInt8
      switch reason {
      case .expiry: terminalReason = 3
      case .protocolFailure, .invalidated: terminalReason = 4
      default: terminalReason = role == .joining ? 1 : 2
      }
      if let wire = try? PairingCrypto.terminal(role: role, reason: terminalReason, cid: cid, rid: request.rid, aid: aid, keys: keys), let entry = try? emit(wire, kind: role == .joining ? .joiningTerminal : .trustedTerminal) {
        output.writes = [entry]
      }
    }
    clearAttempt()
    comparisonGeneration += 1
    phase = .ended
    return output
  }

  func end(reason: EndReason) throws -> Output {
    if phase == .idle || phase == .ended { return Output() }
    return finish(reason)
  }

  func dismissUnsolicited() throws -> Output {
    suppressed = true
    return try end(reason: .deny)
  }

  func invalidate(_ value: Environment) throws -> Output {
    guard value != environment else { return Output() }
    let output = finish(.invalidated)
    if value.clockEpoch != environment.clockEpoch { taintedRequests.formUnion(observedRequests.keys) }
    environment = value
    descriptors.removeAll()
    normalizeAccounting(now: clock())
    return output
  }
}

private extension PairingSession.Output {
  mutating func merge(_ other: Self) {
    writes += other.writes
    events += other.events
    if let accounting = other.accounting { self.accounting = accounting }
  }
}
