import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@Suite(.serialized) struct PageLiveCostTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_PAGE_LIVE_BENCH"] == "1"))
  func busySessionDispatchAndPatchTurnover() throws {
    let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/sessions/perf-seed/session.json")
    let loader = Session(state: BrowserState(), memory: StoreMemory(ids: IdSource(launch: "page-live-cost")), env: PlainWebAddressing(), config: StoreConfig(), now: 1)
    let state = loader.loadSession(try JSONValue.parse(Data(contentsOf: seed)), downloads: nil)
    let ids = state.tabs.keys
    #expect(ids.count == 200)
    let prototype = PageLiveCostRunner(state: state, memory: loader.memory, ids: ids, prototype: true)
    let control = PageLiveCostRunner(state: state, memory: loader.memory, ids: ids, prototype: false)
    let warmup = (0..<2_000).map { PageLiveCostReport(index: $0, ids: ids) }
    let reports = (2_000..<22_000).map { PageLiveCostReport(index: $0, ids: ids) }
    for report in warmup {
      try prototype.feed(report)
      try control.feed(report)
    }
    prototype.resetSamples()
    control.resetSamples()
    for block in 0..<20 {
      let range = (block * 1_000)..<((block + 1) * 1_000)
      let runners = block.isMultiple(of: 2) ? [control, prototype] : [prototype, control]
      for runner in runners {
        for index in range { try runner.measure(reports[index]) }
      }
    }
    #expect(prototype.changed == control.changed)
    #expect(prototype.changed > 0)
    let retained = min(prototype.changed, Store.ringSize)
    #expect(prototype.store.patches(since: prototype.store.rev - retained)?.count == retained)
    if prototype.changed > Store.ringSize {
      #expect(prototype.store.patches(since: prototype.startRev) == nil)
    } else {
      #expect(prototype.store.patches(since: prototype.startRev)?.count == prototype.changed)
    }
    #expect(prototype.liveRing.count == min(prototype.store.rev, Store.ringSize))
    #expect(prototype.store.rev - prototype.startRev == prototype.changed)
    #expect(prototype.live.count == 200)
    prototype.printResults(label: "table-plus-dispatch")
    control.printResults(label: "dispatch-carrier-control")
    print("PAGE_LIVE_COST incremental_p50_ms=\(prototype.percentile(0.50) - control.percentile(0.50)) incremental_p99_ms=\(prototype.percentile(0.99) - control.percentile(0.99))")
    for reportsPerSecond in [200, 1_000, 5_000] {
      let patchesPerReport = Double(prototype.changed) / Double(reports.count)
      let seconds = Double(Store.ringSize) / (Double(reportsPerSecond) * patchesPerReport)
      print("PAGE_LIVE_COST paced_reports_per_second=\(reportsPerSecond) ring_\(Store.ringSize)_seconds=\(seconds)")
    }
  }
}

private struct PageLiveCostFact: JSONConvertible {
  var isLoading = false
  var canGoBack = false
  var canGoForward = false
  var playingAudio = false
  var themeColor: String? = nil
  var discarded = false

  init() {}

  init(json: JSONObject) throws {
    isLoading = json["isLoading"]?.bool ?? false
    canGoBack = json["canGoBack"]?.bool ?? false
    canGoForward = json["canGoForward"]?.bool ?? false
    playingAudio = json["playingAudio"]?.bool ?? false
    themeColor = json["themeColor"]?.string
    discarded = json["discarded"]?.bool ?? false
  }

  var json: JSONObject {
    ["isLoading": .bool(isLoading), "canGoBack": .bool(canGoBack), "canGoForward": .bool(canGoForward), "playingAudio": .bool(playingAudio), "themeColor": JSONValue(themeColor), "discarded": .bool(discarded)]
  }
}

private struct PageLiveCostReport {
  var id: String
  var fact: PageLiveCostFact
  var command: Command

