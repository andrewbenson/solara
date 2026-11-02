import AppKit
import CoreGraphics
import Darwin
import Foundation

public final class PairingNativeArm: CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  fileprivate let handle: PairingTrustedHandle
  public let deadline: TimeInterval
  fileprivate init(_ handle: PairingTrustedHandle, deadline: TimeInterval) { self.handle = handle; self.deadline = deadline }
}

public final class PairingNativeRequest: CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  fileprivate let descriptor: PairingSession.Descriptor
  fileprivate let cid: String
  public var chainSuffix: String { String(cid.suffix(6)) }
  public var requestSuffix: String { String(Base32.encode(descriptor.rid).suffix(6)) }
  public var sessionSuffix: String {
    guard let message = try? PairingFormat.decode(descriptor.wire), case .request(let request) = message.body else { return "" }
    return String(Base32.encode(request.session).suffix(6))
  }
  public var firstObserved: TimeInterval { Double(descriptor.firstSeen) / 1000 }
  fileprivate init(_ descriptor: PairingSession.Descriptor, cid: String) { self.descriptor = descriptor; self.cid = cid }
}

public final class PairingNativeComparison: CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  public var description: String { "<native pairing comparison>" }
  public var debugDescription: String { description }
  fileprivate let handle: PairingComparisonHandle
  public var code: String { handle.code }
  public var claimedName: String { handle.claimedName }
  fileprivate init(_ handle: PairingComparisonHandle) { self.handle = handle }
}

public struct PairingNativeTrustedSnapshot: CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  public let eligible: Bool
  public let markerVerified: Bool
  public let suppressed: Bool
  public let requests: [PairingNativeRequest]
  public let phase: String
  public let comparison: PairingNativeComparison?
}

