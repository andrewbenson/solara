import AppKit
import SolaraCore
import Foundation
import ImageIO
import SolaraEngine
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
final class SolaraHistoryClient: EngineClient {
  enum Failure: Error {
    case invalidReply
    case profileNotLoaded
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
    #if DEBUG
      try await NativeBookmarkFaults.beforeApply(engine: engineProfile, ops: ops)
    #endif
    if NativeBookmarkOwner.current != nil {
      let values = try JSONValue.parse(JSONEncoder().encode(ops))
      let projected = (values.array ?? []).map { value -> JSONValue in
        var operation = value.object ?? [:]
        for key in ["t", "u", "key"] {
          if let text = operation[key]?.string { operation[key] = .string(BookmarkString.display(text)) }
        }
        return .object(operation)
      }
      let args: JSONValue = ["ops": .array(projected)]
      let reply = try await bookmarkCall("ac_bookmarks_apply", profile: engineProfile, args: args.text())
      let result = try JSONDecoder().decode(BookmarkApplyResult.self, from: Data(reply.text().utf8))
      #if DEBUG
        NativeBookmarkFaults.afterApply(engine: engineProfile, result: result)
      #endif
      return result
    }
    let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ops))
    let data = try await call("ac_bookmarks_apply", profile: engineProfile, args: ["ops": values])
    return try JSONDecoder().decode(BookmarkApplyResult.self, from: data)
  }

  func watchBookmarks(engineProfile: String) async throws {
    _ = try await call("ac_bookmarks_watch", profile: engineProfile)
  }

  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree {
    #if DEBUG
      try await NativeBookmarkFaults.beforeRead(engine: engineProfile)
    #endif
    if NativeBookmarkOwner.current != nil {
      let reply = try await bookmarkCall("ac_bookmarks_tree", profile: engineProfile)
      return try JSONDecoder().decode(EngineBookmarkTree.self, from: Data(reply.text().utf8))
    }
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
    guard NativeProfileLoading.isLoaded(engineProfile), source.hasPrefix("https://") || source.hasPrefix("http://") else { return nil }
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

  private func bookmarkCall(_ name: String, profile: String, args: String = "{}") async throws -> JSONValue {
    guard NativeProfileLoading.isLoaded(profile) else { throw Failure.profileNotLoaded }
    return try await withCheckedThrowingContinuation { continuation in
      SolaraCoreEngineBridge.call(name, profile: profile, args: args) { json in
        do {
          let reply = try JSONValue.parseBookmark(json)
          guard reply.object != nil else { throw Failure.invalidReply }
          if let error = reply["error"]?.string { throw Failure.engine(BookmarkString.display(error)) }
          continuation.resume(returning: reply)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func call(_ name: String, profile: String, args: [String: Any] = [:]) async throws -> Data {
    guard NativeProfileLoading.isLoaded(profile) else { throw Failure.profileNotLoaded }
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
  static let client = SolaraHistoryClient()
  static let catalog: LibraryCatalog = makeCatalog()

  private static func makeCatalog() -> LibraryCatalog {
    NativeBookmarkLaunch.select()
    return LibraryCatalog(client: client, bookmarkAdmission: { try await NativeBookmarkLaunch.ensureReady() }, engineAdmission: { NativeProfileLoading.isLoaded($0) })
  }
  private static var lifecycle: Int?
  private static weak var boundStore: Store?
  private static var profileLifetimes: HistoryProfileLifetimes?

  private static func bindProfileLifetimes() {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle {
      let store = NativeStoreHandle.store
      guard boundStore !== store else { return }
      profileLifetimes?.stop()
      profileLifetimes = nil
      boundStore = store
      if let store { profileLifetimes = HistoryProfileLifetimes(catalog: catalog, store: store) }
    }
  }

  static func favicon(page: String, source: String? = nil, profileId: String, dark: Bool) async -> NSImage? {
    if let state = NativeStoreHandle.store?.displayState, state.profiles[profileId] != nil, !Ids.isIncognitoProfile(profileId) {
      let engine = state.engineProfile(profileId)
      if !NativeProfileLoading.isLoaded(engine), let image = await NativeLaunchFavicons.image(page: page, source: source, engine: engine),
        let current = NativeStoreHandle.store?.displayState, current.profiles[profileId] != nil,
        current.engineProfile(profileId).utf16.elementsEqual(engine.utf16), !NativeProfileLoading.isLoaded(engine) { return image }
    }
    let profile = NativeStoreHandle.store?.displayState.engineProfile(profileId) ?? (profileId == "default" ? "" : profileId)
    guard let result = await catalog.favicons?.favicon(page: page, source: source, engineProfile: profile, appearance: dark) else { return nil }
    return NSImage(data: result.data)
  }

  static func devFaviconLookup(page: String, engineProfile: String) async -> [String: Any] {
    let result = await catalog.favicons?.favicon(page: page, engineProfile: engineProfile, appearance: false)
    return ["bytes": result?.data.count ?? 0, "source": result?.source ?? "missing"]
  }

  static func start(engineProfiles: [String]) async {
    do { try await NativeBookmarkLaunch.ensureReady() } catch {
      guard NativeBookmarkOwner.bookmarksSelected else { return }
    }
    bindProfileLifetimes()
    NativeHistoryHints.start(catalog: catalog)
    NewTabSources.shared.useHistoryCatalog(catalog)
    NewTabSources.shared.useBookmarkCatalog(catalog)
    let admitted: [String]
    if let state = NativeStoreHandle.store?.state {
      let live = state.profiles.keys.map { state.engineProfile($0) }
      admitted = engineProfiles.filter { engine in live.contains { $0.utf16.elementsEqual(engine.utf16) } }
    } else { admitted = engineProfiles }
    await catalog.start(engineProfiles: admitted)
  }

  static func command(kind: String, engineProfile: String, payload: [String: Any]) async throws -> Any {
    guard !engineProfile.hasPrefix("incognito:") else { throw SolaraHistoryClient.Failure.invalidReply }
    let data = try JSONSerialization.data(withJSONObject: payload)
    switch kind {
    case "deleteHistory":
      guard let urls = payload["urls"] as? [String] else { throw SolaraHistoryClient.Failure.invalidReply }
      guard !urls.isEmpty else { return NSNull() }
      try await ensureEngine(engineProfile)
      try await catalog.deleteHistory(urls: urls, engineProfile: engineProfile)
      return NSNull()
    case "importHistory":
      let rows = try JSONDecoder().decode(HistoryRowsPayload.self, from: data).rows
      guard !rows.isEmpty else { return NSNull() }
      try await ensureEngine(engineProfile)
      try await catalog.importHistory(rows: rows, engineProfile: engineProfile)
      return NSNull()
    case "addHistoryVisits":
      let input = try JSONDecoder().decode(HistoryVisitsPayload.self, from: data)
      guard !input.pages.isEmpty else { return 0 }
      try await ensureEngine(engineProfile)
      return try await catalog.addHistoryVisits(pages: input.pages, toleranceMs: input.toleranceMs, engineProfile: engineProfile)
    case "applyBookmarks":
      throw BookmarkCoordinatorError.ownershipUnavailable
    case "storeFavicon":
      guard let page = payload["page"] as? String, let source = payload["icon"] as? String,
        let png = payload["png"] as? String, let bytes = Data(base64Encoded: png) else { throw SolaraHistoryClient.Failure.invalidReply }
      guard NativeProfileLoading.isLoaded(engineProfile) else { return ["stored": false] }
      try await catalog.storeFavicon(page: page, source: source, data: bytes, engineProfile: engineProfile)
      return ["stored": true]
    default:
      throw SolaraHistoryClient.Failure.invalidReply
    }
  }

  private static func ensureEngine(_ engine: String) async throws {
    let loaded = await withCheckedContinuation { continuation in
      SolaraCoreHost.ensureProfile(engine) { continuation.resume(returning: $0) }
    }
    guard loaded else { throw SolaraHistoryClient.Failure.profileNotLoaded }
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


@MainActor
private enum NativeLaunchFavicons {
  nonisolated private static let documentLimit = 1100 * 1024
  nonisolated private static let imageLimit = 241
  nonisolated private static let uriLimit = 16 * 1024
  nonisolated private static let rowLimit = 240
  private static var decoded: [Int: NSImage] = [:]
  private static let saved = Task.detached { () -> JSONValue? in
    guard let directory = try? DocumentStore.directoryURL(),
      let file = try? FileHandle(forReadingFrom: directory.appending(path: "launch-look.json")) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: documentLimit + 1), data.count <= documentLimit,
      let look = try? JSONValue.parse(data), look["version"] == 2,
      let favicons = look["favicons"], let images = favicons["images"]?.array, images.count <= imageLimit,
      let profiles = favicons["profiles"]?.object, profiles.count <= rowLimit else { return nil }
    return favicons
  }

  static func image(page: String, source: String?, engine: String) async -> NSImage? {
    guard !Ids.isIncognitoProfile(engine), let saved = await saved.value,
      let profile = saved["profiles"]?[engine]?.object,
      let pages = profile["pages"]?.object, pages.count <= rowLimit,
      let sources = profile["srcs"]?.object, sources.count <= rowLimit,
      let images = saved["images"]?.array else { return nil }
    let page = String(page.prefix { $0 != "#" })
    guard page.utf16.count <= 16 * 1024, (source?.utf16.count ?? 0) <= 16 * 1024 else { return nil }
    let candidates = [source.flatMap { sources[$0] }, pages[page]]
    for candidate in candidates {
      guard let value = candidate?.number, value.isFinite, value.rounded(.towardZero) == value,
        value >= 0, value < Double(images.count) else { continue }
      let index = Int(value)
      if let image = decoded[index] { return image }
      guard let uri = images[index].string, uri.utf16.count <= uriLimit,
        uri.hasPrefix("data:image/png;base64,"),
        let data = Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count))),
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
        let type = CGImageSourceGetType(imageSource), type as String == "public.png",
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, width <= 256, height > 0, height <= 256,
        let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { continue }
      let image = NSImage(cgImage: decodedImage, size: NSSize(width: CGFloat(width), height: CGFloat(height)))
      decoded[index] = image
      return image
    }
    return nil
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
