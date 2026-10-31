import Foundation
import SolaraModel
@testable import SolaraStore
import Synchronization
import Testing

private final class LaunchThemeClock: Sendable {
  let value = Mutex<Double>(0)
  func set(_ now: Double) { value.withLock { $0 = now } }
  func read() -> Double { value.withLock { $0 } }
}

private func launchThemeFixture() throws -> (Store, String, LaunchThemeClock) {
  let clock = LaunchThemeClock()
  let store = Store(clock: { clock.read() })
  let window = try store.dispatch(Command("createWindow", [["url": "https://page.example/"]])).result!.string!
  let id = store.state.windows[window]!.tabIds[0]
  return (store, id, clock)
}

private func launchThemeData(_ themes: [JSONValue], version: Int = 2) -> Data {
  Data(JSONValue.object(["version": JSONValue(version), "themes": .array(themes), "favicons": [:]]).text().utf8)
}

private func launchThemeEntry(_ id: String, page: String = "https://page.example/", color: String = "blue") -> JSONValue {
  ["tab": .string(id), "page": .string(page), "color": .string(color)]
}

private func restoreLaunchTheme(_ store: Store, _ id: String) throws {
  _ = try LaunchPageTheme.restore(store: store, data: launchThemeData([launchThemeEntry(id)]))
}

@Suite struct LaunchPageThemeTests {
  @Test func launchThemeRestoresMatchingPageOnly() throws {
    let (store, id, _) = try launchThemeFixture()
    let window = store.state.tabs[id]!.windowId
    let other = try store.dispatch(Command("newTab", [.string(window), ["url": "https://other.example/"]])).result!.string!
    try store.dispatch(Command("updateTab", [.string(id), ["url": "https://page.example/#anchor"]]))
    let applied = try LaunchPageTheme.restore(store: store, data: launchThemeData([
      launchThemeEntry(id), launchThemeEntry(other), launchThemeEntry("missing")]))
    #expect(applied == 1)
    #expect(store.state.live[id]?.themeColor == "blue")
    #expect(store.state.live[other]?.themeColor == nil)
    #expect(store.pageFacts(id) == nil)
    #expect(store.livePages().isEmpty)
    _ = try LaunchPageTheme.restore(store: store, data: launchThemeData([launchThemeEntry(id, color: "red")]))
    #expect(store.state.live[id]?.themeColor == "blue")
  }

  @Test func launchThemeBoundsUseUTF16AndLimits() throws {
    let (store, id, _) = try launchThemeFixture()
    let accepted = String(repeating: "😀", count: 32)
    let rejected = accepted + "x"
    let applied = try LaunchPageTheme.restore(store: store, data: launchThemeData([
      .null, launchThemeEntry(id, color: rejected), launchThemeEntry(id, color: accepted)]))
    #expect(applied == 1)
    #expect(store.state.live[id]?.themeColor == accepted)
    let before = store.snapshot
    for data in [Data(), Data("{".utf8), launchThemeData([launchThemeEntry(id)], version: 1),
      Data(repeating: 32, count: LaunchPageTheme.documentLimit + 1)] {
      #expect(try LaunchPageTheme.restore(store: store, data: data) == 0)
    }
    #expect(store.snapshot.state == before.state)
    #expect(store.rev == before.rev)
    let (limited, first, _) = try launchThemeFixture()
    let window = limited.state.tabs[first]!.windowId
    var ids = [first]
    for index in 1...200 {
      ids.append(try limited.dispatch(Command("newTab", [.string(window), ["url": .string("https://page.example/\(index)")]])).result!.string!)
    }
    let entries = ids.map { launchThemeEntry($0, page: limited.state.tabs[$0]!.url) }
    #expect(try LaunchPageTheme.restore(store: limited, data: launchThemeData([.null] + entries)) == 200)
    #expect(limited.state.live[ids[199]]?.themeColor == "blue")
    #expect(limited.state.live[ids[200]]?.themeColor == nil)
  }

