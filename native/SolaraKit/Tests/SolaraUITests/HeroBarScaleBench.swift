import Foundation
import Testing

@testable import SolaraModel
@testable import SolaraOmnibox
@testable import SolaraUI

@MainActor
struct HeroBarScaleBench {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_HEROBAR_SCALE"] != nil))
  func mainThreadCostPerKeystroke() async throws {
    let sizes = (ProcessInfo.processInfo.environment["SOLARA_HEROBAR_SCALE"] ?? "5000,20000").split(separator: ",").compactMap { Int($0) }
    let rounds = Int(ProcessInfo.processInfo.environment["SOLARA_HEROBAR_SCALE_ROUNDS"] ?? "10") ?? 10
    let clock = ContinuousClock()
    let micros = { (d: Duration) in Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12 }
    for size in sizes {
      for asynchronous in [false, true] {
        let sources = NewTabSources()
        sources.asynchronous = asynchronous
        sources.setHistory(OmniboxScaleRows.history(size), profileId: "p")
        sources.setTabs((0..<20).map { TabRow(id: "t\($0)", url: "https://tab\($0).example/page", title: "Tab \($0)", favicon: nil) }, profileId: "p")
        #expect(sources.preparedIndex("p"))
        let model = HeroBarModel(
          windowId: "w", tabId: UUID().uuidString, profileId: "p", incognito: false, settings: { Settings(values: [:]) }, sources: sources)
        let field = FakeHeroField()
        model.field = field
        var samples: [Double] = []
        for round in 0..<(rounds + 1) {
          for q in ["github.com/net", "react native perf", "weather"] {
            for i in 1...q.count {
              let next = String(q.prefix(i))
              let before = field.selection
              field.value = next
              field.selection = .caret(next.utf16.count)
              let start = clock.now
              model.textChanged(next, edit: EditContext(before: before, after: field.selection))
              _ = model.items.count
              _ = model.trailingHint
              if round > 0 { samples.append(micros(clock.now - start)) }
              sources.worker.drain()
              await Task.yield()
            }
            model.reset()
          }
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(0.95 * Double(samples.count)))]
        print(String(format: "herobar %d history, %@: main thread per key median %.0f µs, p95 %.0f µs, max %.0f µs (n %d)",
          size, asynchronous ? "background" : "on main", median, p95, samples.last!, samples.count))
      }
    }
  }
}

@MainActor
struct HeroBarRebuildBench {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_HEROBAR_SCALE"] != nil))
  func enterRightAfterAHistoryChange() async throws {
    let sizes = (ProcessInfo.processInfo.environment["SOLARA_HEROBAR_SCALE"] ?? "20000,100000").split(separator: ",").compactMap { Int($0) }
    let clock = ContinuousClock()
    let millis = { (d: Duration) in Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }
    for size in sizes {
      let rows = OmniboxScaleRows.history(size)
      for serveOld in [false, true] {
        var samples: [Double] = []
        for round in 0..<3 {
          let sources = NewTabSources()
          sources.asynchronous = serveOld
          sources.setHistory(rows, profileId: "p")
          #expect(sources.preparedIndex("p"))
          sources.setHistory(rows + [HistoryRow(url: "https://visit\(round).example/", title: "Visit", favicon: nil, visits: 1, lastVisit: 1_794_000_000_000)], profileId: "p")
          let start = clock.now
          _ = sources.suggestNow(SuggestRequest(profileId: "p", typed: "github.com/n", tabs: [], options: SuggestOptions()))
          samples.append(millis(clock.now - start))
          sources.worker.drain()
        }
        samples.sort()
        print(String(format: "rebuild %d history, %@: Enter right after a history change waited median %.1f ms, max %.1f ms (n %d)",
          size, serveOld ? "old index serves until ready" : "cold index swapped in at once", samples[samples.count / 2], samples.last!, samples.count))
      }
    }
  }
}

enum OmniboxScaleRows {
  static func history(_ count: Int) -> [HistoryRow] {
    let words = ["react", "native", "perf", "github", "swift", "rust", "news", "docs", "apple", "mail", "maps", "music", "video", "shop", "bank", "travel", "weather", "sports", "recipe", "photo"]
    var rows: [HistoryRow] = []
    rows.reserveCapacity(count)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(truncatingIfNeeded: seed >> 33)
    }
    let base = 1_794_000_000_000.0
    for i in 0..<count {
      let host = "\(words[next() % words.count])\(next() % 400).\(["com", "org", "net", "io"][next() % 4])"
      let path = (0..<(1 + next() % 3)).map { _ in words[next() % words.count] }.joined(separator: "/")
      let title = (0..<(2 + next() % 4)).map { _ in words[next() % words.count].capitalized }.joined(separator: " ")
      rows.append(HistoryRow(url: "https://\(host)/\(path)/\(i)", title: title, favicon: nil, visits: Double(1 + next() % 40), lastVisit: base - Double(next() % 2_000_000_000)))
    }
    return rows
  }
}
