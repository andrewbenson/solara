import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum DroppedTabs {
  public static let maxTabs = 50

  public static func urls(_ items: [[String: String]]) -> [String] {
    var urls: [String] = []
    for item in items {
      if item["kind"] == "file" {
        if let url = item["url"], isFileURL(url) { urls.append(url) }
        continue
      }
      let isURL = item["kind"] == "url"
      let raw = JSText.trim((isURL ? item["url"] : item["text"]) ?? "")
      let url = isURL ? raw : (JSText.hasSpace(raw) ? nil : fixupUrl(raw))
      if let url, isWebURL(url) { urls.append(url) }
    }
    return Array(urls.prefix(maxTabs))
  }

  @discardableResult
  public static func open(_ store: Store, windowId: String, items: [[String: String]], placement: JSONValue?, refused: (Error) -> Void = { _ in }) -> [String] {
    let urls = urls(items)
    guard !urls.isEmpty, let profileId = store.state.windows[windowId]?.profileId else { return [] }
    var ids: [String] = []
    for (i, url) in urls.enumerated() {
      var options: JSONObject = ["url": .string(url), "background": .bool(i > 0), "profileId": .string(profileId)]
      if let previous = ids.last, let index = store.state.windows[windowId]?.tabIds.firstIndex(of: previous) { options["index"] = .number(Double(index + 1)) }
      do {
        if let id = try store.dispatch(Command("newTab", [.string(windowId), .object(options)]), origin: .native).result?.string, !id.isEmpty { ids.append(id) }
      } catch {
        refused(error)
      }
    }
    if !ids.isEmpty, let placement, placement != .null {
      do {
        try store.dispatch(Command("placeTabs", [JSONValue(ids), placement]), origin: .native)
      } catch {
        refused(error)
      }
    }
    return ids
  }

  private static func isFileURL(_ url: String) -> Bool {
    let units = Array(url.utf16)
    return units.count > 8 && String(decoding: units[0..<8], as: UTF16.self).lowercased() == "file:///" && units[8] != 0x2f
  }

  private static func isWebURL(_ url: String) -> Bool {
    let units = Array(url.utf16)
    let lower = String(decoding: units.prefix(8), as: UTF16.self).lowercased()
    let skip = lower.hasPrefix("https://") ? 8 : lower.hasPrefix("http://") ? 7 : 0
    guard skip > 0, units.count > skip else { return false }
    let first = units[skip]
    return first != 0x2f && !JSText.isSpace(first)
  }
}
