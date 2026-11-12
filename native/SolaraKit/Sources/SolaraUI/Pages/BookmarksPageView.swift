import AppKit
import Observation
import SolaraEngine
import SolaraOmnibox
import SwiftUI

public struct PageBookmark: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: String
  public var parentId: String?
  public var title: String
  public var url: String?
  public var favicon: String?
  public var children: [String]?

  var isFolder: Bool { kind == "folder" }
}

public struct PageBookmarkRoots: Decodable, Equatable, Sendable {
  public var bar: String
  public var other: String
}

public enum BookmarkDrop: Equatable, Sendable {
  case into(String)
  case at(parentId: String, index: Int)
}

public enum BookmarksPageEvent: Equatable, Sendable {
  case open(String, PageOpenMode)
  case openAll(String, newWindow: Bool)
  case edit(String)
  case addGroup(String)
  case restoreArc(String)
  case delete([String])
  case undo
  case move([String], BookmarkDrop, listed: [String])
  case addBookmark(String?)
  case addFolder(String?)
  case importBookmarks
}

@MainActor
@Observable
public final class BookmarksPageModel {
  public var nodes: [String: PageBookmark] = [:]
  public var roots: PageBookmarkRoots?
  public var groupable: Set<String> = []
  public var arcRestorable: Set<String> = []
  public var bookmarkIcons: [String: String] = [:]
  public private(set) var recoveryMessage: String?
  public private(set) var editsPaused = false
  public private(set) var recoveryConflictCount = 0
  public var undoCount: Int?
  public var theme = PageTheme.fallbackLight
  public var profileId = ""
  public private(set) var engineProfile = ""
  public var folderId: String? { didSet { if folderId != oldValue { selected = [] } } }
  public var query = "" { didSet { if query != oldValue { selected = [] } } }
  public var selected: [String] = []
  public var expanded: Set<String> = []
  public var focusRequest = 0
  public var devHover: String?
  var drop: BookmarkDrop?
  var dragging: [String] = []
  @ObservationIgnored var anchor: String?
  @ObservationIgnored private var draggedRowId: String?
  @ObservationIgnored var rowFrames: [String: CGRect] = [:]
  @ObservationIgnored var rowFrameOwners: [String: UUID] = [:]
  @ObservationIgnored var treeFrames: [String: CGRect] = [:]
  @ObservationIgnored public var onEvent: (BookmarksPageEvent) -> Void = { _ in }
  @ObservationIgnored private var seen: State?
  @ObservationIgnored private let catalog: LibraryCatalog?
  @ObservationIgnored private var bookmarkObserver: Task<Void, Never>?

  public init(catalog: LibraryCatalog? = nil) { self.catalog = catalog }

  public func emit(_ event: BookmarksPageEvent) {
    if editsPaused {
      switch event {
      case .open, .openAll: break
      default: return
      }
    }
    onEvent(event)
  }


  deinit { bookmarkObserver?.cancel() }

  var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  func children(_ id: String) -> [PageBookmark] {
    (nodes[id]?.children ?? []).compactMap { nodes[$0] }
  }

  private func linksAndFolders(_ id: String) -> [PageBookmark] {
    children(id).flatMap { $0.isFolder ? [$0] + linksAndFolders($0.id) : [$0] }
  }

  func links(_ id: String) -> [PageBookmark] {
    children(id).flatMap { $0.isFolder ? links($0.id) : [$0] }
  }

  public var ids: [String] {
    if searching, let roots {
      return (linksAndFolders(roots.bar) + linksAndFolders(roots.other))
        .filter { PageFormat.matches(query, $0.title, $0.isFolder ? "" : $0.url ?? "") }
        .map(\.id)
    }
    guard let folderId else { return [] }
    return nodes[folderId]?.children?.filter { nodes[$0] != nil } ?? []
  }

  func ancestors(_ id: String) -> [PageBookmark] {
    var out: [PageBookmark] = []
    var node = nodes[id]
    while let parentId = node?.parentId, out.count < 64, let parent = nodes[parentId], parent.isFolder {
      out.append(parent)
      node = parent
    }
    return out
  }

