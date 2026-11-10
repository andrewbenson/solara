import Foundation
import SolaraEngine
import SolaraModel

enum NativeBookmarkWriter {
  static func state() -> [String: Any] {
    let state = NativeBookmarkOwner.ownershipState
    var result: [String: Any] = ["state": state.phase.rawValue]
    if let reason = state.reason { result["reason"] = reason }
    if state.phase == .owned, let owner = NativeBookmarkOwner.current { result["generation"] = String(owner.currentGeneration) }
    return result
  }

  static func projection() throws -> String {
    guard let owner = NativeBookmarkOwner.displayCurrent else { throw BookmarkWriterError.notOwned }
    return try owner.projection().bookmarkText()
  }

  static func snapshot(profile: String) throws -> [String: Any] {
    let owner = try admittedOwner()
    let snapshot = try owner.snapshot(profile: profile)
    return [
      "engine": snapshot.binding.engine, "generation": String(snapshot.binding.generation),
      "revision": String(snapshot.revision), "ready": snapshot.ready, "hasView": snapshot.hasView, "readyForSync": snapshot.ready, "document": snapshot.document.bookmarkText(),
      "wireDocument": snapshot.wireDocument.bookmarkText(),
      "wireBaselineKeys": JSONValue(snapshot.wireBaselineKeys).bookmarkText(),
      "facts": JSONValue.object(snapshot.facts.mapValues { fact in
        .object(["at": .number(fact.at), "seq": .string(String(fact.seq)), "after": JSONValue(fact.after), "link": .string(fact.link)])
      }).bookmarkText(),
    ]
  }

  static func ackBookmarkFacts(profile: String, engine: String, recordsJSON: String, link: String? = nil, generation: String) throws -> Bool {
    let owner = try admittedOwner()
    guard let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("generation must be a decimal string") }
    let records = try factRecords(recordsJSON).map { item -> (key: String, seq: UInt64, mintedHLC: String) in
      guard let key = item["key"]?.string, let seq = item["seq"]?.string.flatMap(UInt64.init), let hlc = item["mintedHLC"]?.string else { throw BookmarkWriterError.invalidDocument("each ack needs key, decimal-string seq and mintedHLC") }
      return (key, seq, hlc)
    }
    return try owner.ackBookmarkFacts(profileId: profile, expectedEngine: engine, records: records, expectedLink: link.map(BookmarkString.encode), generation: generation)
  }

  static func observeBookmarkRecords(profile: String, engine: String, recordsJSON: String, link: String? = nil, generation: String) throws -> Bool {
    let owner = try admittedOwner()
    guard let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("generation must be a decimal string") }
    let records = try factRecords(recordsJSON).map { item -> (key: String, hlc: String) in
      guard let key = item["key"]?.string, let hlc = item["hlc"]?.string else { throw BookmarkWriterError.invalidDocument("each observation needs key and hlc") }
      return (key, hlc)
    }
    return try owner.observeRemoteRecords(profileId: profile, expectedEngine: engine, records: records, expectedLink: link.map(BookmarkString.encode), generation: generation)
  }

  static func clearBookmarkFacts(profile: String, engine: String, recordsJSON: String, generation: String) throws -> Bool {
    let owner = try admittedOwner()
    guard let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("generation must be a decimal string") }
    let records = try factRecords(recordsJSON).map { item -> (key: String, seq: UInt64) in
      guard let key = item["key"]?.string, let seq = item["seq"]?.string.flatMap(UInt64.init) else { throw BookmarkWriterError.invalidDocument("each clear needs key and decimal-string seq") }
      return (key, seq)
    }
    return try owner.clearBookmarkFacts(profileId: profile, expectedEngine: engine, records: records, generation: generation)
  }

  static func setBookmarkSyncLinks(linksJSON: String) throws -> Bool {
    let owner = try admittedOwner()
    let parsed: JSONValue
    do { parsed = try JSONValue.parseBookmark(linksJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    guard let object = parsed.object else { throw BookmarkWriterError.invalidDocument("links must be a profile-to-link object") }
    let links = try object.mapValues { value -> String in
      guard let link = value.string else { throw BookmarkWriterError.invalidDocument("each link must be a string") }
      return link
    }
    return owner.setBookmarkSyncLinks(links)
  }

  private static func factRecords(_ json: String) throws -> [JSONValue] {
    let parsed: JSONValue
    do { parsed = try JSONValue.parseBookmark(json) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    guard let records = parsed.array else { throw BookmarkWriterError.invalidDocument("records must be an array") }
    return records
  }

  static func replace(profile: String, documentJSON: String, expectedRevision: String, engine: String, generation: String, requestID: String?, recordsJSON: String = "[]", link: String? = nil) throws -> [String: Any] {
    let owner = try admittedOwner()
    guard let expected = UInt64(expectedRevision), let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("revision and generation must be decimal strings") }
    let document: JSONValue
    do { document = try JSONValue.parseBookmark(documentJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    let records = try factRecords(recordsJSON).map { item -> (key: String, hlc: String) in
      guard let key = item["key"]?.string, let hlc = item["hlc"]?.string else { throw BookmarkWriterError.invalidDocument("each observation needs key and hlc") }
      return (key, hlc)
    }
    let revision = try owner.replace(profile: profile, document: document, expectedRevision: expected, binding: BookmarkWriterBinding(engine: engine, generation: generation), requestID: requestID.map(BookmarkString.encode), records: records, expectedLink: link.map(BookmarkString.encode))
    return ["revision": String(revision)]
  }

  static func submit(profile: String, mutationsJSON: String, engine: String, generation: String, requestID: String?) throws -> [String: Any] {
    let owner = try admittedOwner()
    guard let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("generation must be a decimal string") }
    let parsed: JSONValue
    do { parsed = try JSONValue.parseBookmark(mutationsJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    guard let list = parsed.array else { throw BookmarkWriterError.invalidDocument("mutations must be an array") }
    let mutations = try list.map { item -> BookmarkMutation in
      guard let method = item["method"]?.string, let args = item["args"]?.array else { throw BookmarkWriterError.invalidDocument("each mutation needs a method and args") }
      return BookmarkMutation(method: method, args: args)
    }
    let receipt = try owner.submit(profile: profile, mutations: mutations, binding: BookmarkWriterBinding(engine: engine, generation: generation), requestID: requestID.map(BookmarkString.encode))
    return ["engine": receipt.view.engine, "revision": String(receipt.view.revision), "results": JSONValue.array(receipt.results).bookmarkText(), "document": receipt.view.document.bookmarkText()]
  }
  private static func admittedOwner() throws -> NativeBookmarkOwner {
    guard let owner = NativeBookmarkOwner.writableCurrent else { throw BookmarkWriterError.notOwned }
    return owner
  }

}