  @Test func launchThemeFileValidationLeavesStoreUnchanged() throws {
    let (store, id, _) = try launchThemeFixture()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "launch-look.json")
    let before = store.snapshot
    #expect(try LaunchPageTheme.restore(store: store, folder: folder) == 0)
    for data in [Data("{".utf8), launchThemeData([launchThemeEntry(id)], version: 3),
      Data(repeating: 32, count: LaunchPageTheme.documentLimit + 1)] {
      try data.write(to: file)
      #expect(try LaunchPageTheme.restore(store: store, folder: folder) == 0)
      #expect(store.snapshot.state == before.state)
      #expect(store.rev == before.rev)
    }
    try launchThemeData([launchThemeEntry(id)]).write(to: file)
    #expect(try LaunchPageTheme.restore(store: store, folder: folder) == 1)
    #expect(store.snapshot.state.live[id]?.themeColor == "blue")
    #expect(store.livePages().isEmpty)
  }

  @Test func blankDoesNotStartGrace() throws {
    let (store, id, clock) = try launchThemeFixture()
    try restoreLaunchTheme(store, id)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, phaseANavigation(url: "about:blank")))
    clock.set(10_000)
    try store.dispatch(phaseAReport(id, ["type": "advance", "generation": "G"]))
    #expect(store.state.live[id]?.themeColor == "blue")
    #expect(store.memory.pages[id]?.live.settleAt == nil)
  }

  @Test func matchingSettledPageExpiresAfter1500ms() throws {
    let (store, id, clock) = try launchThemeFixture()
    try restoreLaunchTheme(store, id)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    clock.set(500)
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    #expect(store.memory.pages[id]?.live.settleAt == 2000)
    clock.set(1999)
    try store.dispatch(phaseAReport(id, ["type": "advance", "generation": "G"]))
    #expect(store.state.live[id]?.themeColor == "blue")
    clock.set(2000)
    try store.dispatch(phaseAReport(id, ["type": "advance", "generation": "G"]))
    #expect(store.state.live[id]?.themeColor == nil)
  }

  @Test func reportedThemeOrNewPageEndsGrace() throws {
    for newPage in [false, true] {
      let (store, id, clock) = try launchThemeFixture()
      try restoreLaunchTheme(store, id)
      try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
      try store.dispatch(phaseAReport(id, phaseANavigation()))
      var navigation = phaseANavigation(url: newPage ? "https://new.example/" : "https://page.example/").object!
      if !newPage { navigation["themeColor"] = "red" }
      try store.dispatch(phaseAReport(id, .object(navigation)))
      #expect(store.state.live[id]?.themeColor == (newPage ? nil : "red"))
      #expect(store.memory.pages[id]?.live.settleAt == nil)
      clock.set(10_000)
      try store.dispatch(phaseAReport(id, ["type": "advance", "generation": "G"]))
      #expect(store.state.live[id]?.themeColor == (newPage ? nil : "red"))
    }
  }

  @Test func staleGenerationTimerCannotClearReplacement() throws {
    let (store, id, clock) = try launchThemeFixture()
    let callbacks = SequencerValues<@Sendable () -> Void>()
    store.startLaunchPageThemeTimers(after: { _, work in callbacks.append(work) })
    try restoreLaunchTheme(store, id)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    let old = try #require(callbacks.all.first)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id, generation: "H")))
    var navigation = phaseANavigation(generation: "H").object!
    navigation["themeColor"] = "red"
    try store.dispatch(phaseAReport(id, .object(navigation)))
    clock.set(10_000)
    old()
    #expect(store.state.live[id]?.themeColor == "red")
    #expect(store.pageFacts(id)?.generation == "H")
  }

  @Test func unchangedSettledNavigationStillSchedulesNativeAdvance() throws {
    let (store, id, clock) = try launchThemeFixture()
    let callbacks = SequencerValues<@Sendable () -> Void>()
    let delays = SequencerValues<TimeInterval>()
    store.startLaunchPageThemeTimers(after: { delay, work in delays.append(delay); callbacks.append(work) })
    try store.dispatch(Command("updateTab", [.string(id), ["title": "Reported title"]]))
    try restoreLaunchTheme(store, id)
    try store.dispatch(phaseAReport(id, phaseACreated(store, id)))
    let before = store.rev
    clock.set(50)
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    #expect(store.rev == before)
    #expect(delays.all == [1.5])
    let revision = store.rev
    clock.set(100)
    try store.dispatch(phaseAReport(id, phaseANavigation()))
    #expect(store.rev == revision)
    #expect(delays.all == [1.5])
    clock.set(1550)
    let advance = try #require(callbacks.all.first)
    advance()
    #expect(store.state.live[id]?.themeColor == nil)
    #expect(store.memory.pages[id]?.live.settleAt == nil)
  }
}
