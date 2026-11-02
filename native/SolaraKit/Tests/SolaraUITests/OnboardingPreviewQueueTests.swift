import Foundation
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingPreviewQueueTests {
  @Test func failedPreviewRetriesBeforeRestorationAndDrainAcknowledgesBoth() async throws {
    let queue = OnboardingPreviewQueue()
    var available = false
    var writes: [String] = []
    queue.enqueue {
      guard available else { throw CocoaError(.fileWriteUnknown) }
      writes.append("preview")
    }
    do {
      try await queue.drain()
      Issue.record("Unavailable preview must not acknowledge")
    } catch {}
    #expect(writes.isEmpty)
    available = true
    queue.enqueue { writes.append("restore") }
    try await queue.drain()
    #expect(writes == ["preview", "restore"])
    try await queue.drain()
    #expect(writes == ["preview", "restore"])
  }

  @Test func queuedPreviewsKeepTheirOrder() async throws {
    let queue = OnboardingPreviewQueue()
    var writes: [Int] = []
    queue.enqueue { writes.append(1) }
    queue.enqueue { writes.append(2) }
    queue.enqueue { writes.append(3) }
    try await queue.drain()
    #expect(writes == [1, 2, 3])
  }
}
