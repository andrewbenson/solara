import Foundation
import SolaraEngine
import SolaraModel

final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []
  private var threads: [String] = []
  var failSyncDirectory = false

  func record(_ entry: String) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(entry)
    threads.append(Thread.isMainThread ? "main" : "\(pthread_mach_thread_np(pthread_self()))")
  }

  var log: [String] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  var threadLog: [String] {
    lock.lock()
    defer { lock.unlock() }
    return threads
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    entries = []
    threads = []
  }

  var operations: BookmarkPendingFileOperations {
    let live = BookmarkPendingFileOperations.live
    return BookmarkPendingFileOperations(
      read: { try live.read($0) },
      writeNew: { url, data in self.record("writeNew"); try live.writeNew(url, data) },
      syncFile: { url in self.record("syncFile"); try live.syncFile(url) },
      rename: { from, to in self.record("rename"); try live.rename(from, to) },
      syncDirectory: { url in
        self.record("syncDirectory")
        if self.failSyncDirectory { throw CocoaError(.fileWriteUnknown) }
        try live.syncDirectory(url)
      },
      remove: { try live.remove($0) },
      exists: { live.exists($0) })
  }
}

final class Fixture {
  let directory: URL
  let recorder = Recorder()
  var owner: NativeBookmarkOwner
  let wakes = Recorder()

  init() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-owner-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wakes = wakes
    let recorder = recorder
    owner = NativeBookmarkOwner(store: BookmarkPendingStore(directory: directory, fileOperations: recorder.operations), profiles: ["p": "", "alias": ""], defaultProfile: "p", wake: { engine in
      wakes.record("wake:\(engine) after \(recorder.log.filter { $0 == "syncDirectory" }.count) directory syncs")
    })
  }

  func reopen() -> NativeBookmarkOwner {
    NativeBookmarkOwner(store: BookmarkPendingStore(directory: directory), profiles: ["p": "", "alias": ""], defaultProfile: "p", wake: { _ in })
  }

  func stop() { try? FileManager.default.removeItem(at: directory) }

  static func document(_ urls: [String]) -> JSONValue {
    var nodes: JSONObject = ["bar@default": ["id": "bar@default", "kind": "folder", "parentId": nil, "title": "Bookmarks Bar", "children": .array(urls.indices.map { .string("b\($0)") }), "addedAt": 0], "other@default": ["id": "other@default", "kind": "folder", "parentId": nil, "title": "Other Bookmarks", "children": [], "addedAt": 0]]
    for (i, url) in urls.enumerated() { nodes["b\(i)"] = ["id": .string("b\(i)"), "kind": "url", "parentId": "bar@default", "title": "Page", "url": .string(url), "favicon": nil, "addedAt": 10] }
    return ["nodes": .object(nodes), "roots": ["p": ["bar": "bar@default", "other": "other@default"], "alias": ["bar": "bar@default", "other": "other@default"]]]
  }
}

nonisolated(unsafe) var failures: [String] = []
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

func refusal(_ body: () throws -> Void) -> BookmarkWriterError? {
  do { try body(); return nil } catch let error as BookmarkWriterError { return error } catch { return .refused("unexpected \(error)") }
}

