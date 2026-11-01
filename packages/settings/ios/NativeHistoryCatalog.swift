import AppKit
import SolaraCore
import Foundation
import SolaraEngine
import SolaraStore
import SolaraUI

@MainActor
final class SolaraHistoryClient: EngineClient {
  enum Failure: Error {
    case invalidReply
    case engine(String)
  }

  private var observing = false

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {
    guard !observing else { return }
    observing = true
    SolaraCoreEngineBridge.observe("history.changed") { payload in
      nonisolated(unsafe) let payload = payload
      let deliver: @MainActor @Sendable () -> Void = {
        MainActor.assumeIsolated {
          guard let profile = payload["profile"] as? String else { return }
          let changes = payload["kind"] as? String == "batch" ? payload["changes"] as? [[String: Any]] ?? [] : [payload]
          for change in changes {
            guard let kind = change["kind"] as? String else { continue }
            switch kind {
            case "visit":
              guard let url = change["u"] as? String, let title = change["t"] as? String,
                let visits = change["n"] as? Int, let at = change["at"] as? Double else { continue }
              handler(.visit(profile: profile, url: url, title: title, visits: visits, at: at))
            case "modified":
              let rows = (change["rows"] as? [[String: Any]] ?? []).compactMap { row -> HistoryModifiedRow? in
                guard let url = row["u"] as? String, let title = row["t"] as? String,
                  let visits = row["n"] as? Int else { return nil }
                return HistoryModifiedRow(url: url, title: title, visits: visits)
              }
              handler(.modified(profile: profile, rows: rows))
            case "deleted":
              handler(.deleted(profile: profile, all: change["all"] as? Bool ?? false, urls: change["urls"] as? [String] ?? []))
            default:
              break
            }
          }
        }
      }
      if Thread.isMainThread { MainActor.assumeIsolated { deliver() } } else { DispatchQueue.main.async(execute: deliver) }
    }
  }

  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
    SolaraCoreEngineBridge.observe("bookmarks.changed") { payload in
      nonisolated(unsafe) let payload = payload
      let deliver: @MainActor @Sendable () -> Void = {
        MainActor.assumeIsolated {
          if let profile = payload["profile"] as? String { handler(profile) }
        }
      }
      if Thread.isMainThread { MainActor.assumeIsolated { deliver() } } else { DispatchQueue.main.async(execute: deliver) }
    }
  }

  func deleteHistory(urls: [String], engineProfile: String) async throws {
    _ = try await call("ac_history_delete_urls", profile: engineProfile, args: ["urls": urls])
  }

  func importHistory(rows: [HistoryImportRow], engineProfile: String) async throws {
    let values: [[String: Any]] = rows.map { ["u": $0.url, "t": $0.title, "n": $0.visits, "l": $0.lastVisit] }
    _ = try await call("ac_history_import", profile: engineProfile, args: ["rows": values])
  }

  func addHistoryVisits(pages: [HistoryVisitPage], toleranceMs: Double, engineProfile: String) async throws -> Int {
    let values: [[String: Any]] = pages.map { ["u": $0.url, "t": $0.title, "v": $0.visitTimes] }
    let data = try await call("ac_history_add", profile: engineProfile, args: ["pages": values, "toleranceMs": toleranceMs])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let added = object["added"] as? Int else { throw Failure.invalidReply }
    return added
  }

  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ops))
    let data = try await call("ac_bookmarks_apply", profile: engineProfile, args: ["ops": values])
    return try JSONDecoder().decode(BookmarkApplyResult.self, from: data)
  }

  func watchBookmarks(engineProfile: String) async throws {
    _ = try await call("ac_bookmarks_watch", profile: engineProfile)
  }

  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    let data = try await call("ac_bookmarks_tree", profile: engineProfile)
    return try JSONDecoder().decode(EngineBookmarkTree.self, from: data)
  }

  func watchHistory(engineProfile: String) async throws {
    _ = try await call("ac_history_watch", profile: engineProfile)
  }

  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] {
    let data = try await call("ac_history_query", profile: engineProfile, args: ["maxUrls": maxUrls, "maxVisits": maxVisits])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = object["entries"] as? [[String: Any]] else { throw Failure.invalidReply }
    return try rows.map { row in
      guard let url = row["u"] as? String, let title = row["t"] as? String,
        let visits = row["n"] as? Int, let times = row["v"] as? [Double] else { throw Failure.invalidReply }
      return EngineHistoryRow(url: url, title: title, visits: visits, visitTimes: times)
    }
  }

  func storedFavicon(page: String, engineProfile: String) async throws -> Data? {
    let data = try await call("ac_favicons_get", profile: engineProfile, args: ["pages": [page], "size": 32])
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pages = object["pages"] as? [String: [String: String]], let png = pages[page]?["png"] else { return nil }
    return Data(base64Encoded: png)
  }

  func fetchFavicon(source: String, engineProfile: String) async -> Data? {
    if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
      return validImageData(Data(base64Encoded: String(source[source.index(after: comma)...])))
    }
    if source.hasPrefix("file:"), let url = URL(string: source), url.isFileURL { return validImageData(try? Data(contentsOf: url)) }
    if source.hasPrefix("/") { return validImageData(try? Data(contentsOf: URL(fileURLWithPath: source))) }
    guard source.hasPrefix("https://") || source.hasPrefix("http://") else { return nil }
    return await withCheckedContinuation { continuation in
      SolaraCoreFavicons.fetch(source, profile: engineProfile, name: nil) { result in
        guard let uri = result?["uri"] as? String, let comma = uri.firstIndex(of: ",") else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: Data(base64Encoded: String(uri[uri.index(after: comma)...])))
      }
    }
  }

  private func validImageData(_ data: Data?) -> Data? {
    guard let data, NSImage(data: data) != nil else { return nil }
    return data
  }

  func bundledFavicon(page: String, dark: Bool) async -> Data? {
    guard let name = BundledSiteIcons.name(for: page, dark: dark),
      let url = Bundle.main.resourceURL?.appendingPathComponent("assets/assets/site-icons/\(name).png") else { return nil }
    return try? Data(contentsOf: url)
  }

  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws {
    _ = try await call("ac_favicons_set", profile: engineProfile, args: ["page": page, "icon": source, "png": data.base64EncodedString()])
  }

  private func call(_ name: String, profile: String, args: [String: Any] = [:]) async throws -> Data {
    let body = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      SolaraCoreEngineBridge.call(name, profile: profile, args: body) { json in
        let data = Data(json.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          continuation.resume(throwing: Failure.invalidReply)
          return
        }
        if let error = object["error"] as? String {
          continuation.resume(throwing: Failure.engine(error))
        } else {
          continuation.resume(returning: data)
        }
      }
    }
  }
}

