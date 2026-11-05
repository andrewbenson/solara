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
    #expect(snapshot.sidebarEdge == nil)
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

  @Test func decodesAccentAndOptionalWindowSidebarEdge() throws {
    let json = ##"{"profileId":"profile-a","items":[],"hasOther":false,"hideBookmarksBarImport":false,"sidebarEdge":244.5,"theme":{"accent":"#AABBCC"}}"##
    let snapshot = try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.sidebarEdge == 244.5)
    #expect(snapshot.theme["accent"] == "#AABBCC")
    let closed = json.replacingOccurrences(of: "244.5", with: "null")
    #expect(try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(closed.utf8)).sidebarEdge == nil)
  }

  @Test func decodesRecursiveMenuMetadataAndOtherBookmarks() throws {
    let json = #"{"profileId":"p","items":[{"id":"f","kind":"folder","title":"Work","folderLinks":32,"makesGroup":false,"restorableArcHolder":true,"children":[{"id":"u","kind":"url","title":"","url":"https://example.test/?utm_source=test","cleanUrl":"https://example.test/"}]}],"barId":"bar","otherId":"other","otherFolder":{"id":"other","kind":"folder","title":"Other Bookmarks","children":[],"folderLinks":0,"makesGroup":false,"restorableArcHolder":false},"bookmarksBar":"newTab","hasOther":false,"hideBookmarksBarImport":false,"theme":{}}"#
    let snapshot = try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.barId == "bar")
    #expect(snapshot.bookmarksBar == "newTab")
    #expect(snapshot.items[0].folderLinks == 32)
    #expect(!snapshot.items[0].makesGroup)
    #expect(snapshot.items[0].restorableArcHolder)
    #expect(snapshot.items[0].children[0].cleanUrl == "https://example.test/")
    #expect(snapshot.otherFolder?.id == "other")
    #expect(snapshot.otherFolder?.children.isEmpty == true)
  }

  @Test func rejectsAnUnknownItemKind() {
    let json = #"{"profileId":"profile-a","items":[{"id":"a","kind":"separator","title":""}],"hasOther":false,"hideBookmarksBarImport":false,"theme":{}}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(BookmarksBarSnapshot.self, from: Data(json.utf8))
    }
  }
}
