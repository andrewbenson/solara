import Testing
@testable import SolaraEngine

struct BookmarkRecordKeyParityTests {
  @Test(arguments: [
    ("bm-1", "de8f26f1-cf94-4896-bcf5-f260fa6f106a"),
    ("abc", "de16fab4-dc3b-4cf3-a057-00a3b7f5c27c"),
    ("toolbar_____", "1ca6d882-c96b-41a4-a5b8-42c023810ed5"),
    ("é😀", "89af5e08-1d32-495b-b71a-95a7466621cd"),
    ("DEADBEEF-0000-4000-8000-000000000000", "a37681a8-c0f8-424e-8766-bdaae56e0d94"),
  ])
  func legacyUuidMatchesTheJavaScriptStore(syncKey: String, uuid: String) {
    #expect(BookmarkRecordIdentity.bookmarkUuidFor(syncKey) == uuid)
    #expect(BookmarkRecordIdentity.key(id: uuid, node: ["syncKey": .string(syncKey)]) == "bm:\(syncKey)")
    #expect(BookmarkRecordIdentity.key(id: "other-id", node: ["syncKey": .string(syncKey)]) == "bm:other-id")
  }

  @Test func aUuidIsItsOwnLegacyUuid() {
    let id = "0b9c2e1a-3f4d-4e5f-8a6b-7c8d9e0f1a2b"
    #expect(BookmarkRecordIdentity.bookmarkUuidFor(id) == id)
  }
}
