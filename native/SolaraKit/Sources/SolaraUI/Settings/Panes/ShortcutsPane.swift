import AppKit
import Observation
import SolaraModel
import SwiftUI

@MainActor
public protocol ShortcutsServices: AnyObject {
  func menuShortcuts() async -> [MenuShortcutItem]
  func menuShortcutChanges() -> AsyncStream<Void>
  func openURLs(_ urls: [String])
}

enum ShortcutFilter: String, CaseIterable, Hashable {
  case all
  case customized
  case conflicts

  var title: String {
    switch self {
    case .all: "All Shortcuts"
    case .customized: "Customized Shortcuts"
    case .conflicts: "Conflicting Shortcuts"
    }
  }
}

@MainActor
@Observable
public final class ShortcutsPaneModel: SettingsPaneProvider {
  public static let extensionShortcutsURL = "chrome://extensions/shortcuts"
  static let conflictColor = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)

  @ObservationIgnored let services: ShortcutsServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored let recorder: ShortcutRecording
  @ObservationIgnored private var watching: Task<Void, Never>?
  var items: [MenuShortcutItem]?
  var query = ""
  var filter: ShortcutFilter = .all
  var recording: String?

  public init(services: ShortcutsServices, store: SettingsStoreSource, recorder: ShortcutRecording? = nil) {
    self.services = services
    self.store = store
    self.recorder = recorder ?? ShortcutKeyRecorder()
  }

  isolated deinit {
    watching?.cancel()
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { items != nil }

  public func prepare(_ place: SettingsPlace) async {
    watchMenuBar()
    if items == nil { await reload() }
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(ShortcutsPane(model: self))
  }

  func reload() async {
    items = await services.menuShortcuts()
  }

  private func watchMenuBar() {
    guard watching == nil else { return }
    let changes = services.menuShortcutChanges()
    watching = Task { [weak self] in
      for await _ in changes {
        guard let self else { return }
        await self.reload()
      }
    }
  }

  var overrides: ShortcutOverrides {
    guard let object = store.settingValue("shortcuts")?.object else { return [:] }
    var result: ShortcutOverrides = [:]
    for (id, value) in object {
      result[id] = (value.array ?? []).compactMap(\.string)
    }
    return result
  }

  var precedences: ShortcutPrecedences {
    guard let object = store.settingValue("shortcutPrecedence")?.object else { return [:] }
    var result: ShortcutPrecedences = [:]
    for (id, value) in object {
      if let precedence = value.string.flatMap(ShortcutPrecedence.init(rawValue:)) { result[id] = precedence }
    }
    return result
  }

  func precedence(of item: MenuShortcutItem, in precedences: ShortcutPrecedences) -> ShortcutPrecedence? {
    guard let standard = item.defaultPrecedence else { return nil }
    if item.precedenceFixed { return .solara }
    return precedences[item.id] ?? standard
  }

  func setPrecedence(_ item: MenuShortcutItem, _ precedence: ShortcutPrecedence?) {
    var next = store.settingValue("shortcutPrecedence")?.object ?? JSONObject()
    if let precedence, precedence != item.defaultPrecedence, !item.precedenceFixed {
      next[item.id] = .string(precedence.rawValue)
    } else {
      _ = next.removeValue(forKey: item.id)
    }
    store.updateSettings(["shortcutPrecedence": .object(next)])
  }

  func customized(_ item: MenuShortcutItem, overrides: ShortcutOverrides, precedences: ShortcutPrecedences) -> Bool {
    overrides[item.id] != nil || precedences[item.id] != nil
  }

  func reset(_ item: MenuShortcutItem) {
    setShortcut(item.id, nil)
    setPrecedence(item, nil)
  }

  func resolved(_ overrides: ShortcutOverrides) -> ResolvedShortcuts {
    ResolvedShortcuts((items ?? []).map(ShortcutSource.init), overrides: overrides)
  }

  func conflicts(of item: MenuShortcutItem, in resolved: ResolvedShortcuts) -> [MenuShortcutItem] {
    let byId = Dictionary((items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return resolved.conflicts(of: item.id).compactMap { byId[$0] }
  }

  func shown(_ resolved: ResolvedShortcuts, overrides: ShortcutOverrides, precedences: ShortcutPrecedences = [:]) -> [MenuShortcutItem] {
    (items ?? []).filter { item in
      guard ShortcutQuery.matches(query, item.title, item.path.joined(separator: " "), resolved.effective(item.id).formatted) else { return false }
      switch filter {
      case .all: return true
      case .customized: return customized(item, overrides: overrides, precedences: precedences)
      case .conflicts: return !resolved.conflicts(of: item.id).isEmpty
      }
    }
  }

  static func menus(of items: [MenuShortcutItem]) -> [String] {
    var seen: [String] = []
    for item in items where !seen.contains(item.menu) { seen.append(item.menu) }
    return seen
  }

  static func conflictText(_ others: [MenuShortcutItem]) -> String? {
    guard !others.isEmpty else { return nil }
    let lead = others.count == 1 ? "This shortcut conflicts with another shortcut:" : "This shortcut conflicts with other shortcuts:"
    return "\(lead) \(others.map(\.title).joined(separator: ", "))"
  }

  static func pathText(_ item: MenuShortcutItem) -> String? {
    item.path.count > 1 ? item.path.dropFirst().joined(separator: " › ") : nil
  }

  func setShortcut(_ id: String, _ shortcut: KeyShortcut?) {
    var next = store.settingValue("shortcuts")?.object ?? JSONObject()
    if let shortcut {
      next[id] = .array(shortcut.stored.map(JSONValue.string))
    } else {
      _ = next.removeValue(forKey: id)
    }
    store.updateSettings(["shortcuts": .object(next)])
  }

  func record(_ item: MenuShortcutItem) async {
    recording = item.id
    let shortcut = await recorder.record()
    if recording == item.id { recording = nil }
    guard let shortcut else { return }
    setShortcut(item.id, shortcut.same(as: item.defaultShortcut) ? nil : shortcut)
  }

  func clear(_ item: MenuShortcutItem) {
    setShortcut(item.id, item.defaultShortcut.key.isEmpty ? nil : .empty)
  }

  func resetAll() {
    store.updateSettings(["shortcuts": .object(JSONObject()), "shortcutPrecedence": .object(JSONObject())])
  }

  func cancelRecording() {
    recorder.cancel()
    recording = nil
  }
}

struct ShortcutsPane: View {
  @Environment(\.settingsContext) private var context
  @Bindable var model: ShortcutsPaneModel

  var body: some View {
    let overrides = model.overrides
    let precedences = model.precedences
    let resolved = model.resolved(overrides)
    let shown = model.shown(resolved, overrides: overrides, precedences: precedences)
    let app = context?.appName ?? ""
    SettingsForm {
      Section {
        SettingToggle("shortcuts.undoReopensClosedTab", key: "undoReopensClosedTab")
        SettingToggle("shortcuts.showTabNumberHints", key: "showTabNumberHints")
      } header: {
        Text("Perform common actions in \(app) faster and from anywhere. Select an action to customize its keyboard shortcut.")
          .font(.callout)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        EmptyView()
      } header: {
        SettingsAnchor("shortcuts.actions") {
          HStack(spacing: 8) {
            ShortcutsSearchField(text: $model.query)
              .frame(maxWidth: .infinity)
            SettingsPopUp(ShortcutFilter.allCases.map { SettingsPopUpItem($0, $0.title) }, selection: $model.filter)
              .frame(minWidth: 170)
              .fixedSize()
            Button("Reset All Shortcuts") { model.resetAll() }
              .disabled(overrides.isEmpty && precedences.isEmpty)
          }
          .font(.body)
          .fontWeight(.regular)
        }
      }

      if model.items != nil && shown.isEmpty {
        Section {
          Text("No matching actions")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
      }

      ForEach(ShortcutsPaneModel.menus(of: shown), id: \.self) { menu in
        SettingsSection(menu) {
          ForEach(shown.filter { $0.menu == menu }) { item in
            ShortcutRow(
              item: item,
              shortcut: resolved.effective(item.id),
              conflict: ShortcutsPaneModel.conflictText(model.conflicts(of: item, in: resolved)),
              overridden: model.customized(item, overrides: overrides, precedences: precedences),
              precedence: model.precedence(of: item, in: precedences),
              app: app,
              fileSource: model.store.fileSource(shortcut: item.id),
              model: model
            )
          }
        }
      }

      if model.filter == .all && model.query.isEmpty {
        SettingsSection("Extensions") {
          SettingRow("shortcuts.extensionShortcuts") {
            Button("Edit…") { model.services.openURLs([ShortcutsPaneModel.extensionShortcutsURL]) }
          }
        }
      }
    }
    .onDisappear { model.cancelRecording() }
  }
}

struct ShortcutRow: View {
  let item: MenuShortcutItem
  let shortcut: KeyShortcut
  let conflict: String?
  let overridden: Bool
  let precedence: ShortcutPrecedence?
  let app: String
  var fileSource: String? = nil
  let model: ShortcutsPaneModel

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        if overridden && fileSource == nil {
          Button {
            model.reset(item)
          } label: {
            Image(systemName: "arrow.uturn.backward")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .help("Reset to Default")
        }
        if let precedence, item.precedenceFixed {
          Text(precedence.title(app: app))
            .foregroundStyle(.tertiary)
            .help(ShortcutPrecedence.fixedHelp(app: app))
        } else if let precedence {
          SettingsPopUp(
            ShortcutPrecedence.allCases.map { SettingsPopUpItem($0, $0.title(app: app)) },
            selection: Binding(get: { precedence }, set: { model.setPrecedence(item, $0) })
          )
          .help(precedence.help(app: app))
        }
        ShortcutField(
          shortcut: shortcut,
          remappable: item.remappable && fileSource == nil,
          recording: model.recording == item.id,
          onRecord: { Task { await model.record(item) } },
          onClear: { model.clear(item) }
        )
      }
    } label: {
      Text(item.title)
      if let conflict {
        Text(conflict)
          .foregroundStyle(ShortcutsPaneModel.conflictColor)
      } else if let path = ShortcutsPaneModel.pathText(item) {
        Text(path)
      }
      if let fileSource {
        SettingsFileNote(source: fileSource)
      }
    }
    .contextMenu {
      Button("Copy Name for config.json") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.id, forType: .string)
      }
    }
  }
}