@MainActor
enum NativeHistoryCatalog {
  static let catalog = LibraryCatalog(client: SolaraHistoryClient())

  static func favicon(page: String, source: String? = nil, profileId: String, dark: Bool) async -> NSImage? {
    let profile = NativeStoreHandle.store?.state.engineProfile(profileId) ?? (profileId == "default" ? "" : profileId)
    guard let result = await catalog.favicons?.favicon(page: page, source: source, engineProfile: profile, appearance: dark) else { return nil }
    return NSImage(data: result.data)
  }

  static func devFaviconLookup(page: String, engineProfile: String) async -> [String: Any] {
    let result = await catalog.favicons?.favicon(page: page, engineProfile: engineProfile, appearance: false)
    return ["bytes": result?.data.count ?? 0, "source": result?.source ?? "missing"]
  }

  static func start(engineProfiles: [String]) async {
    NativeHistoryHints.start(catalog: catalog)
    NewTabSources.shared.useHistoryCatalog(catalog)
    NewTabSources.shared.useBookmarkCatalog(catalog)
    await catalog.start(engineProfiles: engineProfiles)
  }

  static func command(kind: String, engineProfile: String, payload: [String: Any]) async throws -> Any {
    let data = try JSONSerialization.data(withJSONObject: payload)
    switch kind {
    case "deleteHistory":
      guard let urls = payload["urls"] as? [String] else { throw SolaraHistoryClient.Failure.invalidReply }
      try await catalog.deleteHistory(urls: urls, engineProfile: engineProfile)
      return NSNull()
    case "importHistory":
      let rows = try JSONDecoder().decode(HistoryRowsPayload.self, from: data).rows
      try await catalog.importHistory(rows: rows, engineProfile: engineProfile)
      return NSNull()
    case "addHistoryVisits":
      let input = try JSONDecoder().decode(HistoryVisitsPayload.self, from: data)
      return try await catalog.addHistoryVisits(pages: input.pages, toleranceMs: input.toleranceMs, engineProfile: engineProfile)
    case "applyBookmarks":
      let ops = try JSONDecoder().decode(BookmarkOpsPayload.self, from: data).ops
      let result = try await catalog.applyBookmarks(ops: ops, engineProfile: engineProfile)
      return ["applied": result.applied, "skipped": result.skipped, "invalid": result.invalid]
    case "storeFavicon":
      guard let page = payload["page"] as? String, let source = payload["icon"] as? String,
        let png = payload["png"] as? String, let bytes = Data(base64Encoded: png) else { throw SolaraHistoryClient.Failure.invalidReply }
      try await catalog.storeFavicon(page: page, source: source, data: bytes, engineProfile: engineProfile)
      return ["stored": true]
    default:
      throw SolaraHistoryClient.Failure.invalidReply
    }
  }

  private struct HistoryRowsPayload: Decodable { var rows: [HistoryImportRow] }
  private struct HistoryVisitsPayload: Decodable { var pages: [HistoryVisitPage]; var toleranceMs: Double }
  private struct BookmarkOpsPayload: Decodable { var ops: [BookmarkOperation] }

  static func bookmarksSnapshot(engineProfile: String) -> [String: Any] {
    let bookmarks = catalog.bookmarks(engineProfile: engineProfile)
    return ["count": bookmarks.urlCount, "ready": bookmarks.ready, "revision": bookmarks.revision]
  }

  static func snapshot(engineProfile: String) -> [String: Any] {
    let history = catalog.history(engineProfile: engineProfile)
    return [
      "count": history.entries.count,
      "ready": history.ready,
      "floor": history.floor.isFinite ? history.floor as Any : "-Infinity",
      "revision": history.revision,
    ]
  }
}

#if SOLARA_PROBES
@MainActor
public enum PageLibraryRead {
  public static func bookmarks(windowId: String) -> [[String: Any]] {
    guard let state = NativeStoreHandle.store?.state, let window = state.windows[windowId] else { return [] }
    let snapshot = NativeHistoryCatalog.catalog.bookmarks(engineProfile: state.engineProfile(window.profileId))
    var result: [[String: Any]] = []
    for id in snapshot.nodes.keys.sorted().prefix(128) {
      guard let node = snapshot.nodes[id] else { continue }
      result.append(["id": node.id, "title": String(node.title.prefix(512)), "url": node.url ?? NSNull(),
        "parentId": node.parentId ?? NSNull(), "children": node.children ?? []])
    }
    return result
  }
}
#endif
