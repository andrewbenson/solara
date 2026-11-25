import SolaraEngine
import SolaraModel
import SolaraStore

public struct BookmarkOpenPlan: Equatable, Sendable {
  public let window: BrowserWindow?
  public let tab: Tab?
  public let profile: String
  public let engine: String
  public let binding: BookmarkWriterBinding?
  public let revision: UInt64?
  public let urls: [String]
  public let mode: String
}

public enum BookmarkMenuCommand {
  public static let commands: Set<String> = ["openBookmark", "openBookmarkItems"]

  public static func plan(command: String, arg: String?, windowId: String?, state: BrowserState,
    closing: Set<String>, snapshot: BookmarkWriterSnapshot?) -> BookmarkOpenPlan? {
    guard commands.contains(command), let arg else { return nil }
    let request: JSONValue
    if command == "openBookmark" { request = ["id": .string(arg), "mode": "current"] }
    else {
      guard let parsed = try? JSONValue.parse(arg) else { return nil }
      request = parsed
    }
    let mode = request["mode"]?.string ?? "current"
    guard ["current", "background", "foreground", "window", "incognito", "split", "tabs"].contains(mode) else { return nil }
    let route = CommandRoute.resolve("openBookmark", windowId: windowId, state: state, closing: closing)
    if let id = route.windowId, closing.contains(id) { return nil }
    let window = route.windowId.flatMap { state.windows[$0] }
    let tab = route.tabId.flatMap { state.tabs[$0] }
    if command == "openBookmark", tab == nil { return nil }
    guard tab == nil || tab?.windowId == window?.id && tab?.profileId == window?.profileId else { return nil }
    let profile = state.bookmarkProfileId(window)
    let engine = state.engineProfile(profile)
    var urls: [String] = []
    var binding: BookmarkWriterBinding?
    var revision: UInt64?
    if let nodeId = request["id"]?.string {
      guard let snapshot, snapshot.hasView, snapshot.binding.engine == engine else { return nil }
      binding = snapshot.binding
      revision = snapshot.revision
      let nodes = snapshot.document["nodes"]?.object ?? [:]
      guard let node = nodes[nodeId] else { return nil }
      var seen = Set<JSKey>()
      func collect(_ id: String, depth: Int) {
        guard depth < 512, seen.insert(JSKey(id)).inserted, let node = nodes[id] else { return }
        if node["kind"] == "url", let url = node["url"]?.string, !url.isEmpty { urls.append(url) }
        else if node["kind"] == "folder" {
          for child in node["children"]?.array?.compactMap(\.string) ?? [] { collect(child, depth: depth + 1) }
        }
      }
      if mode == "tabs" || request["folder"]?.truthy == true {
        guard node["kind"] == "folder" else { return nil }
        collect(nodeId, depth: 0)
      } else {
        guard node["kind"] == "url", let url = node["url"]?.string, !url.isEmpty else { return nil }
        urls = [url]
      }
    } else if let url = request["url"]?.string, !url.isEmpty, mode != "tabs" { urls = [url] }
    guard !urls.isEmpty else { return nil }
    return BookmarkOpenPlan(window: window, tab: tab, profile: profile, engine: engine, binding: binding,
      revision: revision, urls: urls, mode: mode)
  }
}
