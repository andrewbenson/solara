#if SOLARA_PROBES
import Darwin
import Foundation
import Testing
@testable import SolaraProbes

struct ProbeTransportTests {
  @Test func aDirectoryEntryIsReadOnlyAsFarAsItsRecordGoes() throws {
    let page = Int(getpagesize())
    let region = try #require(mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0).flatMap { $0 == MAP_FAILED ? nil : $0 })
    defer { munmap(region, page * 2) }
    #expect(mprotect(region + page, page, PROT_NONE) == 0)
    let name = Array(".solara-probe-window-\(UUID().uuidString.lowercased()).png".utf8)
    let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
    let record = (nameOffset + name.count + 1 + 7) & ~7
    #expect(record < MemoryLayout<dirent>.size)
    let entry = (region + page - record).bindMemory(to: dirent.self, capacity: 1)
    memset(UnsafeMutableRawPointer(entry), 0, record)
    UnsafeMutableRawPointer(entry).storeBytes(of: UInt16(record), toByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_reclen)!, as: UInt16.self)
    UnsafeMutableRawPointer(entry).storeBytes(of: UInt16(name.count), toByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_namlen)!, as: UInt16.self)
    name.withUnsafeBytes { UnsafeMutableRawPointer(entry).advanced(by: nameOffset).copyMemory(from: $0.baseAddress!, byteCount: name.count) }
    #expect(ProbeFiles.entryName(entry) == String(decoding: name, as: UTF8.self))
  }

  private let id = UUID().uuidString

  private func request(_ changes: [String: Any] = [:]) -> Data {
    var value: [String: Any] = ["protocol": 1, "id": id, "command": "x", "args": [:], "expiresAtMs": 10_000]
    value.merge(changes) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: value)
  }

  @Test func replyPublicationConvertsSuccessExpiringDuringWriteToTimeout() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var time: Int64 = 0
    var gates = 0
    try ProbeReply.publish(["id": id, "protocol": 1, "result": ["delivered": true]], id: id,
      expiresAtMs: 100, checkGate: {
        gates += 1
        if gates == 2 { time = 100 }
      }, nowMs: { time }, write: { payload, beforePublication in
        try files.reply(id: id, data: payload, beforePublication: beforePublication)
      })
    let published = try Data(contentsOf: data.appendingPathComponent("probes/outbox/\(id).json"))
    let object = try #require(JSONSerialization.jsonObject(with: published) as? [String: Any])
    #expect((object["error"] as? [String: String])?["code"] == "timeout")
    #expect(object["result"] == nil)
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/outbox/\(id).json.tmp").path))
  }

  @Test func replyPublicationSuppressesRevokedGateAfterWriting() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var gates = 0
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeReply.publish(["id": id, "protocol": 1, "result": ["delivered": true]], id: id,
        expiresAtMs: 100, checkGate: {
          gates += 1
          if gates == 2 { throw ProbeFailure.testHooksDenied }
        }, nowMs: { 0 }, write: { payload, beforePublication in
          try files.reply(id: id, data: payload, beforePublication: beforePublication)
        })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("probes/outbox").path).isEmpty)
  }

  @Test func replyPublicationRechecksGateForTimeoutRetry() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var time: Int64 = 0
    var gates = 0
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeReply.publish(["id": id, "protocol": 1, "result": ["delivered": true]], id: id,
        expiresAtMs: 100, checkGate: {
          gates += 1
          if gates == 2 { time = 100 }
          if gates == 4 { throw ProbeFailure.testHooksDenied }
        }, nowMs: { time }, write: { payload, beforePublication in
          try files.reply(id: id, data: payload, beforePublication: beforePublication)
        })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("probes/outbox").path).isEmpty)
  }

  @Test func replyPublicationPreservesErrorsAfterExpiry() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try ProbeReply.publish(["id": id, "protocol": 1, "error": ["code": "notReady"]], id: id,
      expiresAtMs: 100, checkGate: {}, nowMs: { 100 }, write: { payload, beforePublication in
        try files.reply(id: id, data: payload, beforePublication: beforePublication)
      })
    let published = try Data(contentsOf: data.appendingPathComponent("probes/outbox/\(id).json"))
    let object = try #require(JSONSerialization.jsonObject(with: published) as? [String: Any])
    #expect((object["error"] as? [String: String])?["code"] == "notReady")
  }

  @Test func replyPublicationRunsAfterWritingBeforeRename() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("{}".utf8)
    var checked = false
    #expect(throws: ProbeFailure.notReady) {
      try files.reply(id: id, data: payload, beforePublication: {
        checked = true
        #expect(try Data(contentsOf: data.appendingPathComponent("probes/outbox/\(id).json.tmp")) == payload)
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/outbox/\(id).json").path))
        throw ProbeFailure.notReady
      })
    }
    #expect(checked)
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("probes/outbox").path).isEmpty)
  }

  @Test func acceptsEnvelope() throws {
    let value = try ProbeRequest.decode(request(), nowMs: 1)
    #expect(value.id == id)
    #expect(value.command == "x")
  }

  @Test func rejectsEnvelope() {
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(Data("[1]".utf8), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(request(["extra": true]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidEnvelope) { try ProbeRequest.decode(request(["protocol": true]), nowMs: 1) }
    #expect(throws: ProbeFailure.unsupportedProtocol) { try ProbeRequest.decode(request(["protocol": 2]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidArgument) { try ProbeRequest.decode(request(["args": []]), nowMs: 1) }
    #expect(throws: ProbeFailure.invalidArgument) { try ProbeRequest.decode(request(["id": "bad"]), nowMs: 1) }
    #expect(throws: ProbeFailure.expired) { try ProbeRequest.decode(request(["expiresAtMs": 1]), nowMs: 1) }
    #expect(throws: ProbeFailure.expired) { try ProbeRequest.decode(request(["expiresAtMs": 90_000]), nowMs: 1) }
    #expect(throws: ProbeFailure.oversized) { try ProbeRequest.decode(Data(repeating: 32, count: 65_537), nowMs: 1) }
  }

  @Test func rejectsDuplicate() {
    var seen = ProbeSeenIds()
    let first = seen.insert(id)
    let second = seen.insert(id)
    #expect(first)
    #expect(!second)
  }

  @Test func rejectsWrongOwner() throws {
    let fd = Darwin.open(FileManager.default.temporaryDirectory.path, O_RDONLY | O_DIRECTORY)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.checkedDirectory(fd, owner: getuid() + 1) }
  }

  @Test func rejectsSymlinkedProbeDirectory() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("probes"), withDestinationURL: other)
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/claimed").path))
  }

  @Test func checksScratchGate() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    try files.recheck()
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: data.path, homePath: NSHomeDirectory()) }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: data.path)
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: link.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
    try FileManager.default.removeItem(at: data.appendingPathComponent(".solara-probe-scratch"))
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
    #expect(throws: ProbeFailure.testHooksDenied) { try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory()) }
  }

  @Test func acceptsTheRealPathOfAPrivateTempDir() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    #expect(root.path.hasPrefix("/private/"))
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    try files.recheck()
  }

  @Test func claimsRequestsAcrossPolls() throws {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    #expect(files.claim().isEmpty)
    for _ in 0..<2 {
      let next = UUID().uuidString
      try request().write(to: data.appendingPathComponent("probes/inbox/\(next).json"))
      #expect(files.claim().map(\.0) == [next])
    }
  }

  private func scratch() throws -> (URL, URL, ProbeFiles) {
    let root = URL(fileURLWithPath: ProbeFiles.realPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent(UUID().uuidString)
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data().write(to: data.appendingPathComponent(".solara-probe-scratch"))
    let files = try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    return (root, data, files)
  }

  @Test func aFifoInTheInboxDoesNotBlock() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    #expect(mkfifo(data.appendingPathComponent("probes/inbox/\(id).json").path, 0o600) == 0)
    let claimed = files.claim()
    #expect(claimed.count == 1)
    #expect(claimed.first?.1 == nil)
  }

  @Test func aPollClaimsABoundedBatch() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<(ProbeFiles.batch + 8) {
      try request().write(to: data.appendingPathComponent("probes/inbox/\(UUID().uuidString).json"))
    }
    #expect(files.claim().count == ProbeFiles.batch)
    #expect(files.claim().count == 8)
  }
  @Test func rejects0755ScratchOnOpen() throws {
    let (root, data, _) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    }
  }

  @Test func rejects0755ScratchOnRecheck() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
  }

  private func replaceMarkerWithFifo(_ data: URL) throws {
    let marker = data.appendingPathComponent(".solara-probe-scratch").path
    try FileManager.default.removeItem(atPath: marker)
    #expect(mkfifo(marker, 0o600) == 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      let writer = Darwin.open(marker, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
      if writer >= 0 { close(writer) }
    }
  }

  @Test func rejectsFifoMarkerPromptlyOnOpen() throws {
    let (root, data, _) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try replaceMarkerWithFifo(data)
    let start = ContinuousClock.now
    #expect(throws: ProbeFailure.testHooksDenied) {
      try ProbeFiles.open(dataPath: data.path, defaultPath: root.appendingPathComponent("default").path, homePath: NSHomeDirectory())
    }
    #expect(start.duration(to: .now) < .seconds(1))
  }

  @Test func rejectsFifoMarkerPromptlyOnRecheck() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try replaceMarkerWithFifo(data)
    let start = ContinuousClock.now
    #expect(throws: ProbeFailure.testHooksDenied) { try files.recheck() }
    #expect(start.duration(to: .now) < .seconds(1))
  }

  @Test func replyRechecksTransportBeforeWriting() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: data.appendingPathComponent(".solara-probe-scratch"))
    let id = UUID().uuidString
    #expect(throws: ProbeFailure.testHooksDenied) { try files.reply(id: id, data: Data("{}".utf8)) }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/outbox/\(id).json").path))
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("probes/outbox/\(id).json.tmp").path))
  }

  private func artifactName() -> String { ".solara-probe-window-\(UUID().uuidString.lowercased()).png" }

  @Test func artifactPublicationRechecksAfterWritingAndRemovesDeniedOutput() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for failure in [ProbeFailure.timeout, .testHooksDenied, .notReady] {
      let name = artifactName()
      var checked = false
      #expect(throws: failure) {
        try files.writeArtifact(name: name, data: Data([1, 2, 3]), beforePublication: {
          checked = true
          #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(name).path))
          #expect(try Data(contentsOf: data.appendingPathComponent(name + ".tmp")) == Data([1, 2, 3]))
          throw failure
        })
      }
      #expect(checked)
      #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(name).path))
      #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(name + ".tmp").path))
    }
  }

  @Test func artifactPublicationKeepsExistingOutput() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let name = artifactName()
    try files.writeArtifact(name: name, data: Data([1]))
    #expect(throws: ProbeFailure.testHooksDenied) { try files.writeArtifact(name: name, data: Data([2])) }
    #expect(try Data(contentsOf: data.appendingPathComponent(name)) == Data([1]))
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(name + ".tmp").path))
  }

  @Test func refusesArtifactBeyondCountBudget() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<32 { try files.writeArtifact(name: artifactName(), data: Data([1])) }
    let extra = artifactName()
    do {
      try files.writeArtifact(name: extra, data: Data([1]))
      Issue.record("An artifact beyond the count budget was accepted")
    } catch { #expect((error as? ProbeFailure)?.code == "artifactBudgetExceeded") }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(extra).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).filter { $0.hasSuffix(".png") }.count == 32)
  }

  @Test func refusesArtifactBeyondAggregateByteBudget() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = data.appendingPathComponent(artifactName())
    #expect(FileManager.default.createFile(atPath: existing.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: existing)
    try handle.truncate(atOffset: 268_435_455)
    try handle.close()
    let extra = artifactName()
    do {
      try files.writeArtifact(name: extra, data: Data([1, 2]))
      Issue.record("An artifact beyond the aggregate byte budget was accepted")
    } catch { #expect((error as? ProbeFailure)?.code == "artifactBudgetExceeded") }
    #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(extra).path))
    try files.writeArtifact(name: artifactName(), data: Data([1]))
    do {
      try files.writeArtifact(name: artifactName(), data: Data([1]))
      Issue.record("An artifact at a full aggregate byte budget was accepted")
    } catch { #expect((error as? ProbeFailure)?.code == "artifactBudgetExceeded") }
  }

  @Test func clearStaleRemovesOnlyArtifactsOlderThanProcess() throws {
    let (root, data, files) = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = data.appendingPathComponent(artifactName())
    let fresh = data.appendingPathComponent(artifactName())
    let current = data.appendingPathComponent(artifactName())
    let unrelated = data.appendingPathComponent("fixture.png")
    let invalid = data.appendingPathComponent(".solara-probe-window-not-a-uuid.png")
    for item in [old, fresh, current, unrelated, invalid] { try Data([1]).write(to: item) }
    for item in [old, unrelated, invalid] {
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: item.path)
    }
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fresh.path)
    files.clearStale()
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(FileManager.default.fileExists(atPath: invalid.path))
  }

}
#endif