public final class PairingServices: PairingJoining, CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
  public static let shared = PairingServices()
  private let lock = NSRecursiveLock()
  private let replacementLock = NSRecursiveLock()
  private let worker = DispatchQueue(label: "solara.sync.pairing.service", qos: .utility)
  private(set) var coordinator: PairingCoordinator?
  private(set) var installationHost: PairingInstallationHost?
  private var hostFolderIdentity: Data?
  private var accountingStore: PairingDurableStore?
  private let installationRouter = PairingInstallationRouter()
  private var attached = false
  private var pendingStops = 0
  private var localStop: (([String: Any]?, UInt64?) throws -> Void)?
  private var committedObserverGeneration: UInt64 = 0
  private var cachedCommitted: PairingJoinState?
  private var cachedOnboardingToken: String?
  private var replacementGeneration: UInt64 = 0
  private var committedListeners: [@MainActor (PairingJoinState) -> Void] = []
  private var healthy: (() -> Bool)?
  private var projection: (([String: Any], [String: Any]) throws -> Any)?
  private var storeRevision: (() -> Int?)?
  private var bootstrap: (() -> Void)?
  private var refreshPending = false
  private var eligible = false
  private var markerVerified = false
  private var stopped = false
  private var lockKnown = false
  private var unlocked = false
  private var revision: UInt64 = 0
  private var folderGeneration: UInt64 = 1
  private var keyGeneration: UInt64 = 1
  private var context: PairingCoordinator.Configuration?
  private var selectedFolder: URL?
  private var selectedCID: String?
  private var requestObjects: [Data: PairingNativeRequest] = [:]
  private var observers: [NSObjectProtocol] = []
  private var presenter: PairingFolderPresenter?
  private var timer: DispatchSourceTimer?
  var onRequest: (() -> Void)?
  var onKeyAvailable: ((String, Data) -> Void)?

  private let sessionDictionary: () -> [String: Any]?

  init(sessionDictionary: @escaping () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }) { self.sessionDictionary = sessionDictionary }

  #if DEBUG
  public var backendReady: Bool {
    lock.lock()
    defer { lock.unlock() }
    return coordinator != nil && healthy != nil && storeRevision != nil && projection != nil
  }
  #endif

  func register(_ coordinator: PairingCoordinator) {
    lock.lock()
    defer { lock.unlock() }
    if self.coordinator == nil { self.coordinator = coordinator }
  }

  public func registerStore(healthy: @escaping () -> Bool, revision: @escaping () -> Int?, projection: @escaping ([String: Any], [String: Any]) throws -> Any) {
    lock.lock()
    self.healthy = healthy
    storeRevision = revision
    self.projection = projection
    installationHost?.projection = projection
    installationHost?.revision = revision
    lock.unlock()
    refresh()
  }

  public func moduleAttached() {
    lock.lock()
    let reload = attached
    attached = true
    lock.unlock()
    if reload { invalidate("reload") }
    refresh()
  }

  public var committedOnboardingJoinToken: String? {
    lock.lock(); defer { lock.unlock() }; return cachedOnboardingToken
  }

  public func invalidate(_ reason: String) {
    lock.lock()
    revision &+= 1
    eligible = false
    markerVerified = false
    context = nil
    requestObjects.removeAll()
    if reason == "stop" || reason == "forget" || reason == "rekey" {
      stopped = true
      committedObserverGeneration &+= 1
      cachedCommitted = nil
      cachedOnboardingToken = nil
      committedListeners.removeAll()
      pendingStops += 1
      selectedCID = nil
    }
    if reason == "folder" { folderGeneration &+= 1; selectedFolder = nil; selectedCID = nil }
    if reason == "forget" || reason == "rekey" { keyGeneration &+= 1 }
    let coordinator = coordinator
    lock.unlock()
    let mapped: PairingCoordinator.InvalidationReason
    switch reason {
    case "lock": mapped = .lock
    case "folder": mapped = .folder
    case "forget", "rekey": mapped = .key
    case "shutdown": mapped = .shutdown
    case "reload": mapped = .surface
    default: mapped = .stop
    }
    coordinator?.invalidate(reason: mapped)
    if reason == "shutdown" {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.timer?.cancel(); self.timer = nil
        if let presenter = self.presenter { NSFileCoordinator.removeFilePresenter(presenter); self.presenter = nil }
        for observer in self.observers { NotificationCenter.default.removeObserver(observer); DistributedNotificationCenter.default().removeObserver(observer) }
        self.observers.removeAll()
      }
    }
    if reason == "stop" || reason == "forget" || reason == "rekey" {
      worker.async { [weak self] in self?.persistPendingStops() }
    }
  }

  private func persistPendingStops() {
    lock.lock()
    guard pendingStops > 0 else { lock.unlock(); return }
    lock.unlock()
    do { try completeStop(nil, stopGeneration: nil) } catch { }
  }

  func stopInstallation(_ dto: [String: Any]?, stopGeneration: UInt64) throws {
    try worker.sync { try completeStop(dto, stopGeneration: stopGeneration) }
  }

  private func completeStop(_ dto: [String: Any]?, stopGeneration: UInt64?) throws {
    lock.lock()
    guard let localStop else { lock.unlock(); throw PairingInstallationHost.Failure.unavailable }
    let count = pendingStops
    let host = installationHost
    lock.unlock()
    try localStop(dto, stopGeneration)
    host?.finishStop()
    coordinator?.finishStop()
    lock.lock()
    pendingStops -= count
    cachedCommitted = nil
    committedListeners.removeAll()
    lock.unlock()
  }

  public func selectFolder(_ path: String) {
    invalidate("folder")
    lock.lock()
    selectedFolder = URL(fileURLWithPath: path, isDirectory: true)
    lock.unlock()
    refresh()
  }

  func bootstrap(dataDirectory: URL, defaultFolder: URL, keys: PairingInstallationKeyStoring, safeMode: @escaping () -> Bool) {
    lock.lock()
    guard bootstrap == nil else { lock.unlock(); return }
    localStop = { dto, generation in try PairingInstallationHost.stopInstallation(dataDirectory: dataDirectory, dto, stopGeneration: generation) }
    bootstrap = { [weak self] in self?.configure(dataDirectory: dataDirectory, defaultFolder: defaultFolder, keys: keys, safeMode: safeMode) }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in self?.installLifecycle() }
    refresh()
  }

  func refresh() {
    lock.lock()
    guard !refreshPending, let bootstrap else { lock.unlock(); return }
    refreshPending = true
    lock.unlock()
    worker.async { [weak self] in
      bootstrap()
      self?.lock.lock()
      self?.refreshPending = false
      self?.lock.unlock()
    }
  }

  private func configure(dataDirectory: URL, defaultFolder: URL, keys: PairingInstallationKeyStoring, safeMode: @escaping () -> Bool) {
    persistPendingStops()
    let ownerEpoch = coordinator?.configurationEpoch
    lock.lock()
    let captured = revision
    let chosenFolder = selectedFolder
    let chosenCID = selectedCID
    let nativeHealthy = healthy?() == true
    let unlocked = lockKnown && self.unlocked
    let stopped = stopped
    let folderGeneration = folderGeneration
    let keyGeneration = keyGeneration
    lock.unlock()
    do {
      let sample = try PairingBootClock.sample()
      let documentURL = dataDirectory.appendingPathComponent("sync.json")
      var info = stat()
      let bytes: Data?
      if lstat(documentURL.path, &info) == 0 {
        bytes = try PairingPOSIXDurableIO().read(documentURL, limit: 4 * 1024 * 1024)
      } else if errno == ENOENT { bytes = nil }
      else { throw PairingCoordinator.Failure.unavailable }
      let document = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let version = document?["v"] as? Int
      guard bytes == nil || version == 1 || version == 2 else { throw PairingCoordinator.Failure.unavailable }
      let committed = try PairingInstallationHost.committedTarget(dataDirectory: dataDirectory, keys: keys)
      if let committed {
        lock.lock()
        if revision == captured && !stopped {
          if cachedCommitted != .installed { cachedCommitted = .approved }
          cachedOnboardingToken = committed.onboardingToken
        }
        lock.unlock()
      }
      let folder = committed?.folder ?? chosenFolder ?? (document?["folder"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
      let account = document?["deviceId"] as? String
      let keyState: PairingKeyLookup?
      if !safeMode(), let account, (try? PairingFormat.cid(account)) != nil { keyState = keys.pairingLookup(account: account) }
      else { keyState = account == nil ? nil : .failure }
      let entropy: Data?
      if case .found(let value) = keyState { entropy = value }
      else { entropy = nil }
      let enabled = document?["enabled"] as? Bool == true
      let rootCID = entropy.map { SyncKeys(entropy: $0).chainTag }
      let cid = committed?.installation.cid ?? (enabled ? rootCID : chosenCID) ?? rootCID ?? Base32.encode(Data(repeating: 1, count: 16))
      let mailbox = try PairingMailbox(folder: folder, cid: cid)
      if let committed { guard mailbox.folderIdentity == committed.installation.folderIdentity else { throw PairingCoordinator.Failure.unavailable } }
      let accounting: PairingDurableStore
      if let existing = accountingStore { accounting = existing }
      else {
        let evidence = try Self.firstInstallationEvidence(dataDirectory: dataDirectory, syncState: .success(bytes), version: version, keyState: keyState)
        accounting = try PairingDurableStore(dataDirectory: dataDirectory, syncFolder: folder, firstInstallation: evidence)
        accountingStore = accounting
      }
      let hostChanged = hostFolderIdentity != mailbox.folderIdentity
      if hostChanged {
        let host = PairingInstallationHost(dataDirectory: dataDirectory, folder: folder, folderIdentity: mailbox.folderIdentity, keys: keys, accounting: accounting)
        lock.lock()
        host.projection = projection
        host.revision = storeRevision
        host.onRequest = { [weak self] in self?.refresh(); self?.onRequest?() }
        host.onKeyAvailable = { [weak self] account, data in self?.onKeyAvailable?(account, data) }
        host.onState = { [weak self, weak host] state in
          guard let self, let host else { return }
          let token = host.committedOnboardingToken()
          self.lock.lock()
          guard self.installationHost === host, !self.stopped else { self.lock.unlock(); return }
          self.cachedCommitted = state
          self.cachedOnboardingToken = self.stopped ? nil : token
          let listeners = self.committedListeners
          self.lock.unlock()
          for listener in listeners { DispatchQueue.main.async { MainActor.assumeIsolated { listener(state) } } }
        }
        installationHost = host
        hostFolderIdentity = mailbox.folderIdentity
        lock.unlock()
        installationRouter.register(host, folderIdentity: mailbox.folderIdentity)
      }
      guard let host = installationHost else { throw PairingCoordinator.Failure.unavailable }
      var trusted = enabled && entropy?.count == 32 && account.flatMap { try? PairingFormat.cid($0) } != nil
      if trusted {
        let chain = open(folder.appendingPathComponent(cid, isDirectory: true).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if chain >= 0 { close(chain) } else { trusted = false }
      }
      if version == 2, enabled {
        guard try host.recoverInstallation() != nil else { throw PairingCoordinator.Failure.unavailable }
        let phase = (document?["bootstrap"] as? [String: Any])?["phase"] as? String
        trusted = trusted && ["ready", "onboarding-completed"].contains(phase ?? "")
      }
      let committedState = host.committedState()
      if committed != nil { guard committedState != nil else { throw PairingCoordinator.Failure.unavailable } }
      let onboardingToken = host.committedOnboardingToken()
      let mayJoin = !enabled && !stopped && committed == nil
      let allowed = nativeHealthy && unlocked && !safeMode() && !stopped && (mayJoin || trusted)
      let configuration = PairingCoordinator.Configuration(cid: cid, environment: .init(folderIdentity: mailbox.folderIdentity, folderGeneration: folderGeneration, entropyHandle: account.map { Data($0.utf8) }, entropyGeneration: keyGeneration, clockEpoch: sample.epoch, eligible: allowed), localName: Host.current().localizedName ?? "", entropy: trusted ? entropy : nil, trustedDevice: trusted ? account.flatMap { try? PairingFormat.cid($0) } : nil)
      lock.lock()
      guard revision == captured else { lock.unlock(); return }
      cachedCommitted = committedState
      cachedOnboardingToken = stopped ? nil : onboardingToken
      if let context, context.cid == configuration.cid, context.environment == configuration.environment, context.localName == configuration.localName, context.entropy == configuration.entropy, context.trustedDevice == configuration.trustedDevice {
        eligible = allowed
        markerVerified = trusted && allowed
        lock.unlock()
        return
      }
      lock.unlock()
      if coordinator == nil {
        guard keyState != .failure else { return }
        accounting.setFirstInstallationEvidence(try Self.firstInstallationEvidence(dataDirectory: dataDirectory, syncState: .success(bytes), version: version, keyState: keyState))
        let made = PairingCoordinator(configuration: configuration, mailbox: mailbox, store: accounting, authenticator: FreshPairingOwnerAuthenticator(), keyStore: keys, host: installationRouter, clock: { (try? PairingBootClock.sample().milliseconds) ?? UInt64.max }, wall: { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }, initialGeneration: host.minimumGeneration, eligibility: { [weak self] in self?.currentEligibility(safeMode: safeMode) == true })
        lock.lock()
        guard revision == captured else { lock.unlock(); return }
        register(made)
        lock.unlock()
      } else {
        coordinator?.reserveGeneration(above: host.minimumGeneration)
        guard coordinator?.update(configuration: configuration, mailbox: mailbox, expectedInvalidationEpoch: ownerEpoch) == true else { return }
      }
      persistPendingStops()
      lock.lock()
      guard revision == captured else { lock.unlock(); return }
      context = configuration
      eligible = allowed
      markerVerified = trusted && allowed
      lock.unlock()
      if hostChanged { onRequest?() }
      DispatchQueue.main.async { [weak self] in self?.watch(folder) }
    } catch { invalidate("health") }
  }

  static func firstInstallationEvidence(dataDirectory: URL, syncState: Result<Data?, Error>, version: Int?, keyState: PairingKeyLookup?) throws -> PairingFirstInstallationEvidence {
    let noPairingEraSyncState: Bool
    switch syncState {
    case .success(let bytes): noPairingEraSyncState = bytes == nil || version == 1
    case .failure: noPairingEraSyncState = false
    }
    let directory = dataDirectory.appendingPathComponent("Application Support/sync-pairing")
    let io = PairingPOSIXDurableIO()
    try io.prepare(directory)
    let names = try io.contents(directory)
    let noJoinOrStopMarker = !names.contains { $0 == "host-installation.json" || $0 == "host-stop.json" || $0.hasPrefix("host-history-") || $0.hasPrefix("installation-") || $0.hasPrefix("cancelled-") }
    return PairingFirstInstallationEvidence(noPairingEraSyncState: noPairingEraSyncState, noJoinOrStopMarker: noJoinOrStopMarker, keyStateKnown: keyState != .failure)
  }

  private func currentEligibility(safeMode: () -> Bool) -> Bool {
    lock.lock()
    let allowed = eligible && lockKnown && unlocked && !stopped
    let healthy = healthy
    lock.unlock()
    return allowed && healthy?() == true && !safeMode()
  }

  func keyActivated() {
    lock.lock(); stopped = false; selectedCID = nil; context = nil; lock.unlock()
    refresh()
  }

  private func installLifecycle() {
    guard observers.isEmpty else { return }
    let state = PairingScreenLockState.from(session: sessionDictionary())
    lock.lock()
    lockKnown = state != .unknown
    unlocked = state == .unlocked
    lock.unlock()
    let distributed = DistributedNotificationCenter.default()
    for (name, value) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
      observers.append(distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in
        guard let self else { return }
        self.invalidate("lock")
        self.lock.lock(); self.lockKnown = true; self.unlocked = value; self.lock.unlock()
        self.refresh()
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.invalidate("shutdown") })
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 5)
    timer.setEventHandler { [weak self] in self?.refresh() }
    self.timer = timer
    timer.resume()
    refresh()
  }

  private func watch(_ folder: URL) {
    guard presenter?.presentedItemURL != folder else { return }
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    let presenter = PairingFolderPresenter(folder) { [weak self] in self?.coordinator?.poll(); self?.refresh() }
    self.presenter = presenter
    NSFileCoordinator.addFilePresenter(presenter)
  }

  public func start(cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    start(folder: nil, cid: cid, onState: onState)
  }

  public func start(folder: String?, cid: String, onState: @escaping @MainActor (PairingJoinState) -> Void) -> PairingJoinHandle {
    replacementLock.lock()
    defer { replacementLock.unlock() }
    lock.lock()
    var folderChanged = false
    if let folder, selectedFolder?.path != folder {
      revision &+= 1
      folderGeneration &+= 1
      selectedFolder = URL(fileURLWithPath: folder, isDirectory: true)
      selectedCID = nil
      context = nil
      folderChanged = true
    }
    replacementGeneration &+= 1
    let generation = replacementGeneration
    let owner = coordinator
    lock.unlock()
    if folderChanged { owner?.invalidate(reason: .folder) }
    _ = owner?.reserveJoiningReplacement()
    let control = PairingDeferredJoin { [weak self] in
      guard let self else { return }
      self.replacementLock.lock()
      defer { self.replacementLock.unlock() }
      self.lock.lock()
      guard self.replacementGeneration == generation else { self.lock.unlock(); return }
      self.replacementGeneration &+= 1
      let currentOwner = self.coordinator
      self.lock.unlock()
      _ = currentOwner?.reserveJoiningReplacement()
    }
    worker.async { [weak self, weak control] in
      guard let self, let control else { return }
      self.lock.lock()
      guard self.replacementGeneration == generation else { self.lock.unlock(); return }
      self.selectedCID = cid
      let bootstrap = self.bootstrap
      self.lock.unlock()
      bootstrap?()
      self.replacementLock.lock()
      self.lock.lock()
      let current = self.replacementGeneration == generation
      let coordinator = self.coordinator
      self.lock.unlock()
      let installedEpoch = current ? coordinator?.reserveJoiningReplacement() : nil
      self.replacementLock.unlock()
      guard current else { return }
      control.install { coordinator?.start(cid: cid, expectedInvalidationEpoch: installedEpoch, onState: onState) }
      if coordinator == nil { DispatchQueue.main.async { MainActor.assumeIsolated { onState(.failed(.folderUnavailable)) } } }
    }
    return control
  }

  public func committedJoin(onState: @escaping @MainActor (PairingJoinState) -> Void) -> Bool {
    lock.lock()
    guard !stopped else { lock.unlock(); return false }
    let generation = committedObserverGeneration
    let coordinator = coordinator
    lock.unlock()
    let deliver: @MainActor (PairingJoinState) -> Void = { [weak self] state in
      guard let self else { return }
      self.lock.lock()
      let current = !self.stopped && self.committedObserverGeneration == generation
      self.lock.unlock()
      if current { onState(state) }
    }
    if coordinator?.committedJoin(onState: deliver) == true {
      lock.lock(); defer { lock.unlock() }
      return !stopped && committedObserverGeneration == generation
    }
    lock.lock()
    guard !stopped, committedObserverGeneration == generation, let state = cachedCommitted else { lock.unlock(); return false }
    committedListeners.append(deliver)
    DispatchQueue.main.async { MainActor.assumeIsolated { deliver(state) } }
    lock.unlock()
    return true
  }

  public func arm(override: Bool = false) throws -> PairingNativeArm {
    lock.lock()
    let allowed = eligible && markerVerified
    lock.unlock()
    guard allowed, let coordinator else { throw PairingCoordinator.Failure.unavailable }
    return try PairingNativeArm(coordinator.armTrusted(override: override), deadline: Double((try PairingBootClock.sample()).milliseconds + 120000) / 1000)
  }

  public func requests(_ arm: PairingNativeArm) throws -> [PairingNativeRequest] {
    guard let coordinator else { throw PairingCoordinator.Failure.unavailable }
    let requests = try coordinator.requests(arm.handle)
    lock.lock()
    defer { lock.unlock() }
    return requests.map { request in
      if let existing = requestObjects[request.descriptor.hash] { return existing }
      let value = PairingNativeRequest(request.descriptor, cid: context?.cid ?? "")
      requestObjects[request.descriptor.hash] = value
      return value
    }
  }

  public func select(_ request: PairingNativeRequest, arm: PairingNativeArm) throws {
    guard let coordinator, let exact = try coordinator.requests(arm.handle).first(where: { $0.descriptor.rid == request.descriptor.rid && $0.descriptor.wire == request.descriptor.wire && $0.descriptor.folderGeneration == request.descriptor.folderGeneration }) else { throw PairingCoordinator.Failure.stale }
    try coordinator.pin(exact, handle: arm.handle)
  }

  public func present(_ arm: PairingNativeArm) throws { try coordinator?.present(arm.handle) }
  public func panelLive(_ arm: PairingNativeArm) -> Bool { coordinator?.panelLive(arm.handle) == true }
  public func toleratesSoftLoss(_ arm: PairingNativeArm, foreground: Bool) -> Bool { coordinator?.toleratesSoftLoss(arm.handle, foreground: foreground) == true }
  public func hide(_ arm: PairingNativeArm) { try? coordinator?.hide(arm.handle) }
  public func comparison(_ arm: PairingNativeArm) throws -> PairingNativeComparison {
    guard let coordinator else { throw PairingCoordinator.Failure.unavailable }
    return try PairingNativeComparison(coordinator.comparison(arm.handle))
  }
  public func acknowledge(_ comparison: PairingNativeComparison) throws { try coordinator?.acknowledgeComparison(comparison.handle) }
  public func allow(_ arm: PairingNativeArm, observingSurfaceAtReply: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) }, validatingSurface: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) }) throws { try coordinator?.allow(arm.handle, observingSurfaceAtReply: observingSurfaceAtReply, validatingSurface: validatingSurface) }
  public func end(_ arm: PairingNativeArm?, unexpected: Bool = false) {
    if unexpected { coordinator?.dismissUnsolicited() }
    else if let arm { try? coordinator?.deny(arm.handle) }
  }
  public func trustedSnapshot(_ arm: PairingNativeArm?) -> PairingNativeTrustedSnapshot {
    let snapshot = coordinator?.snapshot
    let phase: String
    switch snapshot?.trustedPhase {
    case .armed: phase = "choosing"
    case .comparing: phase = "comparing"
    case .released: phase = "sentUnconfirmed"
    case .installed: phase = "confirmed"
    case .none, .idle, .ended: phase = "idle"
    default: phase = "preparing"
    }
    let quietDescriptors = coordinator?.quietRequests ?? []
    let suppressed = coordinator?.quietSuppressed ?? true
    let armedRequests = arm.flatMap { try? requests($0) }
    let currentComparison = arm.flatMap { try? comparison($0) }
    lock.lock()
    defer { lock.unlock() }
    let quiet = quietDescriptors.map { descriptor -> PairingNativeRequest in
      if let existing = requestObjects[descriptor.hash] { return existing }
      let value = PairingNativeRequest(descriptor, cid: context?.cid ?? "")
      requestObjects[descriptor.hash] = value
      return value
    }
    return PairingNativeTrustedSnapshot(eligible: eligible && markerVerified, markerVerified: markerVerified, suppressed: suppressed, requests: armedRequests ?? quiet, phase: phase, comparison: currentComparison)
  }
}

