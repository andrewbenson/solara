import Foundation
import SolaraStore
import Synchronization

public enum QuitFlush {
  public static let maximumBudget: TimeInterval = 600

  public struct Stages: Sendable {
    public let drain: @Sendable (ContinuousClock.Instant) -> Bool
    public let flush: @Sendable (@escaping @Sendable (FlushResult) -> Void) -> Void

    public init(
      drain: @escaping @Sendable (ContinuousClock.Instant) -> Bool,
      flush: @escaping @Sendable (@escaping @Sendable (FlushResult) -> Void) -> Void
    ) {
      self.drain = drain
      self.flush = flush
    }
  }

  private final class Operation: Sendable {
    struct State {
      var drained = false
      var workerFinished = false
      var result: FlushResult?
    }

    let store: Store
    let deadline: ContinuousClock.Instant
    let barrier = DispatchSemaphore(value: 0)
    let completion = DispatchGroup()
    let state = Mutex(State())

    init(store: Store, deadline: ContinuousClock.Instant) {
      self.store = store
      self.deadline = deadline
      completion.enter()
    }

    func finish(_ result: FlushResult, beforeRelease: () -> Void) {
      let completed = state.withLock { state in
        guard state.result == nil else { return false }
        state.result = result
        return true
      }
      guard completed else { return }
      beforeRelease()
      completion.leave()
    }
  }

  private static let operations = Mutex<[ObjectIdentifier: Operation]>([:])
  private static let worker = DispatchQueue(label: "solara.quit.barrier", qos: .userInitiated, attributes: .concurrent)

  private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
    let duration = ContinuousClock.now.duration(to: deadline).components
    return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000)
  }

  private static func retire(_ operation: Operation, for store: Store) {
    let finished = operation.state.withLock { $0.workerFinished && $0.result != nil }
    guard finished else { return }
    operations.withLock { active in
      let key = ObjectIdentifier(store)
      if active[key] === operation { active.removeValue(forKey: key) }
    }
  }

  public static func run(
    store: Store, writer: PersistenceWriter?, barrierTimeout: TimeInterval, writerTimeout: TimeInterval,
    stages: Stages? = nil
  ) -> FlushResult {
    guard barrierTimeout.isFinite, writerTimeout.isFinite, barrierTimeout > 0, writerTimeout > 0,
      barrierTimeout <= maximumBudget, writerTimeout <= maximumBudget else { return .timedOut }
    let started = ContinuousClock.now
    let deadline = started.advanced(by: .seconds(barrierTimeout))
    let (operation, owns) = operations.withLock { active -> (Operation, Bool) in
      let key = ObjectIdentifier(store)
      if let operation = active[key] { return (operation, false) }
      let operation = Operation(store: store, deadline: deadline)
      active[key] = operation
      return (operation, true)
    }
    if !owns {
      let until = deadline.advanced(by: .seconds(writerTimeout))
      guard operation.completion.wait(timeout: .now() + remaining(until: until)) == .success else { return .timedOut }
      return operation.state.withLock { $0.result ?? .timedOut }
    }
    let stages = stages ?? Stages(
      drain: { store.drainForQuit(until: $0) },
      flush: { complete in
        guard let writer else { complete(.safeModeOpenedNoDatabase); return }
        writer.markShadowDirty()
        writer.enqueueDurableFlush(complete)
      })
    worker.async {
      let drained = stages.drain(operation.deadline)
      operation.state.withLock { $0.drained = drained; $0.workerFinished = true }
      operation.barrier.signal()
      retire(operation, for: store)
    }
    guard operation.barrier.wait(timeout: .now() + remaining(until: deadline)) == .success,
      ContinuousClock.now < deadline, operation.state.withLock({ $0.drained }) else {
      operation.finish(.timedOut) { retire(operation, for: store) }
      return .timedOut
    }
    let writerDeadline = ContinuousClock.now.advanced(by: .seconds(writerTimeout))
    stages.flush { result in
      operation.finish(result) { retire(operation, for: store) }
    }
    guard operation.completion.wait(timeout: .now() + remaining(until: writerDeadline)) == .success else { return .timedOut }
    return operation.state.withLock { $0.result ?? .timedOut }
  }
}
