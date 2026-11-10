import Foundation
import Testing
import SolaraModel
@testable import SolaraEngine

struct BookmarkPendingStoreIOTests {
  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BookmarkScratch-IO-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  @Test func journalRoundTripUsesFileAndDirectorySyncBeforeReturning() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let events = BookmarkIOEvents()
    var operations = BookmarkPendingFileOperations.live
    let write = operations.writeNew
    let syncFile = operations.syncFile
    let rename = operations.rename
    let syncDirectory = operations.syncDirectory
    operations.writeNew = { url, data in events.values.append("write"); try write(url, data) }
    operations.syncFile = { url in events.values.append("fileSync"); try syncFile(url) }
    operations.rename = { source, target in events.values.append("rename"); try rename(source, target) }
    operations.syncDirectory = { url in events.values.append("directorySync"); try syncDirectory(url) }
    let store = BookmarkPendingStore(directory: dir, fileOperations: operations)
    let payload: JSONValue = ["engines": [["engine": "", "desired": ["title": "e\u{301}"]]]]
    try store.write(payload)
    #expect(events.values == ["write", "fileSync", "rename", "directorySync"])
    #expect(BookmarkPendingStore(directory: dir).load().payload == payload)
  }

  @Test func corruptJournalIsMovedAsideByteIdenticallyAndLogged() throws {
    for bytes in [Data(), Data("{".utf8), Data("not json".utf8), Data("{\"version\":1,\"payload\":{},\"checksum\":\"bad\"}".utf8), Data("{}".utf8), Data("[1,2]".utf8), Data("{\"format\":\"bookmarks-v2\",\"entries\":[]}".utf8)] {
      let dir = try directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
      try bytes.write(to: path)
      let events = BookmarkIOEvents()
      let loaded = BookmarkPendingStore(directory: dir, clock: { 1234 }, logger: { events.values.append($0) }).load()
      #expect(loaded.payload == nil)
      #expect(!loaded.writable)
      let notice = try #require(loaded.recoveryNotice)
      #expect(notice.kind == .unreadableJournal)
      let preserved = try #require(notice.preservedPath)
      #expect(preserved.contains("1234"))
      #expect(try Data(contentsOf: URL(fileURLWithPath: preserved)) == bytes)
      #expect(!FileManager.default.fileExists(atPath: path.path))
      #expect(events.values.count == 1)
    }
  }

  @Test func newerJournalVersionIsUntouchedIncludingMtimeAndNeverAdopted() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = Data("{\"version\":999,\"payload\":{\"future\":true}}".utf8)
    try bytes.write(to: path)
    let modified = Date(timeIntervalSince1970: 17)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
    let store = BookmarkPendingStore(directory: dir)
    let loaded = store.load()
    #expect(loaded.payload == nil)
    #expect(!loaded.writable)
    #expect(loaded.recoveryNotice?.kind == .newerJournalVersion)
    #expect(throws: (any Error).self) { try store.write(["overwrite": true]) }
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [BookmarkPendingStore.journalName])
  }

  @Test(arguments: ["{\"version\":\"2\",\"payload\":{}}", "{\"version\":1.5}", "{\"version\":null,\"payload\":{}}"])
  func parsedJournalWithAnotherVersionStaysInPlaceReadOnly(_ text: String) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = Data(text.utf8)
    try bytes.write(to: path)
    let modified = Date(timeIntervalSince1970: 23)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
    let store = BookmarkPendingStore(directory: dir)
    let loaded = store.load()
    #expect(loaded.payload == nil)
    #expect(!loaded.writable)
    #expect(loaded.recoveryNotice?.kind == .newerJournalVersion)
    #expect(throws: (any Error).self) { try store.write(["overwrite": true]) }
    #expect(try Data(contentsOf: path) == bytes)
    #expect(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [BookmarkPendingStore.journalName])
  }

  @Test func crashBeforeRenameKeepsPreviousJournalAndIgnoresTornTemporaryFile() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let before: JSONValue = ["desired": "old"]
    try BookmarkPendingStore(directory: dir).write(before)
    var operations = BookmarkPendingFileOperations.live
    operations.rename = { _, _ in throw BookmarkInjectedIOFailure.crash }
    operations.remove = { _ in }
    let store = BookmarkPendingStore(directory: dir, fileOperations: operations)
    #expect(throws: (any Error).self) { try store.write(["desired": "new"]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".tmp-") })
    #expect(BookmarkPendingStore(directory: dir).load().payload == before)
    operations = .live
    let write = operations.writeNew
    operations.writeNew = { url, data in try write(url, Data(data.prefix(data.count / 2))); throw BookmarkInjectedIOFailure.crash }
    operations.remove = { _ in }
    #expect(throws: (any Error).self) { try BookmarkPendingStore(directory: dir, fileOperations: operations).write(["desired": "torn"]) }
    #expect(BookmarkPendingStore(directory: dir).load().payload == before)
  }

  @Test func failureAfterRenameNeverReportsSuccessAndFailsClosedUntilRelaunch() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try BookmarkPendingStore(directory: dir).write(["desired": "old"])
    var operations = BookmarkPendingFileOperations.live
    operations.syncDirectory = { _ in throw BookmarkInjectedIOFailure.crash }
    let store = BookmarkPendingStore(directory: dir, fileOperations: operations)
    #expect(throws: (any Error).self) { try store.write(["desired": "new"]) }
    #expect(throws: (any Error).self) { try store.write(["desired": "third"]) }
    #expect(BookmarkPendingStore(directory: dir).load().payload == ["desired": "new"])
  }

  @Test func validEnvelopeWithUnreadableCoordinatorPayloadCanBePreserved() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BookmarkPendingStore(directory: dir, clock: { 2000 })
    try store.write(["wrongSchema": true])
    let original = try Data(contentsOf: store.journalURL)
    let loaded = store.recoverUnreadable(reason: "invalid checkpoint")
    #expect(loaded.payload == nil)
    #expect(!loaded.writable)
    let preserved = try #require(loaded.recoveryNotice?.preservedPath)
    #expect(try Data(contentsOf: URL(fileURLWithPath: preserved)) == original)
  }

  @Test func unreadableJournalThatCannotBePreservedBlocksWritesWithoutBlockingLoad() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(BookmarkPendingStore.journalName)
    let bytes = Data("{broken".utf8)
    try bytes.write(to: path)
    var operations = BookmarkPendingFileOperations.live
    operations.rename = { _, _ in throw BookmarkInjectedIOFailure.crash }
    let store = BookmarkPendingStore(directory: dir, fileOperations: operations)
    let loaded = store.load()
    #expect(!loaded.writable)
    #expect(loaded.recoveryNotice != nil)
    #expect(throws: (any Error).self) { try store.write([:]) }
    #expect(try Data(contentsOf: path) == bytes)
  }
}

private final class BookmarkIOEvents {
  var values: [String] = []
}

private enum BookmarkInjectedIOFailure: Error {
  case crash
}
