#if os(macOS)
import Darwin
import Foundation
import SolaraModel
@testable import SolaraStore
import Synchronization
import Testing

@Suite(.serialized) struct PageReportRetentionHeapTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_PAGE_REPORT_HEAP"] == "1"))
  func releaseRetainedRingHeap() throws {
    #if DEBUG
      throw PageReportHeapError.releaseRequired
    #else
      let selected = ProcessInfo.processInfo.environment["SOLARA_PAGE_REPORT_HEAP_CASE"] ?? "live"
      guard ["empty", "live", "mixed", "wrap"].contains(selected) else { throw PageReportHeapError.invalidCase }
      try autoreleasepool {
        let warm = try PageReportHeapFixture.makeStore()
        try PageReportHeapFixture.feed(warm, range: 0..<1_000, mixed: true)
        _ = JSONValue.array((warm.patches(since: 0) ?? []).map(\.json)).text().utf8.count
      }
      var store: Store? = try autoreleasepool { try PageReportHeapFixture.makeStore() }
      weak var releasedStore = store
      #expect(store?.rev == 0)
      var samples: [JSONObject] = []
      let warmed = try PageReportHeapMemory.capture()
      samples.append(warmed.json(phase: "warmed_empty_ring", revision: 0))
      let mixed = selected == "mixed" || selected == "wrap"
      var changed = 0
      if selected != "empty" {
        try autoreleasepool { try PageReportHeapFixture.feed(store!, range: 0..<Store.ringSize, mixed: mixed) }
        changed = Store.ringSize
        #expect(store?.rev == changed)
        samples.append(try PageReportHeapMemory.capture().json(phase: "full_ring", revision: changed))
      }
      if selected == "wrap" {
        for wrap in 1...2 {
          let end = changed + Store.ringSize
          try autoreleasepool { try PageReportHeapFixture.feed(store!, range: changed..<end, mixed: true) }
          changed = end
          #expect(store?.rev == changed)
          samples.append(try PageReportHeapMemory.capture().json(phase: "wrap_\(wrap)", revision: changed))
        }
      }
      let retained = try PageReportHeapMemory.capture()
      samples.append(retained.json(phase: "retained", revision: changed))
      let encoding = try autoreleasepool { try PageReportHeapFixture.measureEncoding(store!, expectedCount: min(changed, Store.ringSize)) }
      let suffix = try autoreleasepool { try PageReportHeapFixture.measureSuffix(store!, count: min(changed, 8)) }
      let producer = selected == "empty" ? JSONObject() : try autoreleasepool { try PageReportHeapFixture.measureConcurrentProducer(store!) }
      store = nil
      #expect(releasedStore == nil)
      samples.append(try PageReportHeapMemory.capture().json(phase: "store_released", revision: changed))
      let retainedSlots = min(changed, Store.ringSize)
      let mallocDelta = Double(retained.mallocBytes) - Double(warmed.mallocBytes)
      let physicalDelta = Double(retained.physicalBytes) - Double(warmed.physicalBytes)
      let report: JSONObject = [
        "schema": 1, "case": .string(selected), "pid": JSONValue(Int(getpid())),
        "os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        "processors": JSONValue(ProcessInfo.processInfo.processorCount), "tabs": 1_000,
        "capacity": JSONValue(Store.ringSize), "changed": JSONValue(changed), "retainedSlots": JSONValue(retainedSlots),
        "retainedMallocMinusWarmed": JSONValue(mallocDelta), "retainedPhysicalMinusWarmed": JSONValue(physicalDelta),
        "mallocBytesPerSlotMinusWarmed": retainedSlots == 0 ? .null : JSONValue(mallocDelta / Double(retainedSlots)),
        "physicalBytesPerSlotMinusWarmed": retainedSlots == 0 ? .null : JSONValue(physicalDelta / Double(retainedSlots)),
        "samples": .array(samples.map(JSONValue.object)), "encoding": .object(encoding),
        "suffix": .object(suffix), "producer": .object(producer),
      ]
      print("PAGE_REPORT_HEAP_JSON " + JSONValue.object(report).text(sortedKeys: true))
    #endif
  }
}

private enum PageReportHeapError: Error {
  case releaseRequired
  case invalidCase
  case footprint(Int32)
  case replayUnavailable
  case workerDeadline
  case producer(String)
}

private struct PageReportHeapMemory: Sendable {
  let mallocBytes: UInt64
  let physicalBytes: UInt64

  static func capture() throws -> Self {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else { throw PageReportHeapError.footprint(result) }
    return Self(mallocBytes: UInt64(statistics.size_in_use), physicalBytes: usage.ri_phys_footprint)
  }

  func json(phase: String, revision: Int) -> JSONObject {
    ["phase": .string(phase), "revision": JSONValue(revision),
      "mallocSizeInUse": JSONValue(Double(mallocBytes)), "physicalFootprint": JSONValue(Double(physicalBytes))]
  }
}

