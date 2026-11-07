import Foundation
import SolaraEngine
import SolaraModel

enum NativeBookmarkWriter {
  static func state() -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { return ["state": "legacy"] }
    return ["state": "owned", "generation": String(owner.currentGeneration)]
  }

  static func snapshot(profile: String) throws -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { throw BookmarkWriterError.notOwned }
    let snapshot = try owner.snapshot(profile: profile)
    return [
      "engine": snapshot.binding.engine, "generation": String(snapshot.binding.generation),
      "revision": String(snapshot.revision), "ready": snapshot.ready, "document": snapshot.document.text(),
    ]
  }

  static func replace(profile: String, documentJSON: String, expectedRevision: String, engine: String, generation: String, requestID: String?) throws -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { throw BookmarkWriterError.notOwned }
    guard let expected = UInt64(expectedRevision), let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("revision and generation must be decimal strings") }
    let document: JSONValue
    do { document = try JSONValue.parse(documentJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    let revision = try owner.replace(profile: profile, document: document, expectedRevision: expected, binding: BookmarkWriterBinding(engine: engine, generation: generation), requestID: requestID)
    return ["revision": String(revision)]
  }

  static func submit(profile: String, mutationsJSON: String, engine: String, generation: String, requestID: String?) throws -> [String: Any] {
    guard let owner = NativeBookmarkOwner.current else { throw BookmarkWriterError.notOwned }
    guard let generation = UInt64(generation) else { throw BookmarkWriterError.invalidDocument("generation must be a decimal string") }
    let parsed: JSONValue
    do { parsed = try JSONValue.parse(mutationsJSON) } catch { throw BookmarkWriterError.invalidDocument(String(describing: error)) }
    guard let list = parsed.array else { throw BookmarkWriterError.invalidDocument("mutations must be an array") }
    let mutations = try list.map { item -> BookmarkMutation in
      guard let method = item["method"]?.string, let args = item["args"]?.array else { throw BookmarkWriterError.invalidDocument("each mutation needs a method and args") }
      return BookmarkMutation(method: method, args: args)
    }
    let receipt = try owner.submit(profile: profile, mutations: mutations, binding: BookmarkWriterBinding(engine: engine, generation: generation), requestID: requestID)
    return ["engine": receipt.view.engine, "revision": String(receipt.view.revision), "results": JSONValue.array(receipt.results).text(), "document": receipt.view.document.text()]
  }
}
