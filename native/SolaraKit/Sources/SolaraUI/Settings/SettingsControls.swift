import SwiftUI

public struct SettingsForm<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    SettingsLazyForm(content: content)
  }
}

public struct SettingsSection<Content: View, Action: View>: View {
  @Environment(\.settingsContext) private var context
  let title: String?
  let description: String?
  let anchor: String?
  let action: Action
  let content: Content

  public init(_ title: String? = nil, description: String? = nil, anchor: String? = nil, @ViewBuilder action: () -> Action, @ViewBuilder content: () -> Content) {
    self.title = title
    self.description = description
    self.anchor = anchor
    self.action = action()
    self.content = content()
  }

  public var body: some View {
    Section {
      content
        .disabled(context?.store.fileSource(keys: SettingsFileKeys.keys(anchor: anchor)) != nil)
    } header: {
      SettingsSectionHeader(title, description: description, anchor: anchor) { action }
    }
  }
}

public struct SettingsSectionHeader<Action: View>: View {
  @Environment(\.settingsContext) private var context
  let title: String?
  let description: String?
  let anchor: String?
  let action: Action

  public init(_ title: String? = nil, description: String? = nil, anchor: String? = nil, @ViewBuilder action: () -> Action) {
    self.title = title
    self.description = description
    self.anchor = anchor
    self.action = action()
  }

  public var body: some View {
    SettingsAnchor(anchor) {
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 3) {
          Text(resolvedTitle)
          if let description {
            Text(description)
              .font(.callout)
              .fontWeight(.regular)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let fileSource = context?.store.fileSource(keys: SettingsFileKeys.keys(anchor: anchor)) {
            SettingsFileNote(source: fileSource)
              .font(.callout)
              .fontWeight(.regular)
          }
        }
        Spacer(minLength: 8)
        action
      }
    }
  }

  private var resolvedTitle: String {
    if let title { return title }
    if let anchor, let entry = context?.index.entry(anchor) { return entry.section }
    return ""
  }
}

public extension SettingsSectionHeader where Action == EmptyView {
  init(_ title: String? = nil, description: String? = nil, anchor: String? = nil) {
    self.init(title, description: description, anchor: anchor) { EmptyView() }
  }
}

public extension SettingsSection where Action == EmptyView {
  init(_ title: String? = nil, description: String? = nil, anchor: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title, description: description, anchor: anchor, action: { EmptyView() }, content: content)
  }
}

public enum RowDescription {
  case index
  case none
  case text(String)
}

public struct SettingRow<Control: View>: View {
  @Environment(\.settingsContext) private var context
  let anchor: String?
  let title: String?
  let description: RowDescription
  let keys: [String]
  let control: Control

  public init(_ anchor: String? = nil, title: String? = nil, description: RowDescription = .index, keys: [String] = [], @ViewBuilder control: () -> Control) {
    self.anchor = anchor
    self.title = title
    self.description = description
    self.keys = keys
    self.control = control()
  }

  public var body: some View {
    let fileSource = context?.store.fileSource(keys: keys + SettingsFileKeys.keys(anchor: anchor))
    SettingsAnchor(anchor) {
      LabeledContent {
        control
          .disabled(fileSource != nil)
      } label: {
        Text(resolvedTitle)
        if let text = resolvedDescription {
          Text(text)
        }
        if let fileSource {
          SettingsFileNote(source: fileSource)
        }
      }
    }
  }

  private var entry: SettingEntry? { anchor.flatMap { context?.index.entry($0) } }

  private var resolvedTitle: String { title ?? entry?.title ?? "" }

  private var resolvedDescription: String? {
    switch description {
    case .index: entry?.displayCaption
    case .none: nil
    case .text(let text): text
    }
  }
}

public extension SettingRow where Control == EmptyView {
  init(_ anchor: String? = nil, title: String? = nil, description: RowDescription = .index) {
    self.init(anchor, title: title, description: description) { EmptyView() }
  }
}

public extension SettingRow {
  init(_ anchor: String? = nil, title: String? = nil, description: String?, @ViewBuilder control: () -> Control) {
    self.init(anchor, title: title, description: description.map(RowDescription.text) ?? .index, control: control)
  }
}

public struct SettingToggle: View {
  @Environment(\.settingsContext) private var context
  let anchor: String
  let key: String
  let inverted: Bool

  public init(_ anchor: String, key: String, inverted: Bool = false) {
    self.anchor = anchor
    self.key = key
    self.inverted = inverted
  }

  public var body: some View {
    SettingRow(anchor, keys: [key]) {
      if let store = context?.store {
        Toggle("", isOn: Binding(get: { store.bool(key) != inverted }, set: { store.set(key, $0 != inverted) }))
          .labelsHidden()
          .toggleStyle(.settingsSwitch)
      }
    }
  }
}

public struct SettingOption: Hashable, Sendable {
  public let value: String
  public let title: String
  public let separatorBefore: Bool

  public init(_ value: String, _ title: String, separatorBefore: Bool = false) {
    self.value = value
    self.title = title
    self.separatorBefore = separatorBefore
  }
}

public struct SettingPicker: View {
  let options: [SettingOption]
  @Binding var selection: String

  public init(_ options: [SettingOption], selection: Binding<String>) {
    self.options = options
    _selection = selection
  }

  @Environment(\.settingsFormHeader) private var inHeader

  public var body: some View {
    if inHeader {
      Picker("", selection: $selection) {
        ForEach(options, id: \.value) { option in
          if option.separatorBefore { Divider() }
          Text(option.title).tag(option.value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
    } else {
      SettingsPopUp(options, selection: $selection)
    }
  }
}

public struct SettingsAnchor<Content: View>: View {
  let id: String?
  let content: Content

  static var flashIn: Duration { .milliseconds(120) }
  static var flashHold: Duration { .milliseconds(900) }
  static var flashOut: Duration { .milliseconds(700) }

  public init(_ id: String?, @ViewBuilder content: () -> Content) {
    self.id = id
    self.content = content()
  }

  public var body: some View {
    if let id {
      content
        .background { SettingsAnchorMark(id: id) }
        .id(id)
    } else {
      content
    }
  }
}

struct SettingsAnchorMark: View {
  @Environment(\.settingsContext) private var context
  @State private var glow = 0.0
  let id: String

  var body: some View {
    let revealing = context?.search.reveal == id
    let serial = flashSerial
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.accentColor.opacity(0.2))
      .padding(-4)
      .opacity(glow)
      .allowsHitTesting(false)
      .background {
        if revealing || serial != nil {
          Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            context?.anchorFrames[id] = frame
          }
        }
      }
      .task(id: serial) {
        guard serial != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { glow = 1 }
        try? await Task.sleep(for: SettingsAnchor<EmptyView>.flashIn + SettingsAnchor<EmptyView>.flashHold)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.7)) { glow = 0 }
      }
  }

  private var flashSerial: Int? {
    guard let flash = context?.search.flash, flash.id == id else { return nil }
    return flash.serial
  }
}
