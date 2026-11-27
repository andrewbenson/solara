import SolaraEngine
import SolaraModel

public struct BookmarkHolderCatalog {
  public let profile: String
  public let snapshot: BookmarkWriterSnapshot

  public init(profile: String, snapshot: BookmarkWriterSnapshot) {
    self.profile = profile
    self.snapshot = snapshot
  }
}

public struct BookmarkHolder {
  fileprivate struct Key: Hashable {
    let engine: JSKey
    let id: JSKey
  }

  public let profile: String
  public let binding: BookmarkWriterBinding
  public let id: String
  public let drafts: [JSONValue]
  fileprivate let nodes: JSONObject
  fileprivate let links: [String: String]
  fileprivate var key: Key { Key(engine: JSKey(binding.engine), id: JSKey(id)) }

  func removals(carried: Set<String>) -> [String] {
    func take(_ id: String, depth: Int) -> (whole: Bool, ids: [String]) {
      guard depth < 64, let node = nodes[id] else { return (false, []) }
      if node["kind"] == "url" { return carried.contains(id) ? (true, [id]) : (false, []) }
      let parts = (node["children"]?.array?.compactMap(\.string) ?? []).map { take($0, depth: depth + 1) }
      return !parts.isEmpty && parts.allSatisfy(\.whole) ? (true, [id]) : (false, parts.flatMap(\.ids))
    }
    let removed = drafts.compactMap { $0["id"]?.string }.flatMap { take($0, depth: 0).ids }
    let children = nodes[id]?["children"]?.array?.compactMap(\.string) ?? []
    let removing = Set(removed)
    return !children.isEmpty && children.allSatisfy(removing.contains) ? [id] : removed
  }

  fileprivate func removalMutations(_ ids: [String]) -> [BookmarkMutation] {
    [
      BookmarkMutation(method: "expectBookmarkNodes", args: [.object(nodes)]),
      BookmarkMutation(method: "removeBookmarks", args: [JSONValue(ids)]),
    ]
  }
}

@MainActor
public final class BookmarkHolderRestoration {
  private var pending: [BookmarkHolder.Key: Task<Void, Never>] = [:]
  private var filed: [BookmarkHolder.Key: (binding: BookmarkWriterBinding, links: [String: String])] = [:]
  private var drains = 0

  public init() {}

  public nonisolated static func holders(in catalogs: [BookmarkHolderCatalog]) -> [BookmarkHolder] {
    var engines = Set<JSKey>()
    var holders: [BookmarkHolder] = []
    for catalog in catalogs where catalog.snapshot.hasView {
      let binding = catalog.snapshot.binding
      guard engines.insert(JSKey(binding.engine)).inserted else { continue }
      let nodes = catalog.snapshot.document["nodes"]?.object ?? [:]
      let bar = BookmarkFlat.roots(binding.engine).bar
      for id in nodes[bar]?["children"]?.array?.compactMap(\.string) ?? [] {
        guard let holder = nodes[id], holder["kind"] == "folder", holder["parentId"] == .string(bar),
          holder["title"]?.string?.hasSuffix(" (Arc)") == true else { continue }
        var seen: Set<JSKey> = [JSKey(id)]
        var expected: JSONObject = [id: holder]
        var links: [String: String] = [:]
        let drafts = (holder["children"]?.array?.compactMap(\.string) ?? []).compactMap { child -> JSONValue? in
          guard nodes[child]?["kind"] == "folder", nodes[child]?["parentId"] == .string(id) else { return nil }
          let before = links.count
          let folder = BookmarkGroupDraft.build(child, nodes: nodes, depth: 1, seen: &seen, expected: &expected, links: &links)
          return links.count > before ? folder : nil
        }
        guard !drafts.isEmpty else { continue }
        holders.append(BookmarkHolder(profile: catalog.profile, binding: binding, id: id, drafts: drafts, nodes: expected, links: links))
      }
    }
    return holders
  }

  public func restore(_ holder: BookmarkHolder, safeMode: Bool, refuse: () -> Void,
    place: (BookmarkHolder) -> Set<String>,
    remove: @escaping @MainActor (BookmarkHolder, [BookmarkMutation]) async throws -> Void) async {
    await start(holder, safeMode: safeMode, refuse: refuse, place: place, remove: remove)?.value
  }

  public var draining: Bool { drains > 0 }

  public func start(_ holder: BookmarkHolder, safeMode: Bool, refuse: () -> Void,
    place: (BookmarkHolder) -> Set<String>,
    remove: @escaping @MainActor (BookmarkHolder, [BookmarkMutation]) async throws -> Void) -> Task<Void, Never>? {
    guard !draining else { return nil }
    if safeMode { refuse(); return nil }
    if let active = pending[holder.key] { return active }
    let previous = filed[holder.key]
    var carried = previous?.binding == holder.binding
      ? previous?.links.filter { holder.links[$0.key] == $0.value } ?? [:] : [:]
    if carried.count < holder.links.count {
      for id in place(holder) { carried[id] = holder.links[id] }
    }
    let ids = holder.removals(carried: Set(carried.keys))
    guard !ids.isEmpty else { filed[holder.key] = nil; return nil }
    let task = Task {
      defer { pending[holder.key] = nil }
      do {
        try await remove(holder, holder.removalMutations(ids))
        filed[holder.key] = nil
      } catch {
        filed[holder.key] = (holder.binding, carried)
      }
    }
    pending[holder.key] = task
    return task
  }

  public func beginDrain() -> @MainActor () async -> Void {
    drains += 1
    let tasks = Array(pending.values)
    return { [self] in
      for task in tasks { await task.value }
      drains -= 1
    }
  }
}
