import Darwin
import Foundation
import Testing

@testable import SolaraOmnibox

@Suite(.serialized) struct DottedInputTests {
  @Test func dottedDashedTextKeepsItsClassification() {
    let cases: [(String, String?)] = [
      ("my-post.another-post.x", nil),
      ("my-post.another-post.x:", nil),
      ("my-post.another-post.x:8", "https://my-post.another-post.x:8"),
      ("my-post.another-post.x:8080", "https://my-post.another-post.x:8080"),
      ("my-post.another-post.x:123456", nil),
      ("my-post.another-post.x:x", nil),
      ("my-post.another-post.x/path", nil),
      ("my-post.another-post.x/path?x=1", "https://my-post.another-post.x/path?x=1"),
      ("my-post.another-post.x:8080/path", "https://my-post.another-post.x:8080/path"),
      ("my-post.another-post.x:/path", nil),
      ("a-b.c-d.e-f.g-h.i:", nil),
      (String(repeating: "-.", count: 256), nil),
      (String(repeating: "-.", count: 255) + ":", nil),
    ]
    #expect(resolveInput("my-post.another-post.x:") == "https://www.google.com/search?q=my-post.another-post.x%3A")
    #expect(classifyPaste("my-post.another-post.x:") == .search(query: "my-post.another-post.x:"))
    #expect(resolveInput("a-b.c-d.e-f.g-h.i:") == "https://www.google.com/search?q=a-b.c-d.e-f.g-h.i%3A")
    #expect(classifyPaste("a-b.c-d.e-f.g-h.i:") == .search(query: "a-b.c-d.e-f.g-h.i:"))
    #expect(resolveInput("my-post.another-post.x:8080") == "https://my-post.another-post.x:8080")
    #expect(classifyPaste("my-post.another-post.x:8080") == .go(url: "https://my-post.another-post.x:8080"))
    #expect(resolveInput("my-post.another-post.x/path?x=1") == "https://my-post.another-post.x/path?x=1")
    #expect(classifyPaste("my-post.another-post.x/path?x=1") == .go(url: "https://my-post.another-post.x/path?x=1"))
    let source = SuggestionSource()
    for (input, expected) in cases {
      #expect(fixupUrl(input) == expected, "\(input)")
      let result = buildSuggestions(input, source)
      #expect(result.completion.isEmpty, "\(input)")
      if let expected {
        #expect(result.items.first == .page(url: expected, title: "", favicon: nil), "\(input)")
      } else {
        #expect(result.items.first?.kind == "search", "\(input)")
      }
    }
  }

  @Test(.enabled(if: !_isDebugAssertConfiguration()))
  func everyDottedDashedPrefixStaysWithinTheParsingCPUBudget() {
    let stems = [
      "my-post.another-post.x",
      "a-b.c-d.e-f.g-h.i",
      String(repeating: "-.", count: 256),
      String(repeating: "a-b.", count: 127) + "x",
      "a" + String(repeating: "-", count: 510),
    ]
    let suffixes = ["", ":", ":8", ":8080", ":123456", ":x", "/path", "/path?x=1", ":8080/path", ":/path"]
    let inputs = stems.flatMap { stem in suffixes.map { String(stem.prefix(512 - $0.count)) + $0 } }
    let prefixes = Set(inputs.flatMap { input in (1...input.count).map { String(input.prefix($0)) } }).sorted()
    let now = 1_790_208_000_000.0
    let history = (0..<200).map { HistoryRow(url: "https://page\($0).example.com/path", title: "Page \($0)", favicon: nil, visits: 5, lastVisit: now) }
    let index = SuggestionIndex(history: history, bookmarks: [])
    index.prepare()
    let options = SuggestOptions(now: now)
    let clock = ContinuousClock()
    var worstParserWall = Duration.zero
    var worstSuggestionWall = Duration.zero
    var worstParserCPU: UInt64 = 0
    var worstSuggestionCPU: UInt64 = 0
    var worstParserKind = ""
    var worstParserLength = 0
    var worstSuggestionLength = 0
    var checksum = 0
    _ = fixupUrl("example.com")
    _ = index.suggest("example.com", tabs: [], options: options)
    for prefix in prefixes {
      for kind in ["fixup", "resolve", "paste"] {
        var wallSamples: [Duration] = []
        var cpuSamples: [UInt64] = []
        for _ in 0..<9 {
          let start = clock.now
          let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
          switch kind {
          case "fixup": checksum += fixupUrl(prefix)?.utf16.count ?? 0
          case "resolve": checksum += resolveInput(prefix).utf16.count
          default: if classifyPaste(prefix) != nil { checksum += 1 }
          }
          cpuSamples.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart)
          wallSamples.append(clock.now - start)
        }
        wallSamples.sort()
        cpuSamples.sort()
        worstParserWall = max(worstParserWall, wallSamples[4])
        if cpuSamples[4] > worstParserCPU {
          worstParserCPU = cpuSamples[4]
          worstParserKind = kind
          worstParserLength = prefix.utf16.count
        }
      }
      var wallSamples: [Duration] = []
      var cpuSamples: [UInt64] = []
      for _ in 0..<9 {
        let start = clock.now
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        checksum += index.suggest(prefix, tabs: [], options: options).items.count
        cpuSamples.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart)
        wallSamples.append(clock.now - start)
      }
      wallSamples.sort()
      cpuSamples.sort()
      worstSuggestionWall = max(worstSuggestionWall, wallSamples[4])
      if cpuSamples[4] > worstSuggestionCPU {
        worstSuggestionCPU = cpuSamples[4]
        worstSuggestionLength = prefix.utf16.count
      }
    }
    print("DottedInputTests: \(prefixes.count) prefixes; parser \(worstParserKind) CPU median \(Double(worstParserCPU) / 1000) us at \(worstParserLength) units; prepared suggestion CPU median \(Double(worstSuggestionCPU) / 1000) us at \(worstSuggestionLength) units; wall medians \(worstParserWall) parser, \(worstSuggestionWall) suggestions")
    #expect(checksum > 0)
    #expect(worstParserCPU > 0)
    #expect(worstSuggestionCPU > 0)
    #expect(worstParserCPU < 1_000_000, "\(worstParserKind) at \(worstParserLength) UTF-16 units")
    #expect(worstSuggestionCPU < 1_000_000, "prepared suggestions at \(worstSuggestionLength) UTF-16 units")
  }
}