  func path(_ id: String) -> String { ancestors(id).map(\.title).reversed().joined(separator: " › ") }

  struct TreeRow: Equatable, Identifiable {
    var id: String
    var title: String
    var depth: Int
    var hasChildren: Bool
  }

  var treeRows: [TreeRow] {
    guard let roots else { return [] }
    var rows: [TreeRow] = []
    func walk(_ id: String, _ depth: Int) {
      guard let node = nodes[id], node.isFolder else { return }
      let sub = children(id).filter(\.isFolder)
      rows.append(TreeRow(id: id, title: node.title, depth: depth, hasChildren: !sub.isEmpty))
      if expanded.contains(id) { sub.forEach { walk($0.id, depth + 1) } }
    }
    walk(roots.bar, 0)
    walk(roots.other, 0)
    return rows
  }

  func choose(folder id: String) {
    query = ""
    folderId = id
    let hidden = ancestors(id).map(\.id).filter { !expanded.contains($0) }
    if !hidden.isEmpty { expanded.formUnion(hidden) }
  }

  func select(_ id: String, command: Bool, shift: Bool) {
    let ids = ids
    if shift, let anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
      selected = Array(ids[min(a, b)...max(a, b)])
      return
    }
    anchor = id
    if command {
      if let i = selected.firstIndex(of: id) { selected.remove(at: i) } else { selected.append(id) }
    } else {
      selected = [id]
    }
  }

  func remove(_ list: [String]) {
    guard !list.isEmpty else { return }
    selected = []
    emit(.delete(list))
  }

  func beginDrag(_ id: String) {
    draggedRowId = id
    let ids = ids
    let selected = Set(selected)
    dragging = selected.contains(id) ? ids.filter { selected.contains($0) } : [id]
  }

  func dropFor(_ point: CGPoint) -> BookmarkDrop? {
    guard let folderId else { return nil }
    if let (id, _) = treeFrames.first(where: { $0.value.contains(point) }) {
      return dragging.contains(id) ? nil : .into(id)
    }
    let ids = ids
    guard let (id, frame) = rowFrames.first(where: { $0.key != draggedRowId && $0.value.contains(point) && ids.contains($0.key) }), let index = ids.firstIndex(of: id) else { return nil }
    let fraction = (point.y - frame.minY) / max(frame.height, 1)
    if nodes[id]?.isFolder == true, fraction > 0.25, fraction < 0.75, !dragging.contains(id) { return .into(id) }
    if searching { return nil }
    return .at(parentId: folderId, index: fraction < 0.5 ? index : index + 1)
  }

  func endDrag(_ point: CGPoint?) {
    let target = point.flatMap(dropFor)
    drop = nil
    let moving = dragging
    dragging = []
    draggedRowId = nil
    guard let target, !moving.isEmpty else { return }
    emit(.move(moving, target, listed: ids))
  }

  func menu(for node: PageBookmark) {
    if !selected.contains(node.id) { select(node.id, command: false, shift: false) }
    let menu = NSMenu()
    let target = PageMenuTarget()
    func item(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
      let made = NSMenuItem(title: title, action: enabled ? #selector(PageMenuTarget.run(_:)) : nil, keyEquivalent: "")
      made.target = enabled ? target : nil
      made.isEnabled = enabled
      made.representedObject = PageMenuAction(run)
      menu.addItem(made)
    }
    let id = node.id
    if let url = node.url, !node.isFolder {
      item("Open in New Tab") { [weak self] in self?.emit(.open(url, .foreground)) }
      item("Open in New Window") { [weak self] in self?.emit(.open(url, .window)) }
      item("Open in Incognito Window") { [weak self] in self?.emit(.open(url, .incognito)) }
      item("Open in Split View") { [weak self] in self?.emit(.open(url, .split)) }
      menu.addItem(.separator())
      item("Edit…") { [weak self] in self?.emit(.edit(id)) }
      item("Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanUrl(url), forType: .string)
      }
    } else {
      item("Open All (\(links(id).count))") { [weak self] in self?.emit(.openAll(id, newWindow: false)) }
      item("Open All in New Window") { [weak self] in self?.emit(.openAll(id, newWindow: true)) }
      item("Add to Sidebar as Group", enabled: groupable.contains(id)) { [weak self] in self?.emit(.addGroup(id)) }
      if arcRestorable.contains(id) { item("Restore Arc Folders as Groups") { [weak self] in self?.emit(.restoreArc(id)) } }
      menu.addItem(.separator())
      item("Rename…") { [weak self] in self?.emit(.edit(id)) }
    }
    if searching, let parentId = node.parentId { item("Show in Folder") { [weak self] in self?.choose(folder: parentId) } }
    menu.addItem(.separator())
    item("Delete") { [weak self] in
      guard let self else { return }
      remove(selected.contains(id) ? selected : [id])
    }
    objc_setAssociatedObject(menu, &PageMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    PageMenuTarget.show(menu, in: nil, at: nil)
  }

  func organizeMenu() {
    let menu = NSMenu()
    let target = PageMenuTarget()
    func item(_ title: String, _ run: @escaping () -> Void) {
      let made = NSMenuItem(title: title, action: #selector(PageMenuTarget.run(_:)), keyEquivalent: "")
      made.target = target
      made.representedObject = PageMenuAction(run)
      menu.addItem(made)
    }
    let parent = folderId
    item("Add New Bookmark…") { [weak self] in self?.emit(.addBookmark(parent)) }
    item("Add New Folder…") { [weak self] in self?.emit(.addFolder(parent)) }
    menu.addItem(.separator())
    item("Import Bookmarks…") { [weak self] in self?.emit(.importBookmarks) }
    objc_setAssociatedObject(menu, &PageMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    PageMenuTarget.show(menu, in: nil, at: nil)
  }

  public struct State: Decodable, Equatable, Sendable {
    public var engineProfile: String
    public var groupable: [String]
    public var arcRestorable: [String]
    public var bookmarkIcons: [String: String]
    public var undoCount: Int?
    public var profileId: String
    public var dark: Bool
    public var theme: [String: String]
    public var panelShadowOpacity: Double?
  }

  public func apply(snapshot: BookmarkSnapshot) {
    recoveryMessage = snapshot.recoveryMessage
    editsPaused = snapshot.editsPaused
    recoveryConflictCount = snapshot.recoveryConflictCount
    let next: [String: PageBookmark] = snapshot.ready ? snapshot.nodes.mapValues { node in
      PageBookmark(id: node.id, kind: node.kind, parentId: node.parentId, title: node.title,
        url: node.url, favicon: bookmarkIcons[node.id], children: node.children)
    } : [:]
    let nextRoots = snapshot.ready ? snapshot.roots.map { PageBookmarkRoots(bar: $0.bar, other: $0.other) } : nil
    if nodes != next { nodes = next }
    if roots != nextRoots {
      let previous = roots
      roots = nextRoots
      if let nextRoots, previous == nil {
        expanded.formUnion([nextRoots.bar, nextRoots.other])
        folderId = nextRoots.bar
      }
    }
    if let roots, folderId.flatMap({ nodes[$0] })?.isFolder != true { folderId = roots.bar }
    let live = Set(nodes.keys)
    if selected.contains(where: { !live.contains($0) }) { selected = selected.filter { live.contains($0) } }
  }

  private func observeBookmarks() {
    bookmarkObserver?.cancel()
    guard let catalog else { return }
    let profile = engineProfile
    apply(snapshot: catalog.bookmarks(engineProfile: profile))
    bookmarkObserver = Task { [weak self] in
      for await snapshot in catalog.observeBookmarks(engineProfile: profile) {
        guard !Task.isCancelled, self?.engineProfile == profile else { return }
        self?.apply(snapshot: snapshot)
      }
    }
  }

  public func apply(json: String) {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
    let previous = seen
    seen = state
    let next = PageTheme(dark: state.dark, tokens: state.theme, panelShadowOpacity: state.panelShadowOpacity)
    if theme != next { theme = next }
    profileId = state.profileId
    if bookmarkIcons != state.bookmarkIcons {
      bookmarkIcons = state.bookmarkIcons
      if previous?.engineProfile == state.engineProfile, let catalog { apply(snapshot: catalog.bookmarks(engineProfile: engineProfile)) }
    }
    if previous?.engineProfile != state.engineProfile {
      engineProfile = state.engineProfile
      observeBookmarks()
    }
    if previous?.groupable != state.groupable { groupable = Set(state.groupable) }
    if previous?.arcRestorable != state.arcRestorable { arcRestorable = Set(state.arcRestorable) }
    if undoCount != state.undoCount { undoCount = state.undoCount }
  }
}

public struct BookmarksPageView: View {
  @Bindable var model: BookmarksPageModel
  let favicons: PageFavicons?

  public init(model: BookmarksPageModel, favicons: PageFavicons?) {
    self.model = model
    self.favicons = favicons
  }

  public var body: some View {
    let theme = model.theme
    let ids = model.ids
    let searching = model.searching
    ZStack(alignment: .bottom) {
      VStack(spacing: 0) {
        PageHeader(title: "Bookmarks", query: $model.query, placeholder: "Search bookmarks", focus: model.focusRequest) {
          if !model.selected.isEmpty {
            OnboardingText("\(model.selected.count) selected", size: 12, color: theme.textSecondary, lines: 1).fixedSize()
            PageButton(title: "Delete", kind: .primary) { model.remove(model.selected) }
          } else {
            PageIconButton(icon: "ellipsis.circle", size: 15, box: 30, radius: 7, nudge: 0, tooltip: "Organize") { model.organizeMenu() }
          }
        }
        if let message = model.recoveryMessage {
          Text(message).font(.system(size: 12)).foregroundStyle(theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
        }
        if model.recoveryConflictCount > 0 {
          Text("Some bookmark changes need recovery. Their saved source has been retained.").font(.system(size: 12)).foregroundStyle(theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
        }
        HStack(alignment: .top, spacing: 16) {
          ScrollView {
            VStack(spacing: 0) {
              ForEach(model.treeRows) { row in
                BookmarkTreeRowView(row: row, model: model)
              }
            }
            .padding(.vertical, 4)
          }
          .scrollContentBackground(.hidden)
          .frame(width: 230)
          VStack(spacing: 0) {
            HStack(spacing: 8) {
              OnboardingText(searching ? "Results for “\(model.query.trimmingCharacters(in: .whitespaces))”" : model.folderId.flatMap { model.nodes[$0]?.title } ?? "", size: 13, weight: 600, color: theme.textPrimary, lines: 1)
                .offset(y: -0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
              if !searching, let folderId = model.folderId {
                PageButton(title: "Open All", disabled: ids.isEmpty) { model.emit(.openAll(folderId, newWindow: false)) }
              }
            }
            .padding(.horizontal, 15)
            .frame(height: 40)
            Rectangle().fill(theme.separator).frame(height: 1)
            if ids.isEmpty {
              BookmarksEmptyState(searching: searching)
            } else {
              BookmarksList(ids: ids, model: model)
            }
          }
          .padding(.top, 1)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RoundedRectangle(cornerRadius: 12, style: .circular).fill(theme.group))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
          .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(theme.groupBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
      }
      if let count = model.undoCount {
        BookmarksUndoToast(message: "\(count) item\(count == 1 ? "" : "s") deleted") { model.emit(.undo) }
          .padding(.bottom, 24)
      }
    }
    .environment(\.pageTheme, model.theme)
    .environment(\.pageFavicons, favicons)
  }
}

struct BookmarksEmptyState: View {
  @Environment(\.pageTheme) private var theme
  let searching: Bool

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: searching ? "magnifyingglass" : "bookmark").font(.system(size: 26)).foregroundStyle(theme.textTertiary).frame(width: 36, height: 36)
      OnboardingText(searching ? "No search results found" : "This folder is empty", size: 15, weight: 500, color: theme.textSecondary, lines: 1).fixedSize()
    }
    .padding(.bottom, 80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct BookmarksList: View {
  let ids: [String]
  let model: BookmarksPageModel
  @FocusState private var focused: Bool

  var body: some View {
    let indicator: Int? = if case .at(_, let index) = model.drop { index } else { nil }
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
          if indicator == index { BookmarkDropLine() }
          if let node = model.nodes[id] {
            BookmarkRowView(node: node, model: model, onFocus: { focused = true })
          }
        }
        if indicator == ids.count { BookmarkDropLine() }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
    }
    .scrollContentBackground(.hidden)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
      model.remove(model.selected)
      return .handled
    }
    .onKeyPress(keys: ["a"]) { press in
      guard press.modifiers.contains(.command) else { return .ignored }
      model.selected = ids
      return .handled
    }
  }
}

struct BookmarkDropLine: View {
  @Environment(\.pageTheme) private var theme

  var body: some View {
    RoundedRectangle(cornerRadius: 1, style: .circular).fill(theme.accent).frame(height: 2).padding(.horizontal, 8).padding(.vertical, -1).zIndex(5)
  }
}

struct BookmarkRowView: View {
  @Environment(\.pageTheme) private var theme
  let node: PageBookmark
  let model: BookmarksPageModel
  let onFocus: () -> Void
  @State private var hovered = false
  @State private var dy: CGFloat = 0
  @State private var frameId = UUID()
  @State private var rowFrame: CGRect?

  var body: some View {
    let selected = model.selected.contains(node.id)
    let highlighted = model.drop == .into(node.id)
    let lit = hovered || model.devHover == node.id
    let dragging = model.dragging.contains(node.id) && dy != 0
    let accent = theme.accent
    let fill: Color =
      selected ? accent.opacity(theme.dark ? 0x59 / 255.0 : 0x33 / 255.0) : highlighted ? accent.opacity(0x40 / 255.0) : lit ? theme.rowHover : .clear
    let detail = model.searching ? model.path(node.id) : node.isFolder ? "\(node.children?.count ?? 0) item\(node.children?.count == 1 ? "" : "s")" : PageFormat.hostLabel(node.url ?? "")
    HStack(spacing: 10) {
      if node.isFolder {
        Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(theme.icon).offset(x: -0.5, y: -0.5).frame(width: 16, height: 16)
      } else {
        PageFavicon(url: node.url ?? "", favicon: node.favicon, profileId: model.profileId)
      }
      HStack(spacing: 9.5) {
        OnboardingText(node.title.isEmpty ? (node.url ?? "") : node.title, size: 13, color: theme.textPrimary, lines: 1)
          .offset(y: -0.5)
        OnboardingText(detail, size: 12, color: theme.textTertiary, lines: 1)
          .offset(y: -0.5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(-1)
      }
      PageIconButton(icon: "ellipsis", size: 13, box: 24, radius: 6, tooltip: "More actions") { model.menu(for: node) }
        .opacity(lit ? 1 : 0)
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background(RoundedRectangle(cornerRadius: 7, style: .circular).fill(fill))
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture(count: 2) { node.isFolder ? model.choose(folder: node.id) : model.emit(.open(node.url ?? "", .current)) }
    .simultaneousGesture(TapGesture().onEnded {
      onFocus()
      let flags = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
      model.select(node.id, command: flags.contains(.command), shift: flags.contains(.shift))
    })
    .gesture(
      DragGesture(minimumDistance: 4, coordinateSpace: .global)
        .onChanged { value in
          if model.dragging.isEmpty { model.beginDrag(node.id) }
          dy = value.translation.height
          let next = model.dropFor(value.location)
          if next != model.drop { model.drop = next }
        }
        .onEnded { value in
          dy = 0
          model.endDrag(value.location)
        }
    )
    .offset(y: dragging ? dy : 0)
    .opacity(dragging ? 0.85 : 1)
    .zIndex(dragging ? 10 : 0)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { next in
      rowFrame = next
      model.rowFrames[node.id] = next
      model.rowFrameOwners[node.id] = frameId
    }
    .onAppear {
      if let rowFrame {
        model.rowFrames[node.id] = rowFrame
        model.rowFrameOwners[node.id] = frameId
      }
    }
    .onDisappear {
      if model.rowFrameOwners[node.id] == frameId {
        model.rowFrames[node.id] = nil
        model.rowFrameOwners[node.id] = nil
      }
    }
    .contextMenu { BookmarkRowMenuProxy(node: node, model: model) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(named: "More Actions") { model.menu(for: node) }
    .pageProbe("bookmark:\(node.id)")
  }
}

struct BookmarkRowMenuProxy: View {
  let node: PageBookmark
  let model: BookmarksPageModel

  var body: some View {
    if let url = node.url, !node.isFolder {
      Button("Open in New Tab") { model.emit(.open(url, .foreground)) }
      Button("Open in New Window") { model.emit(.open(url, .window)) }
      Button("Open in Incognito Window") { model.emit(.open(url, .incognito)) }
      Button("Open in Split View") { model.emit(.open(url, .split)) }
      Divider()
      Button("Edit…") { model.emit(.edit(node.id)) }
      Button("Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanUrl(url), forType: .string)
      }
    } else {
      Button("Open All (\(model.links(node.id).count))") { model.emit(.openAll(node.id, newWindow: false)) }
      Button("Open All in New Window") { model.emit(.openAll(node.id, newWindow: true)) }
      Button("Add to Sidebar as Group") { model.emit(.addGroup(node.id)) }.disabled(!model.groupable.contains(node.id))
      if model.arcRestorable.contains(node.id) { Button("Restore Arc Folders as Groups") { model.emit(.restoreArc(node.id)) } }
      Divider()
      Button("Rename…") { model.emit(.edit(node.id)) }
    }
    if model.searching, let parentId = node.parentId { Button("Show in Folder") { model.choose(folder: parentId) } }
    Divider()
    Button("Delete") { model.remove(model.selected.contains(node.id) ? model.selected : [node.id]) }
  }
}

struct BookmarkTreeRowView: View {
  @Environment(\.pageTheme) private var theme
  let row: BookmarksPageModel.TreeRow
  let model: BookmarksPageModel
  @State private var hovered = false

  var body: some View {
    let selected = !model.searching && model.folderId == row.id
    let target = model.drop == .into(row.id)
    let open = model.expanded.contains(row.id)
    HStack(spacing: 0) {
      ZStack {
        if row.hasChildren {
          Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(selected ? Color.white.opacity(0.8) : theme.textSecondary)
        }
      }
      .frame(width: 16, height: 28)
      .contentShape(Rectangle())
      .onTapGesture {
        guard row.hasChildren else { return }
        if open { model.expanded.remove(row.id) } else { model.expanded.insert(row.id) }
      }
      .accessibilityLabel(open ? "Collapse" : "Expand")
      .accessibilityAddTraits(.isButton)
      .accessibilityHidden(!row.hasChildren)
      Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(selected ? Color.white : theme.icon).frame(width: 18, height: 18)
      OnboardingText(row.title, size: 13, color: selected ? .white : theme.textPrimary, lines: 1)
        .offset(y: -0.5)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 4 + CGFloat(row.depth) * 16)
    .padding(.trailing, 8)
    .frame(height: 28)
    .background(RoundedRectangle(cornerRadius: 6, style: .circular).fill(selected ? theme.accent : hovered ? theme.selected : .clear))
    .background(RoundedRectangle(cornerRadius: 6, style: .circular).fill(target ? theme.accent.opacity(0x40 / 255.0) : .clear))
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture { model.choose(folder: row.id) }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.treeFrames[row.id] = $0 }
    .onDisappear { model.treeFrames[row.id] = nil }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .pageProbe("folder:\(row.id)")
  }
}

struct BookmarksUndoToast: View {
  @Environment(\.pageTheme) private var theme
  let message: String
  let onUndo: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      OnboardingText(message, size: 13, color: .white, lines: 1).fixedSize()
      OnboardingText("Undo", size: 13, weight: 600, color: Color(.sRGB, red: 0x64 / 255, green: 0xA8 / 255, blue: 1, opacity: 1), lines: 1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onUndo)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onUndo)
        .pageProbe("Undo")
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .frame(height: 38)
    .background(RoundedRectangle(cornerRadius: 10, style: .circular).fill(theme.dark ? Color(.sRGB, red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255) : Color(.sRGB, red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)))
  }
}