private final class PairingDeferredJoin: PairingJoinHandle {
  private let lock = NSRecursiveLock()
  private var delegate: PairingJoinHandle?
  private var cancelled = false
  private let onCancel: () -> Void
  init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
  func install(_ make: () -> PairingJoinHandle?) {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { return }
    delegate = make()
  }
  func cancel() -> PairingCancelResult {
    lock.lock(); defer { lock.unlock() }
    if !cancelled { cancelled = true; onCancel() }
    if let delegate { return delegate.cancel() }
    return .cancelled
  }
  func startAgain() { lock.lock(); defer { lock.unlock() }; delegate?.startAgain() }
}

private final class PairingFolderPresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let hint: () -> Void
  init(_ folder: URL, hint: @escaping () -> Void) {
    presentedItemURL = folder
    self.hint = hint
    super.init()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }
  func presentedItemDidChange() { hint() }
  func presentedSubitemDidChange(at url: URL) { hint() }
}

private final class PairingInstallationRouter: PairingInstallationHosting {
  private let lock = NSLock()
  private var hosts: [Data: PairingInstallationHost] = [:]
  func register(_ host: PairingInstallationHost, folderIdentity: Data) {
    lock.lock(); hosts = [folderIdentity: host]; lock.unlock()
  }
  func prepare(_ installation: PairingInstallation, completion: @escaping (Bool) -> Void) {
    lock.lock(); let host = hosts[installation.folderIdentity]; lock.unlock()
    guard let host else { completion(false); return }
    host.prepare(installation, completion: completion)
  }
  func keySaved(_ installation: PairingInstallation, initialized: @escaping (Bool) -> Void, ready: @escaping (Bool) -> Void) {
    lock.lock(); let host = hosts[installation.folderIdentity]; lock.unlock()
    guard let host else { initialized(false); ready(false); return }
    host.keySaved(installation, initialized: initialized, ready: ready)
  }
}
