import AppKit
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
@Suite(.serialized)
struct WindowPlacementPreparationTests {
  @MainActor
  private final class Placement {
    let shell: WindowShellView
    let controller: WindowLayoutController
    var revisions: [Int] = []
    var publishedSize = CGSize.zero

    init(id: String, store: Store) {
      shell = WindowShellView(windowId: id)
      shell.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
      controller = WindowLayoutController(shell: shell, generation: 1, store: store)
      controller.onState = { [weak self] _, revision in
        self?.revisions.append(revision)
        self?.scheduleGeometry()
      }
      controller.start()
    }

    func scheduleGeometry() {
      FrameUpdates.schedule(self) { [weak self] in
        guard let self else { return }
        self.publishedSize = self.shell.bounds.size
      }
    }
  }

  private func state() throws -> BrowserState {
    try BrowserState(stateJSON: JSONValue.parse(#"{"windows":{"a":{"id":"a","profileId":"p","tabIds":["one"],"activeTabIds":{"p":"one"}},"b":{"id":"b","profileId":"p","tabIds":["two"],"activeTabIds":{"p":"two"}}},"tabs":{"one":{"id":"one","profileId":"p","windowId":"a"},"two":{"id":"two","profileId":"p","windowId":"b"}}}"#).object ?? [:])
  }

  @Test func oneFlushPublishesEveryWindowAndRepeatedRevisionKeepsDirtyGeometry() throws {
    FrameUpdates.flush()
    let state = try state()
    let store = Store(state: state)
    let placements = [Placement(id: "a", store: store), Placement(id: "b", store: store)]
    defer { placements.forEach { $0.controller.stop() }; FrameUpdates.flush() }
    for placement in placements {
      placement.controller.receive(state, revision: 4, generation: 1)
    }
    #expect(placements.allSatisfy { $0.revisions.isEmpty && $0.publishedSize == .zero })
    FrameUpdates.flush()
    #expect(placements.allSatisfy { $0.revisions == [4] && $0.publishedSize == CGSize(width: 900, height: 700) })
    for placement in placements {
      placement.controller.receive(state, revision: 4, generation: 1)
    }
    placements[1].shell.setFrameSize(CGSize(width: 1100, height: 800))
    placements[1].scheduleGeometry()
    FrameUpdates.flush()
    #expect(placements.allSatisfy { $0.revisions == [4] })
    #expect(placements[0].publishedSize == CGSize(width: 900, height: 700))
    #expect(placements[1].publishedSize == CGSize(width: 1100, height: 800))
  }

  @Test func aMovePublishesBothOwnersBeforePlacementAndClosedOwnersStayStopped() throws {
    FrameUpdates.flush()
    var state = try state()
    let store = Store(state: state)
    let source = Placement(id: "a", store: store)
    let destination = Placement(id: "b", store: store)
    defer { source.controller.stop(); destination.controller.stop(); FrameUpdates.flush() }
    FrameUpdates.flush()
    state.windows["a"]?.tabIds = []
    state.windows["b"]?.tabIds = ["one", "two"]
    state.tabs["one"]?.windowId = "b"
    source.controller.receive(state, revision: 5, generation: 1)
    destination.controller.receive(state, revision: 5, generation: 1)
    FrameUpdates.flush()
    #expect(source.revisions.last == 5 && destination.revisions.last == 5)
    source.controller.stop()
    source.controller.receive(state, revision: 6, generation: 1)
    destination.controller.receive(state, revision: 6, generation: 1)
    FrameUpdates.flush()
    #expect(source.revisions.last == 5 && destination.revisions.last == 6)
  }
}