struct ShortcutField: View {
  let shortcut: KeyShortcut
  let remappable: Bool
  let recording: Bool
  let onRecord: () -> Void
  let onClear: () -> Void
  @State private var hovered = false

  static let minWidth: CGFloat = 110

  var text: String { recording ? "Type Shortcut" : shortcut.formatted }

  var body: some View {
    if remappable {
      recorder
    } else {
      Text(text.isEmpty ? "—" : text)
        .foregroundStyle(.tertiary)
        .frame(minWidth: Self.minWidth, alignment: .trailing)
        .help("(not remappable)")
    }
  }

  private var recorder: some View {
    HStack(spacing: 4) {
      Text(text.isEmpty ? "None" : text)
        .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor) : text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
      if hovered && !recording && !shortcut.key.isEmpty {
        Button(action: onClear) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help("Remove Shortcut")
      }
    }
    .padding(.horizontal, 8)
    .frame(minWidth: Self.minWidth, minHeight: 24, maxHeight: 24)
    .fixedSize()
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(recording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovered ? 0.1 : 0.05))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: recording ? 1.5 : 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onTapGesture(perform: onRecord)
    .onHover { hovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(text.isEmpty ? "None" : text)
    .accessibilityAction(named: "Remove Shortcut", onClear)
  }
}

struct ShortcutsSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search actions"
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if field.stringValue != text { field.stringValue = text }
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}
