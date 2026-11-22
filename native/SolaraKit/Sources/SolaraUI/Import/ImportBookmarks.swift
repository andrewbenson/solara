import Foundation
import SolaraEngine
import SolaraModel

public struct ImportBookmarkNode: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let isFolder: Bool
  public let title: String
  public let url: String?
  public let dateAdded: Double?
  public let role: String?
  public let pageTitle: String?
  public let children: [ImportBookmarkNode]?

  public init(isFolder: Bool, title: String, url: String?, dateAdded: Double?, role: String?, pageTitle: String?, children: [ImportBookmarkNode]?) {
    self.isFolder = isFolder
    self.title = title
    self.url = url
    self.dateAdded = dateAdded
    self.role = role
    self.pageTitle = pageTitle
    self.children = children
  }

  public var description: String { "ImportBookmarkNode" }
  public var debugDescription: String { "ImportBookmarkNode" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ImportTabRow: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let url: String
  public let title: String
  public let pinned: Bool
  public let customTitle: String?

  public init(url: String, title: String, pinned: Bool, customTitle: String?) {
    self.url = url
    self.title = title
    self.pinned = pinned
    self.customTitle = customTitle
  }

  public var description: String { "ImportTabRow" }
  public var debugDescription: String { "ImportTabRow" }
  public var customMirror: Mirror { Mirror(self, children: [:]) }

  func json(pinned forced: Bool? = nil) -> JSONValue {
    var object: JSONObject = ["url": .string(url), "title": .string(title), "pinned": .bool(forced ?? pinned)]
    if let customTitle { object["customTitle"] = .string(customTitle) }
    return .object(object)
  }
}

public struct ImportBookmarkParents: Sendable, Equatable {
  public let bar: String
  public let other: String
  public let barEmpty: Bool
  public let otherEmpty: Bool

  public init(bar: String, other: String, barEmpty: Bool, otherEmpty: Bool) {
    self.bar = bar
    self.other = other
    self.barEmpty = barEmpty
    self.otherEmpty = otherEmpty
  }
}

public enum ImportBookmarkWriteFailure: Error, Sendable {
  case conditionFailed
  case noRoots
  case failed
}

public enum ImportBookmarks {
  static func draft(_ node: ImportBookmarkNode) -> JSONValue {
    var object: JSONObject
    if node.isFolder {
      object = ["title": .string(node.title), "children": .array((node.children ?? []).map(draft))]
    } else {
      let title = node.title.isEmpty ? (node.url ?? "") : node.title
      object = ["title": .string(title), "url": .string(node.url ?? "")]
    }
    if let added = node.dateAdded { object["addedAt"] = .number(added) }
    return .object(object)
  }

  static func split(_ root: ImportBookmarkNode) -> (toolbar: [ImportBookmarkNode], other: [ImportBookmarkNode]) {
    let children = root.children ?? []
    let toolbar = children.filter { $0.role == "toolbar" }.flatMap { $0.children ?? [] }
    let rest = children.filter { $0.role != "toolbar" }
    let other = rest.flatMap { c -> [ImportBookmarkNode] in
      guard c.role == "other" || c.role == nil else { return [c] }
      return c.isFolder ? (c.children ?? []) : [c]
    }
    return (toolbar, other)
  }

  static func edits(profile: String, toolbar: [ImportBookmarkNode], other: [ImportBookmarkNode], parents: ImportBookmarkParents, browserName: String) -> [BookmarkMutation] {
    func place(_ nodes: [ImportBookmarkNode], _ parent: String, _ empty: Bool) -> [BookmarkMutation] {
      guard !nodes.isEmpty else { return [] }
      let drafts = JSONValue.array(nodes.map(draft))
      guard empty else {
        let wrapper: JSONValue = .object(["title": .string("Imported from \(browserName)"), "children": drafts])
        return [BookmarkMutation(method: "addBookmarkTree", args: [.string(profile), .array([wrapper]), .string(parent)])]
      }
      return [
        BookmarkMutation(method: "expectChildren", args: [.string(profile), .string(parent), .array([])]),
        BookmarkMutation(method: "addBookmarkTree", args: [.string(profile), drafts, .string(parent)]),
      ]
    }
    let planned = place(toolbar, parents.bar, parents.barEmpty) + place(other, parents.other, parents.otherEmpty)
    return planned.filter { $0.method == "expectChildren" } + planned.filter { $0.method != "expectChildren" }
  }

  static func linkCount(_ nodes: [ImportBookmarkNode]) -> Int {
    nodes.reduce(0) { $0 + ($1.isFolder ? linkCount($1.children ?? []) : 1) }
  }
}

@MainActor
public enum ImportBookmarkWrites {
  public static let remapRetry: Duration = .seconds(10)

  public static func parents(hasView: Bool, document: JSONValue, bar: String, other: String) -> ImportBookmarkParents? {
    guard hasView, document["nodes"]?[bar]?["kind"]?.string == "folder", document["nodes"]?[other]?["kind"]?.string == "folder" else { return nil }
    func empty(_ id: String) -> Bool { (document["nodes"]?[id]?["children"]?.array ?? []).isEmpty }
    return ImportBookmarkParents(bar: bar, other: other, barEmpty: empty(bar), otherEmpty: empty(other))
  }

  public static func whileEngineHolds<Binding: Equatable & Sendable>(
    binding: () throws -> Binding,
    isStale: (Error) -> Bool,
    sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    now: () -> ContinuousClock.Instant = { ContinuousClock.now },
    _ attempt: @MainActor (Binding) async throws -> Void
  ) async throws -> Binding {
    let started = now()
    var current = try binding()
    var tries = 0
    while true {
      do {
        try await attempt(current)
        return current
      } catch where isStale(error) {
        try Task.checkCancellation()
        guard now() - started < remapRetry else { throw error }
        await sleep(.milliseconds(min(400, 25 << min(tries, 4))))
        tries += 1
        let next = try binding()
        guard next == current else { throw error }
        current = next
      }
    }
  }
}

@MainActor
final class ImportBookmarkQueue {
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func run<T>(_ body: () async -> T) async -> T {
    if busy { await withCheckedContinuation { waiting.append($0) } }
    busy = true
    defer {
      if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
    return await body()
  }
}
