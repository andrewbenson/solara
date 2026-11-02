import Foundation

public enum PairingJoinState: Equatable {
  case preparing
  case waiting(expires: ContinuousClock.Instant)
  case comparing(code: String, claimedName: String)
  case approved
  case installed
  case failed(PairingJoinFailure)
}

public enum PairingJoinFailure: Equatable {
  case expired, denied, mismatch, folderUnavailable, invalidPeer, cancelled
}

public enum PairingCancelResult: Equatable { case cancelled, alreadyCommitted, unavailable }

public protocol PairingJoining: AnyObject {
  func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle
  func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool
}

public protocol PairingJoinHandle: AnyObject {
  @discardableResult func cancel() -> PairingCancelResult
  func startAgain()
}

protocol PairingCoordinatingMailbox: AnyObject {
  var pairingCID: String { get }
  var pairingFolderIdentity: Data { get }
  var pairingFolder: URL { get }
  func remove(expected: [PairingSession.Entry])
  func poll(rids: Set<Data>) throws -> [PairingSession.Entry]
  func publish(_ entry: PairingSession.Entry, admit: () -> Bool) throws -> PairingMailbox.WriteOutcome
}

struct PairingInstallation: Codable, Equatable {
  let transaction: Data
  let cid: String
  let device: String
  let folderIdentity: Data
  let generation: UInt64
}

struct PairingInstallationDecision: Codable, Equatable {
  enum Disposition: String, Codable { case admitted, cancelled }
  let installation: PairingInstallation
  let disposition: Disposition
}

protocol PairingInstallationHosting: AnyObject {
  func prepare(_ installation: PairingInstallation, completion: @escaping (Bool) -> Void)
  func keySaved(_ installation: PairingInstallation, initialized: @escaping (Bool) -> Void, ready: @escaping (Bool) -> Void)
}

final class PairingTrustedHandle {
  fileprivate init() {}
}

final class PairingComparisonHandle {
  fileprivate let owner: PairingTrustedHandle
  fileprivate let generation: UInt64
  let code: String
  let claimedName: String
  fileprivate init(owner: PairingTrustedHandle, generation: UInt64, code: String, claimedName: String) {
    self.owner = owner; self.generation = generation; self.code = code; self.claimedName = claimedName
  }
}

final class PairingRequestHandle {
  fileprivate let owner: PairingTrustedHandle
  fileprivate let descriptor: PairingSession.Descriptor
  fileprivate init(_ owner: PairingTrustedHandle, _ descriptor: PairingSession.Descriptor) {
    self.owner = owner
    self.descriptor = descriptor
  }
}

final class PairingCoordinator: PairingJoining {
  enum InvalidationReason { case stop, lock, safeMode, folder, key, surface, shutdown }
  enum Failure: Error { case occupied, stale, unavailable }
  struct Configuration {
    var cid: String
    var environment: PairingSession.Environment
    var localName: String
    var entropy: Data?
    var trustedDevice: Data?
  }
  struct Snapshot {
    var joining: Bool
    var trusted: Bool
    var trustedPhase: PairingSession.Phase?
    var code: String?
    var claimedName: String?
  }
  private final class Control: PairingJoinHandle {
    weak var owner: PairingCoordinator?
    private let resultLock = NSLock()
    private var detachedResult: PairingCancelResult = .cancelled
    var generation: UInt64 = 0
    let cid: String
    let callback: @MainActor (PairingJoinState) -> Void
    init(_ owner: PairingCoordinator, _ cid: String, _ callback: @escaping @MainActor (PairingJoinState) -> Void) {
      self.owner = owner; self.cid = cid; self.callback = callback
    }
    func remember(_ result: PairingCancelResult) {
      resultLock.lock()
      detachedResult = result
      resultLock.unlock()
    }
    @discardableResult func cancel() -> PairingCancelResult {
      if let owner { return owner.cancel(self) }
      resultLock.lock()
      defer { resultLock.unlock() }
      return detachedResult
    }
    func startAgain() { owner?.restart(self) }
  }

  private final class Binding {
    let mailbox: PairingCoordinatingMailbox
    let cid: String
    let folderIdentity: Data
    init(_ mailbox: PairingCoordinatingMailbox) {
      self.mailbox = mailbox; cid = mailbox.pairingCID; folderIdentity = mailbox.pairingFolderIdentity
    }
  }

