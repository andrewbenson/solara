import Foundation
import Testing
import SolaraModel
@testable import SolaraUI

struct BugReportTests {
  static let facts = BugReportFacts(repo: "andrewbenson/solara", version: "0.4.5", build: "107", macOS: "26.6.2", model: "MacBookPro18,4", layout: "Sidebar")

  static func query(_ url: String) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(string: url)?.queryItems ?? [] { out[item.name] = item.value }
    return out
  }

  @Test func theLinkFillsTheFormFieldsByTheirIds() throws {
    let url = try #require(BugReport.url(Self.facts))
    #expect(url.hasPrefix("https://github.com/andrewbenson/solara/issues/new?template=bug.yml&"))
    #expect(Self.query(url) == ["template": "bug.yml", "version": "0.4.5 (107)", "macos": "26.6.2", "mac": "MacBookPro18,4", "layout": "Sidebar"])
    #expect(url.contains("version=0.4.5%20%28107%29"))
    #expect(url.contains("mac=MacBookPro18%2C4"))
    #expect(!url.contains("crash="))
  }

  @Test func everythingOutsideTheUnreservedSetIsPercentEncoded() throws {
    var facts = Self.facts
    facts.layout = "Top tabs & more=yes #1 ü/?"
    let url = try #require(BugReport.url(facts, crash: "line one\nline two: 100% + €"))
    let query = String(url.split(separator: "?", maxSplits: 1)[1])
    for pair in query.split(separator: "&") {
      let value = pair.split(separator: "=", maxSplits: 1)[1]
      #expect(value.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || "-_.~%".contains($0) }, "\(value)")
    }
    #expect(Self.query(url)["layout"] == "Top tabs & more=yes #1 ü/?")
    #expect(Self.query(url)["crash"] == "line one\nline two: 100% + €")
  }

  @Test func theVersionLeavesOutAMissingOrRepeatedBuild() {
    #expect(BugReport.versionField(version: "0.4.5", build: "") == "0.4.5")
    #expect(BugReport.versionField(version: "0.4.5", build: "0.4.5") == "0.4.5")
    #expect(BugReport.versionField(version: "0.4.5", build: "107") == "0.4.5 (107)")
  }

  @Test func theRepoMustBeAnOwnerAndName() {
    for bad in ["", "solara", "a/b/c", "../x", "a/..", "evil.com/x?y", "a b/c", "$(AC_RELEASE_REPO)", "a/b#c"] {
      var facts = Self.facts
      facts.repo = bad
      #expect(BugReport.url(facts) == nil, "\(bad)")
    }
    var facts = Self.facts
    facts.repo = "some-org/some.repo_2"
    #expect(BugReport.url(facts)?.hasPrefix("https://github.com/some-org/some.repo_2/issues/new?") == true)
  }

  @Test func aLongCrashIsTrimmedByWholeLinesToStayUnderTheCap() throws {
    let frames = (0..<400).map { "\($0)  Solara.debug.dylib  SomeVeryLongModule.someVeryLongFunctionName(withArgument:andAnother:) + \($0 * 4)" }
    let crash = (["Exception: EXC_BAD_ACCESS (SIGSEGV)", "Queue: com.apple.main-thread"] + frames).joined(separator: "\n")
    let url = try #require(BugReport.url(Self.facts, crash: crash))
    #expect(url.utf8.count <= BugReport.urlLimit)
    #expect(url.utf8.count > BugReport.urlLimit - 400)
    let kept = try #require(Self.query(url)["crash"])
    #expect(kept.hasPrefix("Exception: EXC_BAD_ACCESS (SIGSEGV)\nQueue: com.apple.main-thread\n0  "))
    #expect(kept.hasSuffix("\n…"))
    #expect(crash.hasPrefix(String(kept.dropLast(2))))
    #expect(Self.query(url)["version"] == "0.4.5 (107)")
  }

  @Test func aCrashThatCannotFitIsDroppedButTheRestStays() throws {
    let url = try #require(BugReport.url(Self.facts, crash: String(repeating: "x", count: 20_000)))
    #expect(Self.query(url)["crash"] == nil)
    #expect(Self.query(url)["version"] == "0.4.5 (107)")
    let tight = try #require(BugReport.url(Self.facts, crash: "short", limit: 50))
    #expect(Self.query(tight)["crash"] == nil)
  }

  @Test func theLayoutComesFromTheWindowThenTheSetting() throws {
    let state = BrowserState()
    #expect(BugReport.layoutName(nil, windowId: nil) == "Sidebar")
    #expect(BugReport.layoutName(state, windowId: "w1") == "Sidebar")
    var top = state
    top.settings = top.settings.choosing(["tabLayout": .string("top")])
    #expect(BugReport.layoutName(top, windowId: nil) == "Top tabs")
  }

  @Test func noPageAddressOrTitleCanReachTheLink() throws {
    let url = try #require(BugReport.url(Self.facts))
    let fields = Set(Self.query(url).keys)
    #expect(fields == ["template", "version", "macos", "mac", "layout"])
    let labels = Mirror(reflecting: Self.facts).children.compactMap(\.label)
    #expect(labels == ["repo", "version", "build", "macOS", "model", "layout"])
  }
}
