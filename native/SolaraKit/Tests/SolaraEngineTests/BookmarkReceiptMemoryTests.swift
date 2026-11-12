import Darwin
import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkReceiptMemoryTests {
  private func document(_ count: Int) -> JSONValue {
    var nodes: JSONObject = [
      "bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": .array((0..<count).map { .string("b\($0)") }), "addedAt": 0],
      "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0],
    ]
    for index in 0..<count {
      nodes["b\(index)"] = ["id": .string("b\(index)"), "kind": "url", "parentId": "bar@default", "title": "Page", "url": .string("https://bookmark-\(index).example.test/path"), "favicon": nil, "addedAt": 10]
    }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": "bar@default", "other": "other@default"]]]
  }

  private func mutation(_ edit: Int) -> BookmarkMutation {
    .init(method: "updateBookmark", args: ["b0", ["title": .string("Edited \(edit)")]])
  }

  private func heapBytes() -> UInt64 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return UInt64(statistics.size_in_use)
  }

  @Test func firstReceiptRemainsOriginalAfterOneThousandLaterRequests() throws {
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 123 }, stampsEnabled: true)
    owner.seed(engine: "", document: document(8), ready: true)
    let accepted = try owner.submit(profile: "p", mutations: [mutation(0)], requestID: "first")
    for edit in 1...1000 {
      try owner.submit(profile: "p", mutations: [mutation(edit)], requestID: "edit-\(edit)")
    }
    let current = owner.desiredView(engine: "")
    let retried = try owner.submit(profile: "p", mutations: [mutation(0)], requestID: "first")
    #expect(retried == accepted)
    #expect(retried.view.document["nodes"]?["b0"]?["title"] == "Edited 0")
    #expect(retried.view.facts["bm:b0"]?.seq == 1)
    #expect(owner.desiredView(engine: "") == current)
    #expect(current.document["nodes"]?["b0"]?["title"] == "Edited 1000")
    #expect(throws: BookmarkCoordinatorError.conflictingRequest) {
      try owner.submit(profile: "p", mutations: [mutation(1001)], requestID: "first")
    }
  }

  @Test func originalReceiptSurvivesLaterDurableRequestsAndRestart() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkReceiptScratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    var owner: BookmarkCoordinator? = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 123 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
    owner!.seed(engine: "", document: document(50), ready: false)
    let accepted = try owner!.submit(profile: "p", mutations: [mutation(0)], requestID: "first")
    for edit in 1...8 {
      try owner!.submit(profile: "p", mutations: [mutation(edit)], requestID: "edit-\(edit)")
    }
    let latest = owner!.desiredView(engine: "")
    #expect(owner!.completeRead(engine: "", document: latest.document, capturedRevision: latest.revision))
    #expect(owner!.pumpInput(engine: "", epoch: 0)?.1.isEmpty == true)
    let path = directory.appendingPathComponent(BookmarkPendingStore.journalName)
    let before = try Data(contentsOf: path)
    owner = nil
    let restored = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { 456 }, stampsEnabled: true, pendingStore: BookmarkPendingStore(directory: directory))
    let retried = try restored.submit(profile: "p", mutations: [mutation(0)], requestID: "first")
    #expect(retried == accepted)
    #expect(restored.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 8")
    #expect(try Data(contentsOf: path) == before)
    #expect(throws: BookmarkCoordinatorError.conflictingRequest) {
      try restored.submit(profile: "p", mutations: [mutation(9)], requestID: "first")
    }
    #expect(try Data(contentsOf: path) == before)
    print("BOOKMARK_DURABLE bookmarks=50 requests=9 journal_bytes=\(before.count)")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLARA_BOOKMARK_MEMORY"] == "1"))
  func measureFiveThousandBookmarksAfterOneThousandEdits() throws {
    let environment = ProcessInfo.processInfo.environment
    let retainsRequests = environment["SOLARA_BOOKMARK_MEMORY_CONTROL"] != "1"
    let settled = environment["SOLARA_BOOKMARK_MEMORY_SETTLED"] == "1"
    var clock = 0.0
    let owner = BookmarkCoordinator(profiles: ["p": ""], defaultProfile: "p", now: { clock }, stampsEnabled: true)
    owner.seed(engine: "", document: document(5000), ready: true)
    let initialHeap = heapBytes()
    let start = Date()
    print("BOOKMARK_MEMORY mode=\(retainsRequests ? "requests" : "control") bookmarks=5000 edits=0 heap_bytes=\(initialHeap)")
    fflush(nil)
    var first: BookmarkReceipt?
    for edit in 1...1000 {
      if settled { clock = Double(edit - 1) * 10_000 }
      let receipt = try owner.submit(profile: "p", mutations: [mutation(edit)], requestID: retainsRequests ? "edit-\(edit)" : nil)
      if edit == 1 { first = receipt }
      if settled && retainsRequests { #expect(try owner.acknowledgeReceipt(requestID: "edit-\(edit)", engine: "")) }
      if settled && edit % 10 == 0 {
        let view = owner.desiredView(engine: "")
        let read = owner.beginReceiptRead(engine: "", epoch: 0)
        #expect(owner.completeRead(engine: "", document: view.document, capturedRevision: view.revision, receiptRead: read))
        let facts = owner.bookmarkFacts(profileId: "p")
        #expect(try owner.clearBookmarkFacts(profileId: "p", expectedEngine: "", records: facts.map { (key: $0.key, seq: $0.value.seq) }))
      }
      if [1, 10, 100, 500, 1000].contains(edit) {
        let heap = heapBytes()
        print("BOOKMARK_MEMORY mode=\(retainsRequests ? "requests" : "control") bookmarks=5000 edits=\(edit) heap_bytes=\(heap) growth_bytes=\(Int64(heap) - Int64(initialHeap)) seconds=\(Date().timeIntervalSince(start))")
        fflush(nil)
      }
    }
    if retainsRequests && settled {
      #expect(throws: BookmarkCoordinatorError.expiredRequest) {
        try owner.submit(profile: "p", mutations: [mutation(1)], requestID: "edit-1")
      }
      #expect(throws: BookmarkCoordinatorError.expiredRequest) {
        try owner.submit(profile: "p", mutations: [mutation(968)], requestID: "edit-968")
      }
      let newestFloor = try owner.submit(profile: "p", mutations: [mutation(969)], requestID: "edit-969")
      #expect(newestFloor.view.document["nodes"]?["b0"]?["title"] == "Edited 969")
      #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 1000")
    } else if retainsRequests {
      let retried = try owner.submit(profile: "p", mutations: [mutation(1)], requestID: "edit-1")
      #expect(retried == first)
      #expect(retried.view.document["nodes"]?["b0"]?["title"] == "Edited 1")
      #expect(owner.desiredView(engine: "").document["nodes"]?["b0"]?["title"] == "Edited 1000")
    }
    let finalHeap = heapBytes()
    print("BOOKMARK_MEMORY_FINAL settled=\(settled) cadence_ms=\(settled ? 10_000 : 0) confirmation_batch=\(settled ? 10 : 0) mode=\(retainsRequests ? "requests" : "control") heap_bytes=\(finalHeap) growth_bytes=\(Int64(finalHeap) - Int64(initialHeap)) bytes_per_edit=\((Int64(finalHeap) - Int64(initialHeap)) / 1000) elapsed_seconds=\(Date().timeIntervalSince(start))")
    print("BOOKMARK_MEMORY_SERIALIZED first_receipt_view_bytes=\(BookmarkDurability.encodeView(try #require(first).view).bookmarkText().utf8.count)")
    fflush(nil)
    if let limit = environment["SOLARA_BOOKMARK_MEMORY_LIMIT_BYTES"].flatMap(Int64.init) {
      #expect(Int64(finalHeap) - Int64(initialHeap) < limit)
    }
    if retainsRequests {
      try owner.retire(engine: "")
      print("BOOKMARK_MEMORY_RETIRED heap_bytes=\(heapBytes())")
      fflush(nil)
    }
    withExtendedLifetime(first) {}
    withExtendedLifetime(owner) {}
  }
}