  private final class Joining {
    let binding: Binding
    var installation: PairingInstallation?
    var writeStarted = false
    var cancelRequested = false
    var admissionUncertain = false
    let control: Control
    let session: PairingSession
    let generation: UInt64
    var installing = false
    var prepareCompleted = false
    var listeners: [@MainActor (PairingJoinState) -> Void] = []
    var committed = false
    var initialized = false
    var ready = false
    var invalidated = false
    init(_ control: Control, _ session: PairingSession, _ binding: Binding) {
      self.binding = binding
      self.control = control; self.session = session; generation = control.generation
    }
  }

  private final class Trusted {
    let binding: Binding
    let handle = PairingTrustedHandle()
    let session: PairingSession
    var ready = false
    var authentication: PairingAuthenticationAttempt?
    var authenticating = false
    var retry: PairingSession.Entry?
    init(_ session: PairingSession, _ binding: Binding) { self.session = session; self.binding = binding }
  }

  private let admission = DispatchQueue(label: "solara.sync.pairing.admission")
  private let worker = DispatchQueue(label: "solara.sync.pairing.local", qos: .utility)
  private let mailboxWorker = DispatchQueue(label: "solara.sync.pairing.mailbox", qos: .utility)
  private let queueKey = DispatchSpecificKey<Bool>()
  private var binding: Binding?
  private let store: PairingAccountingStoring
  private let authenticator: PairingOwnerAuthenticating
  private let keyStore: PairingInstallationKeyStoring
  private let host: PairingInstallationHosting
  private let clock: () -> UInt64
  private let wall: () -> UInt64
  private let random: PairingCrypto.Random
  private var configuration: Configuration
  private var restoration: PairingSession.RestorationDisposition
  private var accounting: PairingSession.Accounting?
  private var joining: Joining?
  private var trusted: Trusted?
  private var control: Control?
  private var generation: UInt64 = 0
  private var outstandingWork = 0
  private var polling = false
  private var pollDirty = false
  private var nextPoll: UInt64 = 0
  private var ownedPackets: [ObjectIdentifier: [PairingSession.Entry]] = [:]
  private var cleanupGrace: [(deadline: UInt64, entries: [PairingSession.Entry], binding: Binding)] = []
  private var timer: DispatchSourceTimer?

  init(configuration: Configuration, mailbox: PairingCoordinatingMailbox, store: PairingAccountingStoring, authenticator: PairingOwnerAuthenticating, keyStore: PairingInstallationKeyStoring, host: PairingInstallationHosting, clock: @escaping () -> UInt64, wall: @escaping () -> UInt64, random: @escaping PairingCrypto.Random = PairingCrypto.random) {
    self.configuration = configuration; self.store = store
    binding = try? Self.bind(configuration, mailbox: mailbox, store: store)
    if binding == nil { self.configuration.environment.eligible = false }
    self.authenticator = authenticator; self.keyStore = keyStore; self.host = host
    self.clock = clock; self.wall = wall; self.random = random
    restoration = store.restoreAccounting(now: clock(), epoch: configuration.environment.clockEpoch)
    if case .restored(let value) = restoration { accounting = value }
    admission.setSpecific(key: queueKey, value: true)
    let source = DispatchSource.makeTimerSource(queue: admission)
    source.schedule(deadline: .now() + 1, repeating: 1)
    source.setEventHandler { [weak self] in self?.pollOwned() }
    timer = source
    source.resume()
  }

  private static func bind(_ configuration: Configuration, mailbox: PairingCoordinatingMailbox, store: PairingAccountingStoring) throws -> Binding {
    try store.validatePlacement(pairingFolder: mailbox.pairingFolder)
    guard mailbox.pairingCID == configuration.cid, mailbox.pairingFolderIdentity == configuration.environment.folderIdentity else { throw Failure.unavailable }
    return Binding(mailbox)
  }

  private func transport(_ session: PairingSession) -> Binding? {
    if let slot = joining, slot.session === session { return slot.binding }
    if let slot = trusted, slot.session === session { return slot.binding }
    return nil
  }

  deinit { timer?.cancel() }

