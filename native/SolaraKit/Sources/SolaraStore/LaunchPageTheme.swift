import Foundation
import SolaraModel
import Synchronization

public enum LaunchPageTheme {
  public static let documentLimit = 1100 * 1024
  public static let themeLimit = 200
  public typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

  @discardableResult
  public static func restore(store: Store, folder: URL) throws -> Int {
    let file = folder.appending(path: "launch-look.json")
    guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: documentLimit + 1) else { return 0 }
    return try restore(store: store, data: data)
  }

  @discardableResult
  public static func restore(store: Store, data: Data) throws -> Int {
    guard data.count <= documentLimit, let look = try? JSONValue.parse(data),
      look["version"] == 2, let entries = look["themes"]?.array else { return 0 }
    let themes = entries.compactMap { entry -> JSONValue? in
      guard entry["tab"]?.string != nil, entry["page"]?.string != nil,
        let color = entry["color"]?.string, color.utf16.count <= 64 else { return nil }
      return entry
    }.prefix(themeLimit)
    var restored = 0
    for theme in themes {
      let id = theme["tab"]!.string!
      let snapshot = store.snapshot.state
      guard let tab = snapshot.tabs[id], let live = snapshot.live[id],
        live.themeColor?.isEmpty != false,
        TabPageModel.pageKey(tab.url) == theme["page"]?.string else { continue }
      let commit = try store.dispatch(Command("pageReport", [.string(id), ["type": "restore", "themes": .array([theme])]]), origin: .load)
      if commit.state.live[id]?.themeColor == theme["color"]?.string { restored += 1 }
    }
    return restored
  }
}

struct LaunchPageThemeDeadline: Sendable, Equatable {
  let generation: String
  let at: Double
}

final class LaunchPageThemeTimers: Sendable {
  struct Pending: Sendable {
    let deadline: LaunchPageThemeDeadline
    let ticket: UUID
  }

  private let pending = Mutex<[String: Pending]>([:])
  private let after: LaunchPageTheme.Schedule

  init(after: @escaping LaunchPageTheme.Schedule) { self.after = after }

  func refresh(now: Double, store: Store, capture: () -> [String: LaunchPageThemeDeadline]) {
    let additions = pending.withLock { pending -> [(String, Pending)] in
      let deadlines = capture()
      for id in Array(pending.keys) where deadlines[id] != pending[id]?.deadline { pending[id] = nil }
      var additions: [(String, Pending)] = []
      for (id, deadline) in deadlines where pending[id] == nil {
        let item = Pending(deadline: deadline, ticket: UUID())
        pending[id] = item
        additions.append((id, item))
      }
      return additions
    }
    for (id, item) in additions {
      after(max(0, item.deadline.at - now) / 1000) { [weak self, weak store] in
        guard let self, let store else { return }
        let current = self.pending.withLock { pending -> Bool in
          guard pending[id]?.ticket == item.ticket else { return false }
          pending[id] = nil
          return true
        }
        guard current else { return }
        store.enqueuePageReport(id: id, report: ["type": "advance", "generation": .string(item.deadline.generation)])
        store.sequence {}
      }
    }
  }
}
