import Foundation
import Testing
import SolaraModel
@testable import SolaraUI

struct BookmarksBarSnapshotTests {
  @Test func nativeDocumentPreservesOrderURLsFlagsAndMetadataWithoutABridgeTree() {
    let document: JSONValue = ["roots": ["alias": ["bar": "bar", "other": "other"]], "nodes": [
      "bar": ["id": "bar", "kind": "folder", "title": "Bar", "children": ["holder", "missing", "plain"]],
      "other": ["id": "other", "kind": "folder", "title": "Other", "children": []],
      "holder": ["id": "holder", "kind": "folder", "parentId": "bar", "title": "Space (Arc)", "children": ["group"]],
      "group": ["id": "group", "kind": "folder", "parentId": "holder", "title": "Group", "children": ["web", "script"]],
      "web": ["id": "web", "kind": "url", "parentId": "group", "title": "Web", "url": "https://example.test/?utm_source=x&keep=1", "favicon": "data:icon"],
      "script": ["id": "script", "kind": "url", "parentId": "group", "title": "Script", "url": "javascript:void(0)"],
      "plain": ["id": "plain", "kind": "url", "parentId": "bar", "title": "", "url": "file:///tmp/fixture"]
    ]]
    let metadata = BookmarksBarSnapshot(profileId: "alias", items: [], hasOther: false, hideBookmarksBarImport: true, theme: ["accent": "red"], dark: true, sidebarEdge: 212, bookmarksBar: "always")
    let snapshot = metadata.reading(document, engine: "engine")
    #expect(snapshot.items.map(\.id) == ["holder", "plain"])
    #expect(snapshot.items[0].folderLinks == 2)
    #expect(snapshot.items[0].makesGroup)
    #expect(snapshot.items[0].restorableArcHolder)
    #expect(snapshot.items[0].children[0].children[0].cleanUrl == "https://example.test/?keep=1")
    #expect(snapshot.items[0].children[0].children[0].favicon == "data:icon")
    #expect(snapshot.items[1].displayTitle == "file:///tmp/fixture")
    #expect(snapshot.otherId == "other" && snapshot.otherFolder?.children == [])
    #expect(!snapshot.hasOther)
    #expect(snapshot.dark && snapshot.hideBookmarksBarImport && snapshot.sidebarEdge == 212 && snapshot.theme == ["accent": "red"])
    #expect(metadata.reading(["nodes": [:]], engine: "missing").items.isEmpty)
    var renamed = document.object!
    var nodes = document["nodes"]!.object!
    var web = nodes["web"]!.object!
    web["title"] = "Renamed"
    nodes["web"] = .object(web)
    renamed["nodes"] = .object(nodes)
    #expect(metadata.reading(.object(renamed), engine: "engine").items[0].children[0].children[0].title == "Renamed")
  }

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
