import SwiftUI

public struct SearchEngineItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let keyword: String
  public let url: String
  public let host: String
  public let custom: Bool
  public let extensionName: String?

  public init(id: String, name: String, keyword: String, url: String, host: String, custom: Bool = false, extensionName: String? = nil) {
    self.id = id
    self.name = name
    self.keyword = keyword
    self.url = url
    self.host = host
    self.custom = custom
    self.extensionName = extensionName
  }

  public var fromExtension: Bool { extensionName != nil }
}

public struct ControllingSearchExtension: Hashable, Sendable {
  public let extensionId: String
  public let extensionName: String
  public let profile: String

  public init(extensionId: String, extensionName: String, profile: String) {
    self.extensionId = extensionId
    self.extensionName = extensionName
    self.profile = profile
  }
}

public struct SearchEngineList: Sendable {
  public let engines: [SearchEngineItem]
  public let selectedId: String
  public let controlling: ControllingSearchExtension?

  public init(engines: [SearchEngineItem], selectedId: String, controlling: ControllingSearchExtension?) {
    self.engines = engines
    self.selectedId = selectedId
    self.controlling = controlling
  }

  var builtIn: [SearchEngineItem] { engines.filter { !$0.custom && !$0.fromExtension } }
  var custom: [SearchEngineItem] { engines.filter(\.custom) }
  var fromExtensions: [SearchEngineItem] { engines.filter(\.fromExtension) }
}

public struct SearchEngineInput: Hashable, Sendable {
  public var name: String
  public var keyword: String
  public var url: String
}

@MainActor
public protocol SearchEngineServices: AnyObject {
  func engineList() -> SearchEngineList
  func setSearchEngine(_ id: String)
  func addCustomEngine(_ input: SearchEngineInput) async -> String?
  func updateCustomEngine(_ id: String, _ input: SearchEngineInput) async -> String?
  func removeCustomEngine(_ id: String)
  func manageExtensions(profile: String)
  func disableExtension(profile: String, extensionId: String) async
}

@MainActor
public final class SearchEnginePaneModel: SettingsPaneProvider {
  let services: SearchEngineServices
  let store: SettingsStoreSource

  public init(services: SearchEngineServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { true }
  public func prepare(_ place: SettingsPlace) async {}
  public func view(_ place: SettingsPlace) -> AnyView { AnyView(SearchEnginePane(model: self)) }

  static func description(_ engine: SearchEngineItem) -> String {
    if let name = engine.extensionName {
      return "\(engine.keyword.isEmpty ? "" : "\(engine.keyword) · ")Added by \(name.isEmpty ? "an extension" : name)"
    }
    return engine.custom ? "\(engine.keyword) · \(engine.url)" : engine.keyword
  }
}

enum EngineSheetTarget: Identifiable {
  case add
  case edit(SearchEngineItem)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let engine): engine.id
    }
  }
}

struct SearchEnginePane: View {
  @Environment(\.settingsContext) private var context
  let model: SearchEnginePaneModel
  @State private var sheet: EngineSheetTarget?