@main
struct BookmarkOwnerTests {
  static func replaceIsDurableBeforeItReturns() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    let document = Fixture.document(["https://a.test", "https://b.test"])
    let revision = try? fixture.owner.replace(profile: "p", document: document, expectedRevision: before.revision, binding: before.binding, requestID: "remote-1")
    let log = fixture.recorder.log
    expect(revision == before.revision + 1, "an accepted replacement advances the revision")
    expect(Array(log.suffix(4)) == ["writeNew", "syncFile", "rename", "syncDirectory"], "the journal is written, synced, renamed and its directory synced before replace returns: \(log)")
    let reopened = try! fixture.reopen().snapshot(profile: "p")
    expect(reopened.document == document && reopened.revision == revision, "a fresh owner on the same folder sees the accepted document")
  }

  static func replaceRunsOnTheCallingThread() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    let owner = fixture.owner
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var caller = ""
    nonisolated(unsafe) var returned = false
    let thread = Thread {
      caller = "\(pthread_mach_thread_np(pthread_self()))"
      returned = (try? owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding)) != nil
      done.signal()
    }
    thread.start()
    expect(done.wait(timeout: .now() + 5) == .success, "replace returns without the main thread")
    expect(returned, "the replacement was accepted")
    let threads = fixture.recorder.threadLog
    expect(!threads.isEmpty && threads.allSatisfy { $0 == caller }, "every journal write ran on the calling thread: \(threads) vs \(caller)")
  }

  static func aRemapRefusesTheOldBindingAndWritesNothing() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    fixture.owner.remap(profiles: ["p": "other", "alias": ""], defaultProfile: "p")
    fixture.recorder.clear()
    let error = refusal { try fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding) }
    expect(error == .staleBinding, "a binding from before the remap is refused, got \(String(describing: error))")
    expect(fixture.recorder.log.isEmpty, "a refused replacement writes no journal")
    expect(fixture.wakes.log.isEmpty, "a refused replacement wakes nothing")
    let same = try! fixture.owner.snapshot(profile: "alias")
    fixture.owner.remap(profiles: ["p": "other", "alias": "", "extra": ""], defaultProfile: "p")
    let sameEngine = refusal { try fixture.owner.replace(profile: "alias", document: Fixture.document(["https://a.test"]), expectedRevision: same.revision, binding: same.binding) }
    expect(sameEngine == nil, "a remap that keeps the profile on the same engine accepts the older generation, got \(String(describing: sameEngine))")
  }

  static func aBindingForAnotherEngineIsRefused() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    fixture.recorder.clear()
    let wrong = BookmarkWriterBinding(engine: "Profile 2", generation: before.binding.generation)
    let error = refusal { try fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: wrong) }
    expect(error == .staleBinding, "a binding naming another engine is refused, got \(String(describing: error))")
    expect(fixture.recorder.log.isEmpty, "nothing is written for another engine's binding")
  }

  static func aStaleRevisionIsRefused() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    let setup = try? fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding)
    let accepted = try! fixture.owner.snapshot(profile: "p")
    guard setup == before.revision + 1, accepted.revision == before.revision + 1 else {
      failures.append("the setup replacement must be accepted before a stale revision can be tested")
      return
    }
    fixture.wakes.clear()
    fixture.recorder.clear()
    let error = refusal { try fixture.owner.replace(profile: "p", document: Fixture.document(["https://b.test"]), expectedRevision: before.revision, binding: before.binding) }
    if case .refused = error {} else { failures.append("a replacement against an old revision is refused, got \(String(describing: error))") }
    expect(try! fixture.owner.snapshot(profile: "p").document == accepted.document, "the refused document is not taken")
    expect(fixture.wakes.log.isEmpty, "a stale revision wakes nothing")
    expect(fixture.recorder.log.isEmpty, "a stale revision is refused before any journal write")
  }

  static func theWakeComesOnlyAfterTheDirectorySync() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    fixture.recorder.clear()
    _ = try? fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding)
    expect(fixture.wakes.log == ["wake: after 1 directory syncs"], "one wake, after the journal directory sync: \(fixture.wakes.log)")
  }

  static func aJournalFailureThrowsAndKeepsTheOldDocument() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    fixture.recorder.failSyncDirectory = true
    let error = refusal { try fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding) }
    if case .refused = error {} else { failures.append("a journal failure throws, got \(String(describing: error))") }
    let after = try! fixture.owner.snapshot(profile: "p")
    expect(after.revision == before.revision && after.document == before.document, "a failed journal write leaves the old document and revision")
    expect(fixture.wakes.log.isEmpty, "a failed journal write wakes nothing")
  }

  static func theWriterIsLegacyUntilAnOwnerIsInstalled() {
    let fixture = Fixture()
    defer { fixture.stop(); NativeBookmarkOwner.current = nil }
    NativeBookmarkOwner.current = nil
    expect(NativeBookmarkWriter.state()["state"] as? String == "legacy", "no owner means the JS writer")
    expect((try? NativeBookmarkWriter.snapshot(profile: "p")) == nil, "no snapshot without an owner")
    expect(refusal { _ = try NativeBookmarkWriter.replace(profile: "p", documentJSON: "{}", expectedRevision: "0", engine: "", generation: "1", requestID: nil) } == .notOwned, "no replacement without an owner")
    NativeBookmarkOwner.current = fixture.owner
    let state = NativeBookmarkWriter.state()
    expect(state["state"] as? String == "owned" && state["generation"] as? String == "1", "an installed owner reports owned and its generation: \(state)")
    guard let snapshot = try? NativeBookmarkWriter.snapshot(profile: "p"), let revision = snapshot["revision"] as? String, let generation = snapshot["generation"] as? String, let engine = snapshot["engine"] as? String else {
      failures.append("an installed owner gives a snapshot")
      return
    }
    let reply = try? NativeBookmarkWriter.replace(profile: "p", documentJSON: Fixture.document(["https://a.test"]).text(), expectedRevision: revision, engine: engine, generation: generation, requestID: "r")
    expect(reply?["revision"] as? String == String(UInt64(revision)! + 1), "the bridge accepts a document given as JSON text with decimal-string revisions: \(String(describing: reply))")
    expect(refusal { _ = try NativeBookmarkWriter.replace(profile: "p", documentJSON: "{", expectedRevision: revision, engine: engine, generation: generation, requestID: nil) }.map { if case .invalidDocument = $0 { true } else { false } } == true, "malformed JSON is refused as an invalid document")
  }

  static func submitIsDurableAndReturnsTheReducerResults() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    _ = try? fixture.owner.replace(profile: "p", document: Fixture.document(["https://a.test"]), expectedRevision: before.revision, binding: before.binding)
    let opened = try! fixture.owner.snapshot(profile: "p")
    fixture.recorder.clear()
    fixture.wakes.clear()
    let mutations = [BookmarkMutation(method: "addBookmark", args: [["profileId": "p", "title": "New", "url": "https://new.test"]]), BookmarkMutation(method: "updateBookmark", args: ["b0", ["title": "Renamed"]])]
    guard let receipt = try? fixture.owner.submit(profile: "p", mutations: mutations, binding: opened.binding, requestID: "edit-1") else {
      failures.append("an edit against the current binding is accepted")
      return
    }
    let log = fixture.recorder.log
    expect(Array(log.suffix(4)) == ["writeNew", "syncFile", "rename", "syncDirectory"], "the edit is journaled durably before submit returns: \(log)")
    expect(receipt.results.count == 2 && receipt.results[0].string != nil, "the receipt carries each mutation's result, the new id first: \(receipt.results)")
    let id = receipt.results[0].string ?? ""
    expect(receipt.view.document["nodes"]?[id]?["title"] == "New" && receipt.view.document["nodes"]?["b0"]?["title"] == "Renamed", "the receipt's view holds both edits")
    expect(fixture.wakes.log.count == 1, "one wake after the accepted edit")
    let reopened = try! fixture.reopen().snapshot(profile: "p")
    expect(reopened.document == receipt.view.document && reopened.revision == receipt.view.revision, "a fresh owner on the same folder sees the accepted edit")
  }

  static func submitRefusesAStaleBindingAndWritesNothing() {
    let fixture = Fixture()
    defer { fixture.stop() }
    let before = try! fixture.owner.snapshot(profile: "p")
    fixture.owner.remap(profiles: ["p": "other", "alias": "", "extra": ""], defaultProfile: "p")
    fixture.recorder.clear()
    let error = refusal { _ = try fixture.owner.submit(profile: "p", mutations: [BookmarkMutation(method: "addBookmarkFolder", args: [["profileId": "p", "title": "F"]])], binding: before.binding) }
    expect(error == .staleBinding, "an edit opened before a remap is refused, got \(String(describing: error))")
    expect(fixture.recorder.log.isEmpty && fixture.wakes.log.isEmpty, "a refused edit writes and wakes nothing")
  }

  static func theBridgeSubmitsMutationsGivenAsJSON() {
    let fixture = Fixture()
    defer { fixture.stop(); NativeBookmarkOwner.current = nil }
    NativeBookmarkOwner.current = fixture.owner
    let snapshot = try! fixture.owner.snapshot(profile: "p")
    let reply = try? NativeBookmarkWriter.submit(profile: "p", mutationsJSON: #"[{"method":"addBookmarkFolder","args":[{"profileId":"p","title":"Folder"}]}]"#, engine: snapshot.binding.engine, generation: String(snapshot.binding.generation), requestID: "r")
    guard let reply, let results = reply["results"] as? String, let document = reply["document"] as? String, let revision = reply["revision"] as? String,
      let ids = try? JSONValue.parse(results).array, let id = ids.first?.string, let parsed = try? JSONValue.parse(document) else {
      failures.append("the bridge answers with revision, results and document as JSON text: \(String(describing: reply))")
      return
    }
    expect(parsed["nodes"]?[id]?["kind"] == "folder", "the reply's document holds the new folder")
    expect(revision == String(snapshot.revision + 1), "the reply's revision is the accepted one")
    expect(refusal { _ = try NativeBookmarkWriter.submit(profile: "p", mutationsJSON: #"[{"method":"addBookmarkFolder"}]"#, engine: snapshot.binding.engine, generation: String(snapshot.binding.generation), requestID: nil) }.map { if case .invalidDocument = $0 { true } else { false } } == true, "a mutation without args is refused before it reaches the coordinator")
  }

  static func main() {
    guard CommandLine.arguments.count == 2 else {
      print("FAIL: expected one case name")
      exit(1)
    }
    let test = CommandLine.arguments[1]
    let cases: [String: () -> Void] = [
      "replaceIsDurableBeforeItReturns": replaceIsDurableBeforeItReturns,
      "replaceRunsOnTheCallingThread": replaceRunsOnTheCallingThread,
      "aRemapRefusesTheOldBindingAndWritesNothing": aRemapRefusesTheOldBindingAndWritesNothing,
      "aBindingForAnotherEngineIsRefused": aBindingForAnotherEngineIsRefused,
      "aStaleRevisionIsRefused": aStaleRevisionIsRefused,
      "theWakeComesOnlyAfterTheDirectorySync": theWakeComesOnlyAfterTheDirectorySync,
      "aJournalFailureThrowsAndKeepsTheOldDocument": aJournalFailureThrowsAndKeepsTheOldDocument,
      "theWriterIsLegacyUntilAnOwnerIsInstalled": theWriterIsLegacyUntilAnOwnerIsInstalled,
      "submitIsDurableAndReturnsTheReducerResults": submitIsDurableAndReturnsTheReducerResults,
      "submitRefusesAStaleBindingAndWritesNothing": submitRefusesAStaleBindingAndWritesNothing,
      "theBridgeSubmitsMutationsGivenAsJSON": theBridgeSubmitsMutationsGivenAsJSON,
    ]
    guard let run = cases[test] else {
      print("FAIL \(test): unknown test")
      exit(1)
    }
    run()
    for failure in failures { print("FAIL \(test): \(failure)") }
    if failures.isEmpty { print("PASS \(test)") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