  init(index: Int, ids: [String]) {
    id = ids[index % ids.count]
    let phase = (index / ids.count) % 10
    fact = PageLiveCostFact()
    fact.isLoading = phase < 2 || phase == 9
    fact.canGoBack = phase < 7 || phase == 9
    fact.canGoForward = phase == 6
    fact.playingAudio = (3...5).contains(phase)
    fact.themeColor = phase < 2 || phase == 9 ? nil : phase < 5 ? "#112233" : "#334455"
    fact.discarded = phase == 7
    let delta: JSONValue = ["live": ["upsert": .array([["id": .string(id), "facts": fact.jsonValue]]), "remove": .array([])]]
    command = Command("applyState", [["caches": ["launchBackdrop": delta]]])
  }
}

private final class PageLiveCostRunner {
  let store: Store
  let prototype: Bool
  var live: Table<PageLiveCostFact>
  var controlFacts: [String: PageLiveCostFact] = [:]
  var liveRing: [TablePatch] = []
  var ringStart = 0
  var changed = 0
  var startRev = 0
  var samples: [Double] = []
  var changedSamples: [Double] = []
  var turnoverSamples: [Double] = []
  var accumulatedMilliseconds = 0.0
  var lastTurnoverMilliseconds = 0.0

  init(state: BrowserState, memory: StoreMemory, ids: [String], prototype: Bool) {
    store = Store(state: state, memory: memory, checksInvariants: false, clock: { 1 })
    self.prototype = prototype
    live = Table()
    for id in ids {
      live[id] = PageLiveCostFact()
      controlFacts[id] = PageLiveCostFact()
    }
  }

  func resetSamples() {
    changed = 0
    startRev = store.rev
    samples = []
    changedSamples = []
    turnoverSamples = []
    accumulatedMilliseconds = 0
    lastTurnoverMilliseconds = 0
  }

  @discardableResult
  func feed(_ report: PageLiveCostReport) throws -> Bool {
    if prototype {
      guard live[report.id] != report.fact else { return false }
      let before = live
      live[report.id] = report.fact
      let change = TableChange(live, before)
      let patch = TablePatch(change, live) { id, fact in
        ["id": .string(id), "facts": fact.jsonValue]
      }!
      if liveRing.count < Store.ringSize {
        liveRing.append(patch)
      } else {
        liveRing[ringStart] = patch
        ringStart = (ringStart + 1) % Store.ringSize
      }
    } else {
      guard controlFacts[report.id] != report.fact else { return false }
      controlFacts[report.id] = report.fact
    }
    try store.dispatch(report.command, origin: .engine)
    return true
  }

  func measure(_ report: PageLiveCostReport) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let didChange = try feed(report)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    samples.append(elapsed)
    accumulatedMilliseconds += elapsed
    if didChange {
      changed += 1
      changedSamples.append(elapsed)
      if changed.isMultiple(of: Store.ringSize) {
        turnoverSamples.append(accumulatedMilliseconds - lastTurnoverMilliseconds)
        lastTurnoverMilliseconds = accumulatedMilliseconds
      }
    }
  }

  func percentile(_ fraction: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
  }

  func printResults(label: String) {
    let turnovers = turnoverSamples.sorted()
    let p50Turnover = turnovers.isEmpty ? "unmeasured" : String(turnovers[turnovers.count / 2])
    let p99Turnover = turnovers.isEmpty ? "unmeasured" : String(turnovers[min(turnovers.count - 1, turnovers.count * 99 / 100)])
    let changedSorted = changedSamples.sorted()
    print("PAGE_LIVE_COST label=\(label) tabs=\(live.count) reports=\(samples.count) changed=\(changed) p50_ms=\(percentile(0.50)) p99_ms=\(percentile(0.99)) changed_p50_ms=\(changedSorted[changedSorted.count / 2]) changed_p99_ms=\(changedSorted[changedSorted.count * 99 / 100]) service_ms=\(accumulatedMilliseconds) service_reports_per_second=\(Double(samples.count) * 1_000 / accumulatedMilliseconds) service_patches_per_second=\(Double(changed) * 1_000 / accumulatedMilliseconds) ring_\(Store.ringSize)_p50_ms=\(p50Turnover) ring_\(Store.ringSize)_p99_ms=\(p99Turnover) ring_windows=\(turnovers.count)")
  }
}
