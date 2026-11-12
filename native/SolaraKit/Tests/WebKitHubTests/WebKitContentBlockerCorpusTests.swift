import CryptoKit
import Foundation
import Testing
import WebKit

@Suite @MainActor struct WebKitContentBlockerCorpusTests {
  @Test(.timeLimit(.minutes(5))) func embeddedRulesCompileAndCache() async throws {
    guard let path = ProcessInfo.processInfo.environment["SOLARA_WEBKIT_BLOCKER_CORPUS"] else { return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let manifest = try JSONDecoder().decode(WebKitContentBlocker.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("solara-webkit-corpus-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cache) }
    let store = try #require(WKContentRuleListStore(url: cache))
    var metrics: [[String: Any]] = []
    var seen = Set<String>()
    for group in manifest.lists {
      for chunk in group.chunks {
        guard seen.insert(chunk.sha256).inserted else { continue }
        let read = ProcessInfo.processInfo.systemUptime
        let data = try WebKitContentBlocker.contents(.init(file: chunk.file, sha256: chunk.sha256), root: root, encoding: manifest.encoding)
        let readMs = (ProcessInfo.processInfo.systemUptime - read) * 1000
        let identifier = "corpus." + chunk.sha256
        let started = ProcessInfo.processInfo.systemUptime
        let (list, error): (WKContentRuleList?, Error?) = await withCheckedContinuation { done in
          store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: String(decoding: data, as: UTF8.self)) { done.resume(returning: ($0, $1)) }
        }
        let coldMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if let error {
          Issue.record("WK compile failed for \(group.id)/\(chunk.file): \(String(reflecting: error as NSError))")
          continue
        }
        _ = try #require(list)
        let cachedStart = ProcessInfo.processInfo.systemUptime
        let cached: WKContentRuleList? = await withCheckedContinuation { done in
          store.lookUpContentRuleList(forIdentifier: identifier) { value, _ in done.resume(returning: value) }
        }
        #expect(cached != nil)
        metrics.append(["group": group.id, "file": chunk.file, "sourceBytes": data.count, "readMs": readMs, "coldMs": coldMs, "cachedMs": (ProcessInfo.processInfo.systemUptime - cachedStart) * 1000])
      }
    }
    let bytes = try Self.diskBytes(cache)
    let output: [String: Any] = ["version": manifest.version, "compiledChunks": metrics.count, "compiledBytes": bytes, "encoding": manifest.encoding ?? "none", "readMs": metrics.reduce(0.0) { $0 + ($1["readMs"] as? Double ?? 0) }, "coldMs": metrics.reduce(0.0) { $0 + ($1["coldMs"] as? Double ?? 0) }, "cachedMs": metrics.reduce(0.0) { $0 + ($1["cachedMs"] as? Double ?? 0) }, "chunks": metrics]
    print("WEBKIT_CORPUS " + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    #expect(metrics.count == seen.count)
  }
  private static func diskBytes(_ cache: URL) throws -> Int {
    var bytes = 0
    if let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
      for case let file as URL in files {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
      }
    }
    return bytes
  }

}
