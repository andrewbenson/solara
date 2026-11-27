import Foundation

struct Download {
  static let maxKept = 100
  var id: String
  var isDownloading = false
}
struct Window {}
struct UI { var focusedWindowId: String? }
struct State {
  func downloadSession(_ download: Download) -> String? { nil }
  func downloadVisible(_ download: Download, in window: Window?) -> Bool { false }

  var downloads: [Download]
  var windows: [String: Window] = [:]
  var ui = UI()
  mutating func openDownloads(_ windowId: String) {}
}
struct Config { var safeMode: Bool }
struct Memory { var endedPrivateDownloads: Set<String> = [] }
enum Effect { case openDownloads(windowId: String) }
final class Session {
  var state: State
  var memory = Memory()
  let config: Config
  init(safe: Bool) {
    config = Config(safeMode: safe)
    state = State(downloads: (0..<100).map { Download(id: "saved-\($0)") })
  }
  func privateSessionOpen(_ state: State, _ session: String) -> Bool { false }
  func emit(_ effect: Effect) {}
  func set(_ next: State) { state = next }

  __PRODUCTION__
}

var results: [[String: Any]] = []
for safe in [true, false] {
  let session = Session(safe: safe)
  session.upsertDownload(Download(id: "engine-42"))
  session.upsertDownload(Download(id: "engine-42"))
  let replayed = session.state.downloads.map(\.id)
  session.removeDownload("saved-0")
  results.append(["safe": safe, "replayed": replayed, "removed": session.state.downloads.map(\.id)])
}
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