private final class PageReportHeapPeak: Sendable {
  struct State: Sendable {
    var mallocBytes: UInt64
    var physicalBytes: UInt64
    var samples = 0
    var timedOut = false
  }

  let stopped = Atomic(false)
  let state: Mutex<State>
  let started = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)

  init(initial: PageReportHeapMemory) {
    state = Mutex(State(mallocBytes: initial.mallocBytes, physicalBytes: initial.physicalBytes))
  }

  func start() throws {
    DispatchQueue(label: "solara.page-report-heap.peak").async {
      let deadline = DispatchTime.now() + 120
      self.started.signal()
      while !self.stopped.load(ordering: .relaxed), DispatchTime.now() < deadline {
        if let memory = try? PageReportHeapMemory.capture() { self.note(memory) }
        usleep(1_000)
      }
      if !self.stopped.load(ordering: .relaxed) { self.state.withLock { $0.timedOut = true } }
      self.done.signal()
    }
    guard started.wait(timeout: .now() + 5) == .success else { throw PageReportHeapError.workerDeadline }
  }

  func note(_ memory: PageReportHeapMemory) {
    state.withLock {
      $0.mallocBytes = max($0.mallocBytes, memory.mallocBytes)
      $0.physicalBytes = max($0.physicalBytes, memory.physicalBytes)
      $0.samples += 1
    }
  }

  func finish() throws -> JSONObject {
    stopped.store(true, ordering: .relaxed)
    guard done.wait(timeout: .now() + 5) == .success else { throw PageReportHeapError.workerDeadline }
    guard !state.withLock({ $0.timedOut }) else { throw PageReportHeapError.workerDeadline }
    return state.withLock { ["sampledPeakMallocSizeInUse": JSONValue(Double($0.mallocBytes)),
      "sampledPeakPhysicalFootprint": JSONValue(Double($0.physicalBytes)), "peakSamples": JSONValue($0.samples), "samplingIntervalMilliseconds": 1] }
  }
}

private enum PageReportHeapFixture {
  static let tabCount = 1_000

  static func id(_ index: Int) -> String { "heap-tab-\(index % tabCount)" }
  static func generation(_ index: Int) -> String { "heap-generation-\(index % tabCount)" }

  static func makeStore() throws -> Store {
    var state = BrowserState()
    var window = BrowserWindow(id: "heap-window", profileId: "default", incognito: false, frame: nil, createdAt: 1)
    window.tabIds = (0..<tabCount).map(id)
    window.activeTabIds["default"] = id(0)
    state.windows[window.id] = window
    state.windowOrder = [window.id]
    for index in 0..<tabCount {
      let url = "https://heap.example.test/page/\(index)"
      var tab = Tab(id: id(index), windowId: window.id, profileId: "default", url: url, now: 1)
      tab.navigation = Navigation(url: url, seq: 1)
      tab.title = "Retention fixture page \(index)"
      state.tabs[tab.id] = tab
    }
    let store = Store(state: state, memory: StoreMemory(ids: IdSource(launch: "page-report-heap")), checksInvariants: false, clock: { 1 })
    for index in 0..<tabCount {
      try store.dispatch(Command("pageReport", [.string(id(index)), ["type": "created", "generation": .string(generation(index)),
        "engine": "chromium", "navigationSeq": 1, "contextRevision": 1, "wasNewTab": false, "newTabShownUrl": .null]]), origin: .engine)
    }
    return store
  }

  static func feed(_ store: Store, range: Range<Int>, mixed: Bool) throws {
    for index in range {
      let active = (index / tabCount).isMultiple(of: 2)
      let report: JSONValue
      if mixed {
        report = ["type": "navigation", "generation": .string(generation(index)),
          "url": .string("https://heap.example.test/page/\(index % tabCount)/event/\(index)?source=retention-measurement&section=workspace-and-live-facts"),
          "title": .string("Retention measurement page \(index % tabCount), navigation event \(index), deterministic mixed traffic"),
          "isLoading": .bool(active), "canGoBack": true, "canGoForward": false]
      } else {
        report = ["type": "media", "generation": .string(generation(index)), "playing": .bool(active)]
      }
      try store.dispatch(Command("pageReport", [.string(id(index)), report]), origin: .engine)
    }
  }

  static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

