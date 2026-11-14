import Foundation
import Testing

@testable import SolaraOmnibox

@Suite struct OmniboxScaleBench {
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

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_SCALE"] != nil))
  func keystrokeCostAtScale() throws {
    let sizes = (ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_SCALE"] ?? "5000,20000").split(separator: ",").compactMap { Int($0) }
    let rounds = Int(ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_SCALE_ROUNDS"] ?? "40") ?? 40
    let clock = ContinuousClock()
    let micros = { (d: Duration) in Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12 }
    let tabs = (0..<20).map { TabRow(id: "t\($0)", url: "https://tab\($0).example/page", title: "Tab \($0)", favicon: nil) }
    let bookmarks = (0..<1000).map { BookmarkRow(url: "https://bookmark\($0 % 300).com/b/\($0)", title: "Bookmark \($0)", favicon: nil) }
    let options = SuggestOptions(now: 1_794_000_000_000)
    for size in sizes {
      let rows = Self.history(size)
      var start = clock.now
      let index = SuggestionIndex(history: rows, bookmarks: bookmarks)
      index.prepare()
      let prepare = micros(clock.now - start) / 1000
      var samples: [Double] = []
      for q in ["github.com/net", "react native perf", "weather"] {
        let prefixes = (1...q.count).map { String(q.prefix($0)) }
        for p in prefixes { _ = index.suggest(p, tabs: tabs, options: options) }
        for _ in 0..<rounds {
          for p in prefixes {
            start = clock.now
            _ = index.suggest(p, tabs: tabs, options: options)
            samples.append(micros(clock.now - start))
          }
        }
      }
      samples.sort()
      let median = samples[samples.count / 2]
      let p95 = samples[min(samples.count - 1, Int(0.95 * Double(samples.count)))]
      let mean = samples.reduce(0, +) / Double(samples.count)
      print(String(format: "scale %d history: prepare %.1f ms; per key median %.0f µs, mean %.0f µs, p95 %.0f µs, max %.0f µs (n %d)", size, prepare, median, mean, p95, samples.last!, samples.count))
    }
  }
}