  var body: some View {
    let list = model.services.engineList()
    let locked = list.controlling != nil
    SettingsForm {
      SettingsSection(description: "Used by the command bar and the New Tab page.", anchor: "search.defaultEngine") {
        if let controlling = list.controlling {
          LabeledContent {
            HStack(spacing: 8) {
              Button("Manage") { model.services.manageExtensions(profile: controlling.profile) }
              Button("Disable") { Task { await model.services.disableExtension(profile: controlling.profile, extensionId: controlling.extensionId) } }
            }
          } label: {
            Label {
              Text("\(controlling.extensionName.isEmpty ? "An extension" : controlling.extensionName) is controlling this setting")
              Text("To change your default search engine, disable the extension or manage its settings.")
            } icon: {
              Image(systemName: "puzzlepiece.extension").foregroundStyle(Color.accentColor)
            }
          }
        }
        ForEach(list.builtIn) { engine in
          EngineRow(engine: engine, selected: list.selectedId == engine.id, locked: locked, editable: false, model: model) { sheet = .edit(engine) }
        }
      }

      SettingsSection(description: "Type a shortcut and press Tab in the command bar to search a site directly.", anchor: "search.otherEngines") {
        Button("Add…", systemImage: "plus") { sheet = .add }
      } content: {
        if list.custom.isEmpty {
          SettingRow(title: "No custom search engines", description: .text("Add one with a URL where %s stands for the search terms."))
        } else {
          ForEach(list.custom) { engine in
            EngineRow(engine: engine, selected: list.selectedId == engine.id, locked: locked, editable: engine.id != "custom", model: model) { sheet = .edit(engine) }
          }
        }
      }

      if !list.fromExtensions.isEmpty {
        SettingsSection("Extensions", description: "Some extensions can add search engines to \(context?.appName ?? "").") {
          ForEach(list.fromExtensions) { engine in
            EngineRow(engine: engine, selected: list.selectedId == engine.id, locked: locked, editable: false, model: model) {}
          }
        }
      }

      SettingsSection("Suggestions") {
        SettingToggle("search.suggestions", key: "searchSuggestions")
      }

      SettingsSection("Text selection") {
        SettingToggle("search.showSelectionSearch", key: "showSelectionSearch")
      }
    }
    .sheet(item: $sheet) { target in
      EngineSheet(model: model, engine: { if case .edit(let engine) = target { engine } else { nil } }()) { sheet = nil }
    }
  }
}

struct EngineRow: View {
  let engine: SearchEngineItem
  let selected: Bool
  let locked: Bool
  let editable: Bool
  let model: SearchEnginePaneModel
  let edit: () -> Void

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        if editable {
          Button(action: edit) { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("Edit")
        }
        if selected {
          HStack(spacing: 5) {
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.accentColor)
            Text("Default")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          .frame(minWidth: 92, alignment: .trailing)
        } else {
          Button("Make Default") { model.services.setSearchEngine(engine.id) }
            .disabled(locked)
            .frame(minWidth: 92, alignment: .trailing)
        }
      }
    } label: {
      Label {
        Text(engine.name)
        Text(SearchEnginePaneModel.description(engine))
      } icon: {
        SettingsFavicon(url: "https://\(engine.host)")
      }
    }
  }
}

struct EngineSheet: View {
  let model: SearchEnginePaneModel
  let engine: SearchEngineItem?
  let close: () -> Void
  @State private var name = ""
  @State private var keyword = ""
  @State private var url = ""
  @State private var error: String?

  init(model: SearchEnginePaneModel, engine: SearchEngineItem?, close: @escaping () -> Void) {
    self.model = model
    self.engine = engine
    self.close = close
    _name = State(initialValue: engine?.name ?? "")
    _keyword = State(initialValue: engine?.keyword ?? "")
    _url = State(initialValue: engine?.url ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(engine == nil ? "Add Search Engine" : "Edit Search Engine")
        .font(.system(size: 15, weight: .semibold))
      SheetField(label: "Name", text: $name, placeholder: "Wikipedia", submit: save)
      SheetField(label: "Shortcut", text: $keyword, placeholder: "w", submit: save)
      SheetField(label: "URL with %s in place of the query", text: $url, placeholder: "https://en.wikipedia.org/w/index.php?search=%s", contentType: .URL, submit: save)
      if let error {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .padding(.top, 10)
      }
      HStack(spacing: 8) {
        if let engine {
          Button("Delete", role: .destructive) {
            model.services.removeCustomEngine(engine.id)
            close()
          }
        }
        Spacer()
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
        Button(engine == nil ? "Add" : "Save", action: save)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: 440)
  }

  private func save() {
    let input = SearchEngineInput(name: name, keyword: keyword, url: url)
    Task {
      let result = if let engine { await model.services.updateCustomEngine(engine.id, input) } else { await model.services.addCustomEngine(input) }
      if let result {
        error = result
        return
      }
      close()
    }
  }
}

struct SheetField: View {
  let label: String
  @Binding var text: String
  let placeholder: String
  var contentType: NSTextContentType = .solaraPlainText
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      TextField("", text: $text, prompt: Text(placeholder))
        .textContentType(contentType)
        .textFieldStyle(.roundedBorder)
        .onSubmit(submit)
    }
    .padding(.top, 12)
  }
}