  private func owned<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
    return try admission.sync(execute: body)
  }

  var snapshot: Snapshot {
    owned {
      Snapshot(joining: joining != nil, trusted: trusted != nil, trustedPhase: trusted?.session.phase, code: trusted?.session.code.map(Self.displayCode), claimedName: trusted?.session.peerName)
    }
  }

  @discardableResult private func work(_ body: @escaping () -> Void) -> Bool { scheduleWork(on: worker, body) }

  @discardableResult private func mailboxWork(_ body: @escaping () -> Void) -> Bool { scheduleWork(on: mailboxWorker, body) }

  private func scheduleWork(on queue: DispatchQueue, _ body: @escaping () -> Void) -> Bool {
    let admitted = owned {
      guard outstandingWork < 32 else {
        if joining?.committed != true { failJoining(.folderUnavailable) }
        endTrusted(persist: false)
        return false
      }
      outstandingWork += 1
      return true
    }
    guard admitted else { return false }
    queue.async { [self] in
      body()
      admission.async { self.outstandingWork -= 1 }
    }
    return true
  }

  private func makeSession(_ role: PairingFormat.Role, cid: String) throws -> PairingSession {
    let cidBytes = try PairingFormat.cid(cid)
    var environment = configuration.environment
    environment.sessionGeneration = generation
    return try PairingSession(role: role, cid: cidBytes, environment: environment, localName: configuration.localName, clock: clock, random: random, restoration: accounting.map { .restored($0) } ?? restoration)
  }

  func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    owned {
      let next = Control(self, cid, onState)
      if joining?.committed == true {
        next.owner = nil
        Task { @MainActor in onState(.failed(.invalidPeer)) }
        return next
      }
      if let previous = control {
        guard cancel(previous) != .unavailable else {
          next.owner = nil
          Task { @MainActor in onState(.failed(.folderUnavailable)) }
          return next
        }
        previous.owner = nil
      }
      control = next
      begin(next)
      return next
    }
  }

  func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool {
    owned {
      guard let slot = joining, slot.committed else { return false }
      slot.listeners.append(onState)
      emitCommitted(slot, slot.initialized && slot.ready ? .installed : .approved, listeners: [onState])
      return true
    }
  }

  private func emitCommitted(_ slot: Joining, _ state: PairingJoinState, listeners: [@MainActor (PairingJoinState) -> Void]? = nil) {
    if listeners == nil { emit(slot.control, state) }
    let callbacks = listeners ?? slot.listeners
    for callback in callbacks {
      DispatchQueue.main.async { [weak self, weak slot] in
        guard let self, let slot, self.owned({ self.joining === slot && slot.committed }) else { return }
        MainActor.assumeIsolated { callback(state) }
      }
    }
  }

  private func begin(_ control: Control) {
    guard self.control === control, control.owner === self else { return }
    guard generation < UInt64.max else { emit(control, .failed(.invalidPeer)); return }
    generation += 1
    control.generation = generation
    control.remember(.cancelled)
    emit(control, .preparing)
    do {
      guard let binding, configuration.environment.eligible, control.cid == configuration.cid else { throw Failure.unavailable }
      let session = try makeSession(.joining, cid: control.cid)
      let output = try session.startJoining(createdMs: wall())
      let slot = Joining(control, session, binding)
      joining = slot
      nextPoll = clock()
      let observedNow = clock()
      let deadline = session.deadline ?? observedNow
      let remaining = deadline > observedNow ? min(300000, deadline - observedNow) : 0
      emit(control, .waiting(expires: ContinuousClock.now.advanced(by: .milliseconds(Int64(remaining)))))
      process(output, session: session)
    } catch { failJoining(.invalidPeer) }
  }

  private func restart(_ value: Control) {
    owned {
      guard control === value, value.owner === self, joining?.committed != true else { return }
      if let slot = joining, slot.installation != nil {
        guard cancel(value) == .cancelled else { return }
      } else {
        if let slot = joining { _ = try? slot.session.end(reason: .cancel); cleanup(slot.session) }
        joining = nil
      }
      begin(value)
    }
  }

  @discardableResult private func cancel(_ value: Control) -> PairingCancelResult {
    owned {
      guard control === value, value.owner === self else { return .cancelled }
      guard joining?.committed != true else { return .alreadyCommitted }
      let slot = joining
      if let slot, let installation = slot.installation {
        slot.cancelRequested = true
        value.remember(.unavailable)
        do {
          try store.cancelInstallation(installation)
          guard try store.installationDecision(for: installation) == .init(installation: installation, disposition: .cancelled) else { throw Failure.unavailable }
        } catch {
          emit(value, .failed(.folderUnavailable))
          return .unavailable
        }
      }
      let deadline = slot?.session.deadline
      let output = try? slot?.session.end(reason: .cancel)
      if let slot { cleanup(slot.session) }
      joining = nil
      if generation < UInt64.max { generation += 1 }
      value.generation = generation
      if let slot, let output {
        for entry in output.writes { publishTerminal(entry, session: slot.session, deadline: deadline, binding: slot.binding) }
      }
      value.remember(.cancelled)
      emit(value, .failed(.cancelled))
      return .cancelled
    }
  }

  private static func displayCode(_ value: String) -> String {
    String(value.prefix(3)) + " " + String(value.suffix(3))
  }

  private func emit(_ value: Control, _ state: PairingJoinState) {
    let captured = value.generation
    DispatchQueue.main.async { [weak self, weak value] in
      guard let self, let value else { return }
      let current = self.owned { self.control === value && value.owner === self && value.generation == captured }
      guard current else { return }
      MainActor.assumeIsolated { value.callback(state) }
    }
  }

  func armTrusted(override: Bool = false) throws -> PairingTrustedHandle {
    try owned {
      guard trusted == nil else { throw Failure.occupied }
      guard let binding, configuration.environment.eligible, let entropy = configuration.entropy, entropy.count == 32, SyncKeys(entropy: entropy).chainTag == configuration.cid, let device = configuration.trustedDevice, device.count == 16, device.contains(where: { $0 != 0 }) else { throw Failure.unavailable }
      guard generation < UInt64.max else { throw Failure.unavailable }
      generation += 1
      let session = try makeSession(.trusted, cid: configuration.cid)
      _ = try session.arm(override: override)
      let slot = Trusted(session, binding)
      trusted = slot
      nextPoll = clock()
      let checkpoint = try session.checkpointAccounting()
      accounting = checkpoint
      work { [weak self, weak slot] in
        guard let self, let slot else { return }
        do {
          let saved = try self.store.persistAccounting(checkpoint)
          try self.store.setSuppressed(false)
          self.admission.async {
            guard self.trusted === slot, saved == checkpoint, self.live(session) else { return }
            slot.ready = true
            self.pollOwned(force: true)
          }
        } catch { self.admission.async { if self.trusted === slot { self.endTrusted() } } }
      }
      return slot.handle
    }
  }

  private func trustedSlot(_ handle: PairingTrustedHandle) throws -> Trusted {
    guard let slot = trusted, slot.handle === handle, slot.ready, live(slot.session) else { throw Failure.stale }
    return slot
  }

  func requests(_ handle: PairingTrustedHandle) throws -> [PairingRequestHandle] {
    try owned { try trustedSlot(handle).session.descriptors.map { PairingRequestHandle(handle, $0) } }
  }

  func pin(_ request: PairingRequestHandle, handle: PairingTrustedHandle) throws {
    try owned {
      let slot = try trustedSlot(handle)
      guard request.owner === handle else { throw Failure.stale }
      process(try slot.session.pin(request.descriptor, handle: slot.session.handle, armGeneration: slot.session.armGeneration, createdMs: wall()), session: slot.session)
    }
  }

  func comparison(_ handle: PairingTrustedHandle) throws -> PairingComparisonHandle {
    try owned {
      let session = try trustedSlot(handle).session
      guard let code = session.code, let name = session.peerName else { throw Failure.stale }
      return PairingComparisonHandle(owner: handle, generation: session.comparisonGeneration, code: Self.displayCode(code), claimedName: name)
    }
  }

  func present(_ handle: PairingTrustedHandle) throws {
    try owned {
      let slot = try trustedSlot(handle)
      guard !slot.authenticating else { throw Failure.occupied }
      _ = try slot.session.present(handle: slot.session.handle, armGeneration: slot.session.armGeneration)
    }
  }

  func deny(_ handle: PairingTrustedHandle) throws {
    try owned { _ = try trustedSlot(handle); endTrusted(reason: .deny, notifyPeer: true) }
  }

  func dismissUnsolicited() {
    owned {
      endTrusted(reason: .deny, notifyPeer: true)
      work { [store] in try? store.setSuppressed(true) }
    }
  }

  func acknowledgeComparison(_ comparison: PairingComparisonHandle) throws {
    try owned {
      let session = try trustedSlot(comparison.owner).session
      _ = try session.acknowledgeComparison(handle: session.handle, generation: comparison.generation)
    }
  }

  func hide(_ handle: PairingTrustedHandle) throws {
    try owned {
      let slot = try trustedSlot(handle)
      slot.authentication?.cancel()
      if slot.authenticating { endTrusted() }
      else { _ = try slot.session.hide() }
    }
  }

  func allow(_ handle: PairingTrustedHandle) throws {
    try owned {
      let slot = try trustedSlot(handle)
      guard !slot.authenticating else { throw Failure.occupied }
      let tuple = try slot.session.authorization()
      slot.authenticating = true
      slot.authentication = authenticator.authenticate(tuple, validate: { [weak self, weak slot] value in
        guard let self, let slot else { return false }
        return self.owned { self.trusted === slot && slot.authenticating && self.valid(value, slot) }
      }, completion: { [weak self, weak slot] capability in
        guard let self, let slot else { return }
        self.admission.async {
          guard self.trusted === slot, slot.authenticating else { return }
          guard let capability, self.valid(tuple, slot) else { self.endTrusted(); return }
          do { try self.prepareApproval(slot, tuple: tuple, capability: capability) }
          catch { self.endTrusted() }
        }
      })
    }
  }

  private func valid(_ tuple: PairingSession.Authorization, _ slot: Trusted) -> Bool {
    guard trusted === slot, configuration.environment.eligible, live(slot.session), let entropy = configuration.entropy, SyncKeys(entropy: entropy).chainTag == configuration.cid else { return false }
    return (try? slot.session.validateAuthorization(tuple)) != nil
  }

  private func prepareApproval(_ slot: Trusted, tuple: PairingSession.Authorization, capability: OwnerAuthentication) throws {
    guard let context = slot.session.cryptoContext, let entropy = configuration.entropy, let device = configuration.trustedDevice else { throw Failure.stale }
    let (requestHeader, request, offerHeader, offer) = try PairingCrypto.context(request: context.request, offer: context.offer)
    let payload = PairingCrypto.Approval(entropy: entropy, cid: requestHeader.cid, rid: requestHeader.rid, aid: offerHeader.aid, joiningSession: request.session, trustedDevice: device, transcript: context.keys.transcript, approvedMs: wall(), expiresMs: offer.expiresMs)
    let wire = try PairingCrypto.sealApproval(payload, keys: context.keys, rng: random)
    let entry = PairingSession.Entry(rid: tuple.rid, aid: tuple.aid, kind: .approval, wire: wire)
    track(entry, session: slot.session)
    let record = PairingConsumedApproval(cid: tuple.cid, rid: tuple.rid, aid: tuple.aid, transcript: tuple.transcript, epoch: configuration.environment.clockEpoch, time: clock(), sealedApproval: wire)
    work { [weak self, weak slot] in
      guard let self, let slot else { return }
      do {
        try self.store.consumeApproval(record)
        self.mailboxWork {
          do {
            _ = try slot.binding.mailbox.publish(entry) {
              self.owned {
                guard self.valid(tuple, slot), let current = self.configuration.entropy, PairingCrypto.equal(current, entropy) else { return false }
                do {
                  _ = try slot.session.commitApproval(wire: wire, ownerAuthentication: capability)
                  slot.retry = entry
                  return true
                } catch { return false }
              }
            }
          } catch {
            self.admission.async {
              if self.trusted === slot, slot.session.phase != .released { self.endTrusted() }
            }
          }
        }
      } catch {
        self.admission.async {
          guard self.trusted === slot else { return }
          if slot.session.phase != .released { self.endTrusted() }
        }
      }
    }
  }

  func retryApproval(_ handle: PairingTrustedHandle) throws {
    try owned {
      let slot = try trustedSlot(handle)
      guard let entry = slot.retry, slot.session.phase == .released else { throw Failure.stale }
      publish(entry, session: slot.session)
    }
  }

  func invalidate(reason: InvalidationReason) {
    owned {
      configuration.environment.eligible = false
      if generation < UInt64.max { generation += 1 }
      if let slot = joining, !slot.committed { slot.invalidated = true }
      if let value = control, joining?.committed != true { cancel(value) }
      endTrusted(persist: false)
    }
  }

  func update(configuration: Configuration, mailbox: PairingCoordinatingMailbox? = nil) {
    owned {
      invalidate(reason: .folder)
      let selected = mailbox ?? binding?.mailbox
      self.configuration = configuration
      binding = selected.flatMap { try? Self.bind(configuration, mailbox: $0, store: store) }
      if binding == nil { self.configuration.environment.eligible = false }
    }
  }

  private func endTrusted(persist: Bool = true, reason: PairingSession.EndReason = .invalidated, notifyPeer: Bool = false) {
    guard let slot = trusted else { return }
    slot.authentication?.cancel()
    let deadline = slot.session.deadline
    let output = try? slot.session.end(reason: reason)
    cleanup(slot.session)
    trusted = nil
    if persist, let checkpoint = try? slot.session.checkpointAccounting() {
      accounting = checkpoint
      work { [store] in _ = try? store.persistAccounting(checkpoint) }
    } else { accounting = slot.session.accounting }
    if notifyPeer, let output {
      for entry in output.writes { publishTerminal(entry, session: slot.session, deadline: deadline, binding: slot.binding) }
    }
  }

  private func failJoining(_ failure: PairingJoinFailure) {
    guard let value = control, joining?.committed != true else { return }
    if let slot = joining, slot.admissionUncertain || slot.cancelRequested {
      emit(value, .failed(.folderUnavailable))
      return
    }
    if let slot = joining { _ = try? slot.session.end(reason: .invalidated); cleanup(slot.session) }
    joining = nil
    value.remember(.cancelled)
    emit(value, .failed(failure))
  }

  private func live(_ session: PairingSession) -> Bool {
    guard configuration.environment.eligible else { return false }
    if let slot = joining, slot.session === session, slot.cancelRequested || slot.admissionUncertain { return false }
    if let result = try? session.tick(), !result.events.isEmpty { process(result, session: session) }
    return current(session) && session.phase != .idle && session.phase != .ended
  }

  private func current(_ session: PairingSession) -> Bool {
    joining?.session === session || trusted?.session === session
  }

  private func track(_ entry: PairingSession.Entry, session: PairingSession) {
    let key = ObjectIdentifier(session)
    if ownedPackets[key]?.contains(entry) != true { ownedPackets[key, default: []].append(entry) }
  }

  private func cleanup(_ session: PairingSession, grace: UInt64 = 0) {
    guard let entries = ownedPackets.removeValue(forKey: ObjectIdentifier(session)), !entries.isEmpty else { return }
    guard let binding = transport(session) else { return }
    cleanup(entries: entries, grace: grace, binding: binding)
  }

  private func cleanup(entries: [PairingSession.Entry], grace: UInt64, binding: Binding) {
    if grace == 0 { mailboxWork { binding.mailbox.remove(expected: entries) } }
    else {
      let (deadline, overflow) = clock().addingReportingOverflow(grace)
      cleanupGrace.append((overflow ? UInt64.max : deadline, entries, binding))
    }
  }

  private func publishTerminal(_ entry: PairingSession.Entry, session: PairingSession, deadline: UInt64?, binding: Binding) {
    guard entry.kind == .joiningTerminal || entry.kind == .trustedTerminal else { return }
    let capturedGeneration = generation
    let environment = configuration.environment
    let revision = session.accounting.revision
    mailboxWork { [weak self] in
      guard let self else { return }
      do {
        _ = try binding.mailbox.publish(entry) {
          self.owned {
            guard self.configuration.environment.eligible, self.configuration.environment == environment,
              self.generation == capturedGeneration, session.phase == .ended, session.accounting.revision == revision else { return false }
            if let deadline, self.clock() >= deadline { return false }
            return true
          }
        }
        self.admission.async { self.cleanup(entries: [entry], grace: 60000, binding: binding) }
      } catch { }
    }
  }

  private func cleanDuePackets() {
    let now = clock()
    let due = cleanupGrace.filter { now >= $0.deadline }
    cleanupGrace.removeAll { now >= $0.deadline }
    for item in due { mailboxWork { item.binding.mailbox.remove(expected: item.entries) } }
  }

  private func publish(_ entry: PairingSession.Entry, session: PairingSession) {
    guard let binding = transport(session) else { return }
    track(entry, session: session)
    let revision = session.accounting.revision
    let deadline = session.deadline
    mailboxWork { [weak self, weak session] in
      guard let self, let session else { return }
      do {
        _ = try binding.mailbox.publish(entry) {
          self.owned {
            if entry.kind == .receipt, let slot = self.joining, slot.session === session, slot.committed { return true }
            guard self.current(session), self.live(session), session.deadline == deadline, session.accounting.revision == revision else { return false }
            if let deadline, self.clock() >= deadline { return false }
            return true
          }
        }
        if entry.kind == .receipt { self.admission.async { self.cleanup(session, grace: 60000) } }
      } catch { }
    }
  }

  private func process(_ output: PairingSession.Output, session: PairingSession) {
    guard current(session) else { return }
    if let reservation = output.accounting {
      accounting = reservation
      work { [weak self, weak session] in
        guard let self, let session else { return }
        do {
          let saved = try self.store.persistAccounting(reservation)
          self.admission.async {
            guard self.current(session), self.live(session), saved == reservation else { return }
            do { self.process(try session.persistedAccounting(saved), session: session) }
            catch { if self.trusted?.session === session { self.endTrusted() } }
          }
        } catch { self.admission.async { if self.trusted?.session === session { self.endTrusted() } } }
      }
    }
    for entry in output.writes where entry.kind != .approval { publish(entry, session: session) }
    for event in output.events {
      switch event {
      case .comparisonReady:
        if let slot = joining, slot.session === session, let code = session.code, let name = session.peerName { emit(slot.control, .comparing(code: Self.displayCode(code), claimedName: name)) }
      case .approvalReceived(let candidate):
        if let slot = joining, slot.session === session { install(candidate, slot: slot) }
      case .ended(let reason):
        if joining?.session === session {
          let failure: PairingJoinFailure
          switch reason {
          case .expiry: failure = .expired
          case .deny: failure = .denied
          case .cancel: failure = .cancelled
          default: failure = .invalidPeer
          }
          failJoining(failure)
        }
        if trusted?.session === session { endTrusted() }
      default: break
      }
    }
  }

  func tick() { admission.async { [weak self] in self?.pollOwned() } }

  func poll() { admission.async { [weak self] in self?.pollOwned(force: true) } }

  private func pollOwned(force: Bool = false) {
    cleanDuePackets()
    for session in [joining?.session, trusted?.session].compactMap({ $0 }) {
      if let result = try? session.tick() { process(result, session: session) }
    }
    let activeJoining = joining.flatMap { $0.committed || $0.cancelRequested || $0.admissionUncertain ? nil : $0 }
    guard activeJoining != nil || trusted != nil else { return }
    let now = clock()
    guard force || now >= nextPoll else { return }
    if polling { pollDirty = true; return }
    let interval: UInt64 = joining != nil && joining?.committed != true ? 2000 : 5000
    let (next, overflow) = now.addingReportingOverflow(interval)
    nextPoll = overflow ? UInt64.max : next
    polling = true
    let capturedJ = activeJoining, capturedT = trusted
    guard let binding = capturedJ?.binding ?? capturedT?.binding else { polling = false; return }
    let rids = Set([capturedJ?.session, capturedT?.session].compactMap { $0?.cryptoContext }.compactMap { try? PairingFormat.decode($0.request).rid })
    let scheduled = mailboxWork { [weak self] in
      guard let self else { return }
      let result = Result { try binding.mailbox.poll(rids: rids) }
      self.admission.async {
        self.polling = false
        defer {
          if self.pollDirty { self.pollDirty = false; self.pollOwned(force: true) }
        }
        guard case .success(let entries) = result else {
          if let slot = capturedJ, self.joining === slot { self.failJoining(.folderUnavailable) }
          if let slot = capturedT, self.trusted === slot { self.endTrusted() }
          return
        }
        var budget = PairingMailbox.bytesPerPass
        for entry in entries.prefix(PairingMailbox.entriesPerPass) {
          guard entry.wire.count <= budget else { break }
          budget -= entry.wire.count
          if let slot = capturedT, self.trusted === slot, slot.ready, [.request, .select, .confirm, .joiningName, .receipt, .joiningTerminal].contains(entry.kind), let output = try? slot.session.receive(entry) { self.process(output, session: slot.session) }
          if let slot = capturedJ, self.joining === slot, !slot.committed, !slot.cancelRequested, !slot.admissionUncertain, [.offer, .reveal, .trustedName, .approval, .trustedTerminal].contains(entry.kind), let output = try? slot.session.receive(entry) { self.process(output, session: slot.session) }
        }
        if let slot = capturedJ, self.joining === slot, slot.session.phase == .requestLive, slot.session.offers.count == 1, let offer = slot.session.offers.first, let output = try? slot.session.selectOffer(offer, handle: slot.session.handle) { self.process(output, session: slot.session) }
      }
    }
    if !scheduled { polling = false; pollDirty = false }
  }

  private func install(_ candidate: PairingSession.ValidatedApprovalCandidate, slot: Joining) {
    guard !slot.installing, live(slot.session), let context = slot.session.cryptoContext, let device = context.joiningDevice else { return }
    do {
      let (requestHeader, request, offerHeader, offer) = try PairingCrypto.context(request: context.request, offer: context.offer)
      let payload = candidate.payload
      guard payload.entropy.count == 32, SyncKeys(entropy: payload.entropy).chainTag == configuration.cid,
        payload.cid == requestHeader.cid, payload.rid == requestHeader.rid, payload.aid == offerHeader.aid,
        payload.joiningSession == request.session, payload.expiresMs == offer.expiresMs,
        payload.transcript == context.keys.transcript, device.count == 16, device.contains(where: { $0 != 0 }),
        payload.trustedDevice.count == 16, payload.trustedDevice.contains(where: { $0 != 0 }) else { throw Failure.stale }
      slot.installing = true
      let installation = PairingInstallation(transaction: payload.transcript, cid: configuration.cid, device: Base32.encode(device), folderIdentity: configuration.environment.folderIdentity, generation: slot.generation)
      slot.installation = installation
      slot.control.remember(.unavailable)
      work { [weak self, weak slot] in
        guard let self, let slot else { return }
        self.host.prepare(installation) { prepared in
          self.admission.async {
            guard self.joining === slot, !slot.invalidated, !slot.prepareCompleted, self.live(slot.session), slot.control.generation == slot.generation else { return }
            slot.prepareCompleted = true
            guard prepared else { self.failJoining(.invalidPeer); return }
            self.saveKey(candidate, installation: installation, slot: slot)
          }
        }
      }
    } catch { failJoining(.invalidPeer) }
  }

  private func validateWrite(_ candidate: PairingSession.ValidatedApprovalCandidate, installation: PairingInstallation, slot: Joining) -> Bool {
    guard joining === slot, !slot.invalidated, !slot.committed, !slot.cancelRequested, !slot.admissionUncertain, slot.control.generation == slot.generation,
      slot.installation == installation, binding === slot.binding,
      configuration.environment.eligible, configuration.cid == slot.binding.cid,
      configuration.environment.folderIdentity == slot.binding.folderIdentity,
      configuration.environment.folderGeneration == slot.session.environment.folderGeneration,
      configuration.environment.entropyGeneration == slot.session.environment.entropyGeneration,
      configuration.environment.entropyHandle == slot.session.environment.entropyHandle,
      configuration.environment.clockEpoch == slot.session.environment.clockEpoch,
      live(slot.session) else { return false }
    return (try? slot.session.validateInstall(candidate)) != nil
  }

  private func saveKey(_ candidate: PairingSession.ValidatedApprovalCandidate, installation: PairingInstallation, slot: Joining) {
    let entropy = candidate.payload.entropy
    work { [weak self, weak slot] in
      guard let self, let slot else { return }
      let allowed = self.owned { self.validateWrite(candidate, installation: installation, slot: slot) }
      guard allowed else { return }
      let saved: Bool
      switch self.keyStore.pairingLookup(account: installation.device) {
      case .absent:
        let started = self.owned {
          guard self.validateWrite(candidate, installation: installation, slot: slot), !slot.writeStarted else { return false }
          slot.writeStarted = true
          return true
        }
        guard started else { return }
        saved = self.keyStore.pairingInsert(entropy, account: installation.device)
      case .found: saved = false
      case .failure: saved = false
      }
      let matches: Bool
      if saved, case .found(let value) = self.keyStore.pairingLookup(account: installation.device) {
        matches = value.count == 32 && PairingCrypto.equal(entropy, value) && SyncKeys(entropy: value).chainTag == installation.cid
      } else { matches = false }
      self.admission.async {
        guard self.joining === slot, !slot.invalidated, !slot.committed, slot.control.generation == slot.generation, self.live(slot.session) else { return }
        guard matches else { self.failJoining(.invalidPeer); return }
        guard self.validateWrite(candidate, installation: installation, slot: slot) else { return }
        do {
          _ = try slot.session.commitInstall(coordinatorValidatedRootCIDSessionAndDevice: candidate)
          let decision = PairingInstallationDecision(installation: installation, disposition: .admitted)
          guard try self.store.persistInstallationDecision(decision) == decision,
            try self.store.installationDecision(for: installation) == decision else { throw Failure.unavailable }
        } catch {
          slot.admissionUncertain = true
          self.emit(slot.control, .failed(.folderUnavailable))
          return
        }
        slot.committed = true
        slot.control.remember(.alreadyCommitted)
        self.emitCommitted(slot, .approved)
        self.worker.async {
          self.host.keySaved(installation, initialized: { initialized in
            self.admission.async {
              guard self.joining === slot, !slot.invalidated, slot.committed, initialized, !slot.initialized else { return }
              slot.initialized = true
              if let output = try? slot.session.installed() { self.process(output, session: slot.session) }
              if slot.ready { self.emitCommitted(slot, .installed) }
            }
          }, ready: { ready in
            self.admission.async {
              guard self.joining === slot, !slot.invalidated, slot.committed, ready, !slot.ready else { return }
              slot.ready = true
              if slot.initialized { self.emitCommitted(slot, .installed) }
            }
          })
        }
      }
    }
  }
}

extension PairingMailbox: PairingCoordinatingMailbox {
  var pairingCID: String { cid }
  var pairingFolder: URL { folder }
  var pairingFolderIdentity: Data { folderIdentity }
  func poll(rids: Set<Data>) throws -> [PairingSession.Entry] {
    let listing = poll(rids: Array(rids))
    guard !listing.unavailable else { throw PairingMailbox.Failure.folder }
    return listing.entries.compactMap { entry in
      guard let kind = PairingSession.Kind(rawValue: entry.kind.rawValue) else { return nil }
      return PairingSession.Entry(rid: entry.rid, aid: entry.aid, kind: kind, wire: entry.wire)
    }
  }
}
