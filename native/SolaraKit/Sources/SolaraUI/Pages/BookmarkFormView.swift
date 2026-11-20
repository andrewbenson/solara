import AppKit
import Observation
import SolaraOmnibox
import SwiftUI

public enum BookmarkFormEvent: Equatable, Sendable {
  case done(name: String, folderId: String?)
  case remove
  case cancel
  case save(name: String, url: String, parentId: String?)
  case newFolder(parentId: String?)
}

@MainActor
@Observable
public final class BookmarkFormModel {
  public enum Kind: String, Decodable, Sendable {
    case page, allTabs, editBookmark, addBookmark, renameFolder, newFolder
  }

  public struct Placement: Decodable, Equatable, Sendable {
    public var top: Double
    public var left: Double?
    public var right: Double?
  }

  public struct State: Decodable, Equatable, Sendable {
    public var kind: Kind
    public var key: String
    public var name: String
    public var url: String?
    public var folderId: String?
    public var tabCount: Int?
    public var folders: [PageBookmark]
    public var roots: PageBookmarkRoots?
    public var placement: Placement?
    public var select: String?
    public var selectRev: Int?
    public var dark: Bool
  }

  public var kind: Kind = .page
  public var name = ""
  public var url = ""
  public var folderId: String?
  public var tabCount = 0
  public var folders: [String: PageBookmark] = [:]
  public var roots: PageBookmarkRoots?
  public var placement: Placement?
  public var expanded: Set<String> = []
  public var dark = false
  public var focusRequest = 0
  @ObservationIgnored public var onEvent: (BookmarkFormEvent) -> Void = { _ in }
  @ObservationIgnored private var seen: State?

  public init() {}

  var isPopover: Bool { kind == .page || kind == .allTabs }
  var isFolder: Bool { kind == .renameFolder || kind == .newFolder }
  var showsURL: Bool { kind == .editBookmark || kind == .addBookmark }
  var showsPicker: Bool { kind != .renameFolder }

  var heading: String {
    switch kind {
    case .page: "Bookmark Added"
    case .allTabs: "Bookmark \(tabCount) Tabs"
    case .editBookmark: "Edit Bookmark"
    case .addBookmark: "Add Bookmark"
    case .renameFolder: "Rename Folder"
    case .newFolder: "New Folder"
    }
  }

  var nameLabel: String { kind == .allTabs ? "Folder name" : "Name" }
  var namePlaceholder: String { kind == .allTabs ? "Tabs" : isPopover ? "Name" : "" }

  public var valid: Bool {
    if isPopover { return true }
    return isFolder ? !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !resolveInput(url).isEmpty
  }

  func children(_ id: String) -> [PageBookmark] {
    (folders[id]?.children ?? []).compactMap { folders[$0] }.filter(\.isFolder)
  }

  func ancestors(_ id: String) -> [String] {
    var out: [String] = []
    var node = folders[id]
    while let parentId = node?.parentId, out.count < 64, let parent = folders[parentId] {
      out.append(parent.id)
      node = parent
    }
    return out
  }

  func reveal(_ id: String?) {
    guard let id else { return }
    expanded.formUnion(ancestors(id))
  }

  func submit() {
    if isPopover { return onEvent(.done(name: name, folderId: folderId)) }
    guard valid else { return }
    onEvent(.save(name: name, url: url, parentId: folderId))
  }

  func escape() {
    if isPopover { onEvent(.done(name: name, folderId: folderId)) } else { onEvent(.cancel) }
  }

  public func apply(json: String) {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
    let previous = seen
    seen = state
    dark = state.dark
    placement = state.placement
    if previous?.folders != state.folders { folders = Dictionary(state.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    roots = state.roots
    if previous?.key != state.key {
      kind = state.kind
      name = state.name
      url = state.url ?? ""
      folderId = state.folderId
      tabCount = state.tabCount ?? 0
      expanded = Set([state.roots?.bar, state.roots?.other].compactMap { $0 })
      reveal(state.folderId)
      focusRequest += 1
    }
    if let select = state.select, previous?.selectRev != state.selectRev {
      folderId = select
      reveal(select)
    }
  }
}

public struct BookmarkFormView: View {
  @Bindable var model: BookmarkFormModel

  public init(model: BookmarkFormModel) {
    self.model = model
  }

  public var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(model.isPopover ? Color.clear : Color.black.opacity(model.dark ? 0.35 : 0.15))
          .contentShape(Rectangle())
          .onTapGesture { model.isPopover ? model.submit() : model.onEvent(.cancel) }
          .accessibilityHidden(true)
        if model.isPopover {
          BookmarkFormPanel(model: model, width: 320)
            .offset(x: popoverX(in: proxy.size.width), y: model.placement?.top ?? 0)
        } else {
          BookmarkFormPanel(model: model, width: 420)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
      }
    }
    .preferredColorScheme(model.dark ? .dark : .light)
  }

