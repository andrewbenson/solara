import Foundation
import Testing
@testable import SolaraUI

struct BookmarksBarSnapshotTests {
  @Test func decodesTheBridgeSnapshotWithoutRequiringDark() throws {
    let json = ##"{"profileId":"profile-a","items":[{"id":"url-a","kind":"url","title":"","url":"https://example.test/","favicon":"data:image/png;base64,a"},{"id":"folder-a","kind":"folder","title":"Work"}],"otherId":"other-a","hasOther":true,"hideBookmarksBarImport":false,"theme":{"textTab":"#112233","toolbarHover":"#1122330F"}}"##
    let snapshot = try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.profileId == "profile-a")
    #expect(snapshot.items.map(\.kind) == [.url, .folder])
    #expect(snapshot.items[0].displayTitle == "https://example.test/")
    #expect(snapshot.items[1].url == nil)
    #expect(snapshot.items[1].displayTitle == "Work")
    #expect(snapshot.otherId == "other-a")
    #expect(snapshot.hasOther)
    #expect(!snapshot.hideBookmarksBarImport)
    #expect(!snapshot.dark)
    #expect(snapshot.theme["textTab"] == "#112233")
    #expect(snapshot == (try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))))
  }

  @Test func decodesAnEmptyDarkProfileSnapshot() throws {
    let json = #"{"profileId":"profile-b","items":[],"hasOther":false,"hideBookmarksBarImport":true,"dark":true,"theme":{}}"#
    let snapshot = try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.otherId == nil)
    #expect(!snapshot.hasOther)
    #expect(snapshot.hideBookmarksBarImport)
    #expect(snapshot.dark)
  }

  @Test func rejectsAnUnknownItemKind() {
    let json = #"{"profileId":"profile-a","items":[{"id":"a","kind":"separator","title":""}],"hasOther":false,"hideBookmarksBarImport":false,"theme":{}}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    }
  }
}
