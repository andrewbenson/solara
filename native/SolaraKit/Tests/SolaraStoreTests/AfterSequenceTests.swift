import Foundation
import Synchronization
import Testing
@testable import SolaraStore

@Suite struct AfterSequenceTests {
  @Test func callbacksWaitForOuterExitAndStayFIFOThroughListenerReentry() throws {
    let store = makeStore()
    let order = Mutex<[String]>([])
    let token = store.subscribe { _ in
      order.withLock { $0.append("listener") }
      store.sequence { store.afterSequence { order.withLock { $0.append("reentrant") } } }
    }
    defer { store.unsubscribe(token) }
    try store.sequence {
      try store.dispatch(settingsCommand(["sidebarWidth": 299]))
      store.afterSequence { order.withLock { $0.append("first") } }
      store.sequence { store.afterSequence { order.withLock { $0.append("second") } } }
      #expect(order.withLock { $0 }.isEmpty)
    }
    #expect(order.withLock { $0 } == ["listener", "first", "second", "reentrant"])
  }

  @Test func callbackReentryCannotOvertakeAlreadyReservedCallback() {
    let store = makeStore()
    let order = Mutex<[String]>([])
    store.sequence {
      store.afterSequence {
        order.withLock { $0.append("first") }
        store.sequence { store.afterSequence { order.withLock { $0.append("third") } } }
      }
      store.afterSequence { order.withLock { $0.append("second") } }
    }
    #expect(order.withLock { $0 } == ["first", "second", "third"])
  }
}
