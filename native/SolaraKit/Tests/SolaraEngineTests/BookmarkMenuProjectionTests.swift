import SolaraEngine
import SolaraModel
import Testing

@Suite struct BookmarkMenuProjectionTests {
  @Test func emptyCatalog() {
    let menu = BookmarkMenuProjection(document: [:], profile: "work", engine: "work")
    #expect(menu.folders.map(\.id) == ["bar@work", "other@work"])
    #expect(menu.recent.isEmpty)
    #expect(menu.bar.isEmpty)
    #expect(menu.other.isEmpty)
    #expect(!BookmarkMenuProjection.contains(url: "https://example.com", document: [:], profile: "work", engine: "work"))
  }

  @Test func orderedFoldersAndRecentBookmarksStayWithinTheProfile() {
    let document: JSONValue = [
      "roots": ["work": ["bar": "bar", "other": "other"]],
      "nodes": [
        "bar": ["kind": "folder", "children": ["folder", "b"]],
        "other": ["kind": "folder", "children": ["a"]],
        "folder": ["kind": "folder", "title": "Folder", "parentId": "bar", "children": ["nested"]],
        "a": ["kind": "url", "parentId": "other", "url": "https://a.example", "title": "", "addedAt": 4],
        "b": ["kind": "url", "parentId": "bar", "url": "https://b.example", "title": "B", "addedAt": 3],
        "foreign": ["kind": "url", "parentId": "elsewhere", "url": "https://foreign.example", "addedAt": 9],
        "nested": ["kind": "url", "parentId": "folder", "url": "https://nested.example", "addedAt": 5],
      ],
    ]
    let menu = BookmarkMenuProjection(document: document, profile: "work", engine: "work")
    #expect(menu.folders.map(\.id) == ["bar", "other", "folder"])
    #expect(menu.recent.map(\.id) == ["nested", "a", "b"])
    #expect(menu.recent.map(\.title) == ["https://nested.example", "https://a.example", "B"])
    #expect(menu.bar.first?.children?.map(\.id) == ["nested"])
    #expect(BookmarkMenuProjection.contains(url: "https://nested.example", document: document, profile: "work", engine: "work"))
    #expect(!BookmarkMenuProjection.contains(url: "https://foreign.example", document: document, profile: "work", engine: "work"))
  }
}
