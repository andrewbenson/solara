import Foundation
import SolaraPersistence
import SolaraStore

public struct StoreHost: Sendable {
  public let bridge: StoreBridge
  public let writer: PersistenceWriter?
  private let quitStages: QuitFlush.Stages?

  public init(
    store: Store, ownsWorkspace: Bool, folder: URL,
    themeSchedule: @escaping LaunchPageTheme.Schedule = { delay, work in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    },
    restoreTrouble: (String) -> Void = { _ in },
    makeWriter: (Store) -> PersistenceWriter?,
    makeBridge: (Store) -> StoreBridge = { StoreBridge(store: $0) },
    quitStages: QuitFlush.Stages? = nil
  ) {
    if ownsWorkspace {
      do { try LaunchPageTheme.restore(store: store, folder: folder) }
      catch { restoreTrouble("\(error)") }
      store.startLaunchPageThemeTimers(after: themeSchedule)
    }
    writer = makeWriter(store)
    bridge = makeBridge(store)
    self.quitStages = quitStages
  }

  public func termination() -> FlushResult { flushForQuit() }

  public func flush(timeout: TimeInterval) -> FlushResult { flushForQuit(writerTimeout: timeout) }

  public func flushForQuit(barrierTimeout: TimeInterval = 0.5, writerTimeout: TimeInterval = 0.5) -> FlushResult {
    QuitFlush.run(store: bridge.store, writer: writer, barrierTimeout: barrierTimeout, writerTimeout: writerTimeout, stages: quitStages)
  }
}
