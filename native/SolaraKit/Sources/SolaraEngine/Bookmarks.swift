import Foundation

public struct EngineBookmarkNode: Codable, Sendable, Equatable {
  public var id: String
  public var kind: String
  public var title: String
  public var url: String?
  public var addedAt: Double
  public var syncKey: String?
  public var children: [EngineBookmarkNode]?

  enum CodingKeys: String, CodingKey {
    case id
    case kind = "k"
    case title = "t"
    case url = "u"
    case addedAt = "a"
    case syncKey = "key"
    case children = "c"
  }

  public init(id: String, kind: String, title: String, url: String? = nil, addedAt: Double = 0, syncKey: String? = nil, children: [EngineBookmarkNode]? = nil) {
    self.id = id
    self.kind = kind
    self.title = title
    self.url = url
    self.addedAt = addedAt
    self.syncKey = syncKey
    self.children = children
  }
}

public struct EngineBookmarkTree: Codable, Sendable, Equatable {
  public var bar: EngineBookmarkNode
  public var other: EngineBookmarkNode

  public init(bar: EngineBookmarkNode, other: EngineBookmarkNode) {
    self.bar = bar
    self.other = other
  }
}

public struct BookmarkNode: Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: String
  public var parentId: String?
  public var title: String
  public var url: String?
  public var addedAt: Double
  public var syncKey: String?
  public var children: [String]?
  public var isFolder: Bool { kind == "folder" }

  public init(id: String, kind: String, parentId: String?, title: String, url: String? = nil, addedAt: Double = 0, syncKey: String? = nil, children: [String]? = nil) {
    self.id = id
    self.kind = kind
    self.parentId = parentId
    self.title = title
    self.url = url
    self.addedAt = addedAt
    self.syncKey = syncKey
    self.children = children
  }
}

public struct BookmarkRoots: Sendable, Equatable {
  public var bar: String
  public var other: String

  public init(bar: String, other: String) {
    self.bar = bar
    self.other = other
  }
}

public struct BookmarkSnapshot: Sendable, Equatable {
  public var roots: BookmarkRoots?
  public var nodes: [String: BookmarkNode]
  public var hasView: Bool
  public var readyForSync: Bool
  public var recoveryMessage: String?
  public var editsPaused: Bool
  public var recoveryConflictCount: Int
  public var ready: Bool {
    get { hasView }
    set { hasView = newValue }
  }
  public var revision: Int
  public var urlCount: Int { nodes.values.filter { !$0.isFolder }.count }

  public init(roots: BookmarkRoots? = nil, nodes: [String: BookmarkNode] = [:], ready: Bool = false, revision: Int = 0, readyForSync: Bool? = nil, recoveryMessage: String? = nil, editsPaused: Bool = false, recoveryConflictCount: Int = 0) {
    self.roots = roots
    self.nodes = nodes
    hasView = ready
    self.readyForSync = readyForSync ?? ready
    self.recoveryMessage = recoveryMessage
    self.editsPaused = editsPaused
    self.recoveryConflictCount = recoveryConflictCount
    self.revision = revision
  }
}

public enum BookmarkReadUnavailable: Error {
  case unsupported
}

public extension EngineClient {
  func observeBookmarks(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
  func watchBookmarks(engineProfile: String) async throws {}
  func readBookmarks(engineProfile: String) async throws -> EngineBookmarkTree { throw BookmarkReadUnavailable.unsupported }
}

@MainActor
final class BookmarkLibrary {
  let engineProfile: String
  let client: any EngineClient
  let publish: @MainActor (BookmarkSnapshot) -> Void
  let admission: @MainActor () -> Bool
  private(set) var snapshot = BookmarkSnapshot()
  private var loading = false
  private var again = false
  private var reloadWaiters: [CheckedContinuation<Void, Never>] = []

  init(engineProfile: String, client: any EngineClient, admission: @escaping @MainActor () -> Bool = { true }, publish: @escaping @MainActor (BookmarkSnapshot) -> Void) {
    self.engineProfile = engineProfile
    self.client = client
    self.publish = publish
    self.admission = admission
  }

  func reload() async {
    guard admission() else { return }
    if loading {
      again = true
      await withCheckedContinuation { reloadWaiters.append($0) }
      return
    }
    loading = true
    defer {
      loading = false
      let waiters = reloadWaiters
      reloadWaiters = []
      for waiter in waiters { waiter.resume() }
    }
    repeat {
      again = false
      do {
        guard admission() else { break }
        try await client.watchBookmarks(engineProfile: engineProfile)
        guard admission() else { break }
        let tree = try await client.readBookmarks(engineProfile: engineProfile)
        guard admission() else { break }
        let roots = BookmarkRoots(bar: "bar@\(engineProfile.isEmpty ? "default" : engineProfile)", other: "other@\(engineProfile.isEmpty ? "default" : engineProfile)")
        var nodes: [String: BookmarkNode] = [:]
        func add(_ source: EngineBookmarkNode, id: String, parentId: String?, depth: Int) throws {
          guard depth <= 512, nodes[id] == nil, source.kind == "u" || source.kind == "f" else { throw BookmarkReadUnavailable.unsupported }
          let children = source.kind == "f" ? source.children ?? [] : []
          nodes[id] = BookmarkNode(id: id, kind: source.kind == "f" ? "folder" : "url", parentId: parentId,
            title: parentId == nil ? (id == roots.bar ? "Bookmarks Bar" : "Other Bookmarks") : source.title,
            url: source.kind == "u" ? source.url ?? "" : nil, addedAt: source.addedAt, syncKey: source.syncKey,
            children: source.kind == "f" ? children.map(\.id) : nil)
          for child in children { try add(child, id: child.id, parentId: id, depth: depth + 1) }
        }
        try add(tree.bar, id: roots.bar, parentId: nil, depth: 0)
        try add(tree.other, id: roots.other, parentId: nil, depth: 0)
        guard admission() else { break }
        guard !again else { continue }
        if snapshot.roots != roots || snapshot.nodes != nodes || !snapshot.ready {
          snapshot = BookmarkSnapshot(roots: roots, nodes: nodes, ready: true, revision: snapshot.revision + 1)
          publish(snapshot)
        }
      } catch {
        break
      }
    } while again
  }
}