  static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
  }

  static func measureEncoding(_ store: Store, expectedCount: Int) throws -> JSONObject {
    let baseline = try PageReportHeapMemory.capture()
    let peak = PageReportHeapPeak(initial: baseline)
    try peak.start()
    var failure: (any Error)?
    var encodedBytes = 0
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      try autoreleasepool {
        guard let patches = store.patches(since: max(0, store.rev - expectedCount)) else { throw PageReportHeapError.replayUnavailable }
        #expect(patches.count == expectedCount)
        let value = JSONValue.array(patches.map(\.json))
        peak.note(try PageReportHeapMemory.capture())
        let encoded = value.text()
        encodedBytes = encoded.utf8.count
        peak.note(try PageReportHeapMemory.capture())
      }
    } catch { failure = error }
    let elapsed = milliseconds(since: start)
    var result = try peak.finish()
    if let failure { throw failure }
    result["elapsedMilliseconds"] = JSONValue(elapsed)
    result["samples"] = 1
    result["encodedBytes"] = JSONValue(encodedBytes)
    result["patches"] = JSONValue(expectedCount)
    result["baselineMallocSizeInUse"] = JSONValue(Double(baseline.mallocBytes))
    result["baselinePhysicalFootprint"] = JSONValue(Double(baseline.physicalBytes))
    return result
  }

  static func measureSuffix(_ store: Store, count: Int) throws -> JSONObject {
    let revision = store.rev
    var samples: [Double] = []
    for _ in 0..<100 {
      let start = DispatchTime.now().uptimeNanoseconds
      let patches = store.patches(since: revision - count)
      samples.append(milliseconds(since: start))
      #expect(patches?.count == count)
    }
    return ["samples": JSONValue(samples.count), "patches": JSONValue(count),
      "milliseconds": .array(samples.map { JSONValue($0) }), "p50Milliseconds": JSONValue(percentile(samples, 0.50)), "p95Milliseconds": JSONValue(percentile(samples, 0.95))]
  }

  static func measureConcurrentProducer(_ store: Store) throws -> JSONObject {
    let revision = store.rev
    guard let patches = store.patches(since: max(0, revision - Store.ringSize)) else { throw PageReportHeapError.replayUnavailable }
    let producer = PageReportHeapProducer(store: store)
    try producer.start()
    let start = DispatchTime.now().uptimeNanoseconds
    producer.beginEncoding.signal()
    let encodedBytes = JSONValue.array(patches.map(\.json)).text().utf8.count
    let encodingEnd = DispatchTime.now().uptimeNanoseconds
    let encodingMilliseconds = milliseconds(since: start)
    let measured = try producer.finish()
    let firstProducerStart = producer.state.withLock { $0.firstStart }
    let overlapped = firstProducerStart > 0 && firstProducerStart < encodingEnd
    #expect(overlapped)
    #expect(measured.count == 64)
    #expect(store.rev == revision + 64)
    return ["samples": JSONValue(measured.count), "milliseconds": .array(measured.map { JSONValue($0) }), "p50Milliseconds": JSONValue(percentile(measured, 0.50)),
      "p95Milliseconds": JSONValue(percentile(measured, 0.95)), "maximumMilliseconds": JSONValue(measured.max() ?? 0),
      "overlappedEncoding": .bool(overlapped), "encodingMilliseconds": JSONValue(encodingMilliseconds), "encodedBytes": JSONValue(encodedBytes)]
  }
}

private final class PageReportHeapProducer: Sendable {
  struct State: Sendable {
    var store: Store?
    var samples: [Double] = []
    var failure: String?
    var firstStart: UInt64 = 0
  }

  let state: Mutex<State>
  let started = DispatchSemaphore(value: 0)
  let beginEncoding = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)

  init(store: Store) { state = Mutex(State(store: store)) }

  func start() throws {
    DispatchQueue(label: "solara.page-report-heap.producer").async {
      self.run()
      self.done.signal()
    }
    guard started.wait(timeout: .now() + 5) == .success else { throw PageReportHeapError.workerDeadline }
  }

  private func run() {
    defer { state.withLock { $0.store = nil } }
    guard let store = state.withLock({ $0.store }) else { return }
    started.signal()
    guard beginEncoding.wait(timeout: .now() + 5) == .success else {
      state.withLock { $0.failure = "encoding start deadline" }
      return
    }
    do {
      for index in 0..<64 {
        let tab = PageReportHeapFixture.id(index)
        let report: JSONValue = ["type": "media", "generation": .string(PageReportHeapFixture.generation(index)),
          "playing": .bool(store.state.live[tab]?.playingAudio != true)]
        let start = DispatchTime.now().uptimeNanoseconds
        if index == 0 { state.withLock { $0.firstStart = start } }
        try store.dispatch(Command("pageReport", [.string(tab), report]), origin: .engine)
        let elapsed = PageReportHeapFixture.milliseconds(since: start)
        state.withLock { $0.samples.append(elapsed) }
      }
    } catch { state.withLock { $0.failure = String(describing: error) } }
  }

  func finish() throws -> [Double] {
    guard done.wait(timeout: .now() + 60) == .success else { throw PageReportHeapError.workerDeadline }
    if let failure = state.withLock({ $0.failure }) { throw PageReportHeapError.producer(failure) }
    return state.withLock { $0.samples }
  }
}

#endif
