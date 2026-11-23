import Foundation
import SolaraStore
import Testing
@testable import SolaraUI

struct StoreUnavailableReportTests {
  static let home = "/Users/someone"
  static let shortFolder = "/var/folders/ab/xyz123/T/ac-store-unavailable-1/data"
  static let realFolder = "/private" + shortFolder

  func failure(_ detail: String, errorType: String = "StoreOpenTestFailure", safeMode: Bool = false) -> StoreUnavailable {
    StoreUnavailable(
      cause: .openFailed, detail: detail, dataFolder: URL(fileURLWithPath: Self.shortFolder, isDirectory: true), offersSafeMode: true,
      errorType: errorType, launchWasSafeMode: safeMode)
  }

  @Test func theSummaryIsBuiltFromTheCauseTheTypeAndTheFirstLine() {
    let text = StoreUnavailableReport.summary(
      failure("SQLite error 14: unable to open \(Self.shortFolder)/state.sqlite\nsecret second line"),
      dataFolderPaths: [Self.shortFolder, Self.realFolder], home: Self.home)
    #expect(text == """
      Solara couldn't open its windows and tabs at launch.
      Cause: openFailed
      Error: StoreOpenTestFailure
      Message: SQLite error 14: unable to open <data folder>/state.sqlite
      Safe mode: no
      """)
    #expect(!text.contains("secret"))
  }

  @Test func theResolvedFolderIsReplacedWholeBeforeItsShorterForm() {
    let text = StoreUnavailableReport.scrub("open \(Self.realFolder)/state.sqlite and \(Self.shortFolder)/x", dataFolderPaths: [Self.shortFolder, Self.realFolder], home: Self.home)
    #expect(text == "open <data folder>/state.sqlite and <data folder>/x")
    #expect(!text.contains("/private"))
  }

  @Test func homeUsersAndTemporaryFoldersAreScrubbed() {
    let text = StoreUnavailableReport.scrub(
      "a \(Self.home)/Library/x b /Users/other/y c /private/var/folders/zz/q/T/f d /var/folders/zz/q/T/g", dataFolderPaths: [], home: Self.home)
    #expect(text == "a ~/Library/x b /Users/<user>/y c <temporary folder> d <temporary folder>")
  }

  @Test func noFullPathSurvivesInTheLink() throws {
    let detail = "SQLite error 14: unable to open database file \(Self.shortFolder)/state.sqlite (resolved \(Self.realFolder)/state.sqlite, home \(Self.home))"
    let summary = StoreUnavailableReport.summary(failure(detail, safeMode: true), dataFolderPaths: [Self.shortFolder, Self.realFolder], home: Self.home)
    let facts = BugReportFacts(repo: "owner/repo", version: "1.0", build: "1", macOS: "26.0", model: "Mac", layout: "Sidebar")
    let link = try #require(BugReport.url(facts, crash: summary))
    let decoded = try #require(link.removingPercentEncoding)
    for leak in [Self.home, Self.shortFolder, Self.realFolder, "/private/var", "/var/folders", "/Users/someone"] {
      #expect(!decoded.contains(leak), "\(leak) in \(decoded)")
    }
    #expect(decoded.contains("<data folder>/state.sqlite"))
    #expect(decoded.contains("Safe mode: yes"))
  }

  @Test func aTrailingSlashOrTheRootIsNeverAFolderToReplace() {
    #expect(StoreUnavailableReport.scrub("/a/b/c", dataFolderPaths: ["/", "/a/b/"], home: "") == "<data folder>/c")
  }
}
