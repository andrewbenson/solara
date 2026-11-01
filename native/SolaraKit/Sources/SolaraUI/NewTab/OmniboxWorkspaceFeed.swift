import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct OmniboxSourceStatus: Sendable, Equatable {
  public let mode: String
  public let ready: Bool
  public let epoch: Int

  public var dictionary: [String: Any] { ["mode": mode, "ready": ready, "epoch": epoch] }
}

@MainActor
public final class OmniboxWorkspaceFeed {
  public private(set) var status = OmniboxSourceStatus(mode: "js-feed", ready: false, epoch: 0)
  public var onStatus: ((OmniboxSourceStatus) -> Void)?
  private let sources: NewTabSources
  private let ownsWorkspace: () -> Bool
  private let resolve: () -> Store?
  private let clock: () -> TimeInterval
  private let currentOwnershipGeneration: () -> Int
  private var ownershipGeneration: Int
  private var store: Store?
  private var listener: Int?
  private(set) var generation = 0
  private var projection: OmniboxWorkspaceSources?
  private var revision = -1
  private var idleSnapshotRevision = -1
  private var waitingSince: TimeInterval?
  private var timedOut = false
  private var started = false
  private var lifecycleListener: Int?
  private var deadline: Task<Void, Never>?
  var didSubscribe: ((Store) -> Void)?

  public init(sources: NewTabSources, ownsWorkspace: @escaping () -> Bool,
    ownershipGeneration: @escaping () -> Int = { NativeStoreHandle.ownershipGeneration },
    resolve: @escaping () -> Store?, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.sources = sources
    self.ownsWorkspace = ownsWorkspace
    currentOwnershipGeneration = ownershipGeneration
    self.ownershipGeneration = ownershipGeneration()
    self.resolve = resolve
    self.clock = clock
  }

  public func observeStatus(_ handler: @escaping (OmniboxSourceStatus) -> Void) {
    onStatus = handler
    start()
    reconcile()
    handler(status)
  }

  public func start() {
    guard !started else { return }
    started = true
    let listener = NativeStoreHandle.subscribeLifecycle { [weak self] in
      guard let self, self.started else { return }
      self.reconcile()
    }
    if started {
      lifecycleListener = listener
    } else {
      NativeStoreHandle.unsubscribeLifecycle(listener)
    }
  }

  public func stop() {
    started = false
    if let lifecycleListener { NativeStoreHandle.unsubscribeLifecycle(lifecycleListener) }
    lifecycleListener = nil
    cancelDeadline()
    detach()
    timedOut = false
  }

  public func reconcile(now suppliedNow: TimeInterval? = nil) {
    let now = suppliedNow ?? clock()
    let nextOwnershipGeneration = currentOwnershipGeneration()
    if ownershipGeneration != nextOwnershipGeneration {
      ownershipGeneration = nextOwnershipGeneration
      if store != nil { detach() }
    }
    guard ownsWorkspace() else {
      cancelDeadline()
      timedOut = false
      if store != nil { detach() }
      return
    }
    guard let resolved = resolve() else {
      guard !timedOut else { return }
      if store != nil { detach() }
      let since = waitingSince ?? now
      waitingSince = since
      if now - since >= 2 {
        timedOut = true
        cancelDeadline()
        fallback()
      } else if deadline == nil {
        let remaining = 2 - (now - since)
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
          guard !Task.isCancelled, let self else { return }
          self.deadline = nil
          self.reconcile(now: since + 2)
        }
      }
      return
    }
    cancelDeadline()
    timedOut = false
    guard store !== resolved else { return }
    if store != nil { detach() }
    generation += 1
    let ticket = generation
    store = resolved
    revision = -1
    listener = resolved.subscribe { [weak self] commit in
      Task { @MainActor [weak self] in
        self?.receive(state: commit.state, revision: commit.rev, generation: ticket)
      }
    }
    didSubscribe?(resolved)
    let snapshot = resolved.snapshot
    receive(state: snapshot.state, revision: snapshot.rev, generation: ticket)
  }

  func receive(state: BrowserState, revision nextRevision: Int, generation ticket: Int) {
    guard ticket == generation, let store else { return }
    guard ownershipGeneration == currentOwnershipGeneration(), ownsWorkspace(), resolve() === store else {
      reconcile()
      return
    }
    guard nextRevision > revision else { return }
    revision = nextRevision
    let next = OmniboxWorkspaceSources(state)
    if projection != next {
      projection = next
      sources.applyWorkspace(next)
    }
    if !status.ready || status.mode != "native-store" {
      publish(mode: "native-store", ready: true)
    }
  }

  public func setIdleTabs(_ rows: OmniboxIdleTabSources, epoch: Int, revision: Int) {
    reconcile()
    guard acceptsFallback(epoch), revision > idleSnapshotRevision else { return }
    idleSnapshotRevision = revision
    sources.setIdleTabs(rows)
  }

  public func setTabs(_ rows: [TabRow], profileId: String, epoch: Int) {
    reconcile()
    guard acceptsFallback(epoch) else { return }
    sources.setTabs(rows, profileId: profileId)
  }

  public func setEngineProfile(_ engineProfile: String, bookmarkEngineProfile: String, profileId: String, epoch: Int) {
    reconcile()
    guard acceptsFallback(epoch) else { return }
    sources.setEngineProfile(engineProfile, bookmarkEngineProfile: bookmarkEngineProfile, profileId: profileId)
  }

  public func forget(windowId: String) {
    reconcile()
    sources.forget(windowId: windowId)
  }

  private func cancelDeadline() {
    deadline?.cancel()
    deadline = nil
    waitingSince = nil
  }

  private func acceptsFallback(_ epoch: Int) -> Bool {
    epoch == status.epoch && !(status.mode == "native-store" && status.ready)
  }

  private func detach() {
    generation += 1
    if let listener { store?.unsubscribe(listener) }
    listener = nil
    store = nil
    revision = -1
    projection = nil
    sources.resetWorkspace()
    fallback()
  }

  private func fallback() {
    publish(mode: "js-feed", ready: false)
  }

  private func publish(mode: String, ready: Bool) {
    idleSnapshotRevision = -1
    status = OmniboxSourceStatus(mode: mode, ready: ready, epoch: status.epoch + 1)
    onStatus?(status)
  }
}