  private func popoverX(in width: CGFloat) -> CGFloat {
    if let left = model.placement?.left { return left }
    return width - (model.placement?.right ?? 0) - 320
  }
}

struct BookmarkFormPanel: View {
  @Bindable var model: BookmarkFormModel
  let width: CGFloat
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(model.heading)
        .font(model.isPopover ? .headline : .title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      label(model.nameLabel)
      TextField(model.nameLabel, text: $model.name, prompt: Text(model.namePlaceholder))
        .textContentType(.solaraPlainText)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .focused($nameFocused)
        .onSubmit { model.submit() }
        .pageProbe("Name field")
      if model.showsURL {
        label("URL")
        TextField("URL", text: $model.url, prompt: Text("https://"))
          .textContentType(.URL)
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .onSubmit { model.submit() }
          .pageProbe("URL field")
      }
      if model.showsPicker {
        label("Folder")
        BookmarkFolderPicker(model: model)
          .frame(height: model.isPopover ? 176 : 180)
      }
      HStack(spacing: 8) {
        if model.isPopover {
          Button("New Folder") { model.onEvent(.newFolder(parentId: model.folderId)) }
            .focusable(false)
            .pageProbe("New Folder")
        }
        Spacer(minLength: 0)
        switch model.kind {
        case .page:
          Button("Remove") { model.onEvent(.remove) }.pageProbe("Remove")
          Button("Done") { model.submit() }.keyboardShortcut(.defaultAction).pageProbe("Done")
        case .allTabs:
          Button("Cancel") { model.onEvent(.cancel) }.pageProbe("Cancel")
          Button("Save") { model.submit() }.keyboardShortcut(.defaultAction).pageProbe("Save")
        default:
          Button("Cancel") { model.onEvent(.cancel) }.pageProbe("Cancel")
          Button("Save") { model.submit() }.keyboardShortcut(.defaultAction).disabled(!model.valid).pageProbe("Save")
        }
      }
      .controlSize(.regular)
      .padding(.top, model.isPopover ? 14 : 18)
    }
    .padding(model.isPopover ? 14 : 18)
    .frame(width: width, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: model.isPopover ? 12 : 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: model.isPopover ? 12 : 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    .shadow(color: .black.opacity(model.dark ? 0.45 : 0.18), radius: model.isPopover ? 24 : 30, y: model.isPopover ? 10 : 12)
    .contentShape(Rectangle())
    .onTapGesture {}
    .onExitCommand { model.escape() }
    .onAppear { DispatchQueue.main.async { nameFocused = true } }
    .onChange(of: model.focusRequest) { _, _ in DispatchQueue.main.async { nameFocused = true } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.heading)
    .accessibilityAddTraits(.isModal)
  }

  private func label(_ text: String) -> some View {
    Text(text).font(.subheadline).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 5)
  }
}

struct BookmarkFolderPicker: View {
  @Bindable var model: BookmarkFormModel

  var body: some View {
    List(selection: $model.folderId) {
      if let roots = model.roots {
        ForEach([roots.bar, roots.other], id: \.self) { id in
          if let node = model.folders[id] { BookmarkFolderNode(node: node, model: model) }
        }
      }
    }
    .listStyle(.bordered(alternatesRowBackgrounds: false))
    .accessibilityLabel("Folder")
  }
}

struct BookmarkFolderNode: View {
  let node: PageBookmark
  @Bindable var model: BookmarkFormModel

  var body: some View {
    let sub = model.children(node.id)
    if sub.isEmpty {
      row
    } else {
      DisclosureGroup(isExpanded: Binding(
        get: { model.expanded.contains(node.id) },
        set: { open in if open { model.expanded.insert(node.id) } else { model.expanded.remove(node.id) } }
      )) {
        ForEach(sub) { child in BookmarkFolderNode(node: child, model: model) }
      } label: {
        row
      }
    }
  }

  private var row: some View {
    Label(node.title, systemImage: "folder").tag(Optional(node.id)).lineLimit(1).pageProbe("pick:\(node.id)")
  }
}
