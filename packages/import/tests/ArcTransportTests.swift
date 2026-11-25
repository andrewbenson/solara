import Foundation
import XCTest
@testable import SolaraLegacyImportCore

final class ArcTransportTests: XCTestCase {
  let personalPages: Set<String> = ["https://calendar.example/", "https://later.example/", "https://today.example/", "https://mail.example.com/"]

  func testFiltersDistinguishAllEmptySelectedAndUnknownSpaces() throws {
    let importer = Importer(discovery: Fixtures.discovery())
    let kinds: [ImportKind] = [.spaces, .pinnedTabs, .tabs, .favorites]
    let all = try importer.importData(browserId: "arc", profileId: "Default", kinds: kinds)
    XCTAssertEqual(all.spaces.map(\.id), ["S-PERSONAL", "S-UNTITLED"])
    XCTAssertEqual(Set(all.favicons.map(\.page)), personalPages.union(["https://untitled.example/"]))
    let selected = try importer.importData(browserId: "arc", profileId: "Default", kinds: kinds, options: ImportOptions(spaceIds: ["S-PERSONAL"]))
    XCTAssertEqual(selected.spaces.map(\.id), ["S-PERSONAL"])
    XCTAssertEqual(Set(selected.favicons.map(\.page)), personalPages)
    XCTAssertEqual(Set(selected.favicons.map(\.png)).count, 4)
    for icon in all.favicons {
      XCTAssertTrue(try XCTUnwrap(Data(base64Encoded: icon.png)).starts(with: ChromiumFavicons.pngSignature))
      XCTAssertEqual(icon.icon, icon.page + "icon.png")
    }
    let excluded: [Set<String>] = [[], ["unknown"], ["S-WORK"]]
    for ids in excluded {
      let none = try importer.importData(browserId: "arc", profileId: "Default", kinds: kinds, options: ImportOptions(spaceIds: ids))
      XCTAssertEqual(none.spaces, [])
      XCTAssertEqual(none.tabs, [])
      XCTAssertEqual(none.favorites.count, 3)
      XCTAssertEqual(none.favicons.map(\.page), ["https://mail.example.com/"])
    }
  }

  func testBothSourceProfilesHaveIndependentCommonDataAndIcons() throws {
    let importer = Importer(discovery: Fixtures.discovery())
    for (profile, space, bookmark, history, pages) in [
      ("Default", "S-PERSONAL", "https://arc-bookmark.example/", "https://arc-history.example/", personalPages),
      ("Profile 1", "S-WORK", "https://arc-work-bookmark.example/", "https://arc-work-history.example/", Set(["https://jira.example/", "https://slack.example/"])),
    ] {
      let result = try importer.importData(browserId: "arc", profileId: profile, kinds: [.bookmarks, .history, .spaces, .pinnedTabs, .tabs, .favorites], options: ImportOptions(spaceIds: [space]))
      XCTAssertEqual(result.failed, [])
      XCTAssertEqual(result.spaces.map(\.profileId), [profile])
      XCTAssertEqual(result.history.map(\.url), [history])
      XCTAssertEqual(result.bookmarks?.linkCount, 1)
      func links(_ node: BookmarkNode) -> [String] {
        node.type == .url ? node.url.map { [$0] } ?? [] : (node.children ?? []).flatMap(links)
      }
      XCTAssertEqual(result.bookmarks.map(links), [bookmark])
      XCTAssertEqual(Set(result.favicons.map(\.page)), pages)
      XCTAssertEqual(Set(result.favicons.map(\.png)).count, pages.count)
    }
  }

  func testZenEmptyFilterDoesNotBecomeAllSpaces() throws {
    let importer = Importer(discovery: Fixtures.discovery())
    let profile = "Profiles/zen12345.Default (release)"
    let filters: [Set<String>?] = [nil, [], ["{work-space}"], ["unknown"]]
    for ids in filters {
      let result = try importer.importData(browserId: "zen", profileId: profile, kinds: [.spaces, .pinnedTabs, .tabs, .favorites], options: ImportOptions(spaceIds: ids))
      XCTAssertEqual(result.spaces.map(\.id), ids == nil ? ["{work-space}", "{play-space}"] : ids == ["{work-space}"] ? ["{work-space}"] : [])
      XCTAssertEqual(result.favorites.map(\.url), ["https://mail.example/"])
      if ids == [] || ids == ["unknown"] { XCTAssertEqual(result.tabs, []) }
    }
  }
}
