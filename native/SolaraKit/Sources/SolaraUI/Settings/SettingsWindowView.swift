import AppKit
import SwiftUI

public struct SettingsWindowView: View {
  static let sidebarWidth: CGFloat = 214
  static let revealMargin: CGFloat = 16

  let context: SettingsContext

  public init(context: SettingsContext) {
    self.context = context
  }

  public var body: some View {
    NavigationSplitView {
      SettingsSidebar(context: context)
        .frame(width: Self.sidebarWidth)
        .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth)
    } detail: {
      SettingsDetail(context: context)
    }
    .toolbar(removing: .sidebarToggle)
    .background(WindowChromeTrimmer())
    .environment(\.settingsContext, context)
    .onAppear { context.syncShown() }
    .onChange(of: context.navigation.place) { _, place in
      context.syncShown()
    }
    .onChange(of: context.navigation.pane, initial: true) { _, pane in
      context.onPaneChange(pane)
    }
  }
}

struct SettingsSidebar: View {
  @Bindable var search: SettingsSearchModel
  let context: SettingsContext

  init(context: SettingsContext) {
    self.context = context
    search = context.search
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsSearchField(
        text: $search.query,
        focusRequest: search.focusRequest,
        onSubmit: { context.submitSearch() },
        onArrow: { search.moveSelection($0) }
      )
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
      if search.isSearching {
        SettingsSearchResults(context: context)
      } else {
        SettingsPaneList(context: context)
      }
    }
  }
}

struct SettingsPaneList: View {
  static let rowHeight: CGFloat = 30
  static let highlightHeight: CGFloat = 28
  static let groupSpacing: CGFloat = 12

  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool
  let context: SettingsContext

  var body: some View {
    let selected = context.navigation.pane
    ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(Array(SettingsPane.sidebarGroups.enumerated()), id: \.offset) { index, group in
          if index > 0 { Color.clear.frame(height: Self.groupSpacing) }
          ForEach(group) { pane in
            SettingsPaneRow(pane: pane, selected: pane == selected, scheme: scheme)
              .onTapGesture { context.goToPane(pane) }
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .scrollIndicators(.automatic)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.downArrow) { step(1) }
    .onKeyPress(.upArrow) { step(-1) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings")
  }

  private func step(_ offset: Int) -> SwiftUI.KeyPress.Result {
    let panes = SettingsPane.sidebarOrder
    guard let index = panes.firstIndex(of: context.navigation.pane) else { return .ignored }
    let next = min(max(index + offset, 0), panes.count - 1)
    if next != index { context.goToPane(panes[next]) }
    return .handled
  }
}

struct SettingsPaneRow: View {
  @Environment(\.controlActiveState) private var activeState
  let pane: SettingsPane
  let selected: Bool
  let scheme: ColorScheme

  var body: some View {
    let emphasized = selected && activeState == .key
    HStack(spacing: 8) {
      SettingsPaneTile(pane: pane, scheme: scheme)
      Text(pane.title)
        .font(.system(size: 13))
        .foregroundStyle(emphasized ? Color.white : scheme == .dark ? Color.white : Color.black)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.leading, 6)
    .frame(height: SettingsPaneList.highlightHeight)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(emphasized ? Color.accentColor : scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
      }
    }
    .frame(height: SettingsPaneList.rowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pane.title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

struct SettingsSearchResults: View {
  let context: SettingsContext

  var body: some View {
    let search = context.search
    let results = search.results
    if results.isEmpty {
      VStack(spacing: 4) {
        Text("No Results")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Text("Nothing matches “\(search.query.trimmingCharacters(in: .whitespaces))”.")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .padding(.top, 40)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    } else {
      ScrollViewReader { proxy in
        List {
          ForEach(groups(results), id: \.pane) { group in
            Section {
              ForEach(group.rows, id: \.offset) { row in
                ResultRow(entry: row.entry, selected: row.offset == search.selected)
                  .id(row.offset)
                  .contentShape(Rectangle())
                  .onTapGesture { context.reveal(row.entry.id) }
                  .onHover { if $0 { search.selected = row.offset } }
              }
            } header: {
              Label(group.pane.title, systemImage: group.pane.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
          }
        }
        .listStyle(.sidebar)
        .onChange(of: search.selected) { _, selected in
          proxy.scrollTo(selected)
        }
      }
    }
  }

  private func groups(_ results: [SettingEntry]) -> [(pane: SettingsPane, rows: [(offset: Int, entry: SettingEntry)])] {
    var out: [(pane: SettingsPane, rows: [(offset: Int, entry: SettingEntry)])] = []
    for (offset, entry) in results.enumerated() {
      if out.last?.pane == entry.pane {
        out[out.count - 1].rows.append((offset, entry))
      } else {
        out.append((entry.pane, [(offset, entry)]))
      }
    }
    return out
  }
}

struct ResultRow: View {
  let entry: SettingEntry
  let selected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(entry.title)
        .font(.system(size: 13))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .lineLimit(1)
      Text(entry.section != entry.title ? entry.section : entry.paneTitle)
        .font(.system(size: 11))
        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .padding(.horizontal, 6)
    .background(selected ? RoundedRectangle(cornerRadius: 7).fill(Color.accentColor) : nil)
  }
}

struct SettingsDetail: View {
  let context: SettingsContext
  @State private var lastKey: SettingsPlace?

  var body: some View {
    let navigation = context.navigation
    ScrollViewReader { proxy in
      Group {
        if let shown = context.shown {
          paneView(shown)
            .onAppear { context.onPaneAppear(shown) }
            .id(shown)
        } else {
          Color.clear
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .safeAreaInset(edge: .top, spacing: 0) { ConfigProblemsBanner(model: ConfigProblemsModel.shared) }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { context.viewport = $0 }
      .onChange(of: RevealKey(reveal: context.search.reveal, shown: context.shown), initial: true) { _, key in
        reveal(key, proxy: proxy)
      }
      .onChange(of: context.shown) { _, shown in
        DispatchQueue.main.async { lastKey = shown }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button { navigation.goBack() } label: { Image(systemName: "chevron.left") }
          .disabled(!navigation.canGoBack)
          .help("Back")
        Button { navigation.goForward() } label: { Image(systemName: "chevron.right") }
          .disabled(!navigation.canGoForward)
          .help("Forward")
      }
    }
    .navigationTitle(context.shown.map(context.title(for:)) ?? "")
  }

  @ViewBuilder
  private func paneView(_ place: SettingsPlace) -> some View {
    if let provider = context.panes[place.pane] {
      provider.view(place)
    } else {
      Text(place.pane.title)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private struct RevealKey: Equatable {
    let reveal: String?
    let shown: SettingsPlace?
  }

  private func reveal(_ key: RevealKey, proxy: ScrollViewProxy) {
    guard let id = key.reveal, let entry = context.index.entry(id) else { return }
    if context.navigation.pane != entry.pane {
      context.search.clearReveal()
      return
    }
    guard key.shown?.pane == entry.pane else { return }
    let animated = lastKey == key.shown
    DispatchQueue.main.async {
      let frame = context.anchorFrames[id] ?? .null
      let viewport = context.viewport
      let margin = SettingsWindowView.revealMargin
      let inView = animated && !frame.isNull && frame.minY >= viewport.minY + margin && frame.maxY <= viewport.maxY - margin
      if !inView {
        let target = UnitPoint(x: 0.5, y: 1.0 / 3.0)
        if animated {
          withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: target) }
        } else {
          proxy.scrollTo(id, anchor: target)
        }
      }
      context.search.flashSetting(id)
    }
  }
}

struct WindowChromeTrimmer: NSViewRepresentable {
  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      trim()
      DispatchQueue.main.async { [weak self] in
        self?.trim()
        if self?.window?.firstResponder is NSText { self?.window?.makeFirstResponder(nil) }
      }
    }

    func trim() {
      guard let toolbar = window?.toolbar else { return }
      for (index, item) in toolbar.items.enumerated().reversed() where item.itemIdentifier == .toggleSidebar || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar") || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebarToggle") {
        toolbar.removeItem(at: index)
      }
    }
  }

  func makeNSView(context: Context) -> Probe { Probe() }

  func updateNSView(_ view: Probe, context: Context) {
    DispatchQueue.main.async { view.trim() }
  }
}

struct SettingsPaneTile: View {
  static let size: CGFloat = 20
  static let radius: CGFloat = 5

  let pane: SettingsPane
  let scheme: ColorScheme

  var body: some View {
    Image(systemName: pane.tileSymbol)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: Self.size, height: Self.size)
      .background {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
          .fill(fill.gradient)
          .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
              .strokeBorder(Color.white.opacity(scheme == .dark && pane.tileColor == .black ? 0.18 : 0), lineWidth: 0.5)
          }
      }
  }

  private var fill: Color {
    switch pane.tileColor {
    case .gray: Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    case .blue: Color(red: 0, green: 122 / 255, blue: 1)
    case .cyan: Color(red: 50 / 255, green: 173 / 255, blue: 230 / 255)
    case .indigo: Color(red: 88 / 255, green: 86 / 255, blue: 214 / 255)
    case .black: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    case .green: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    case .orange: Color(red: 1, green: 149 / 255, blue: 0)
    case .red: Color(red: 1, green: 59 / 255, blue: 48 / 255)
    }
  }
}
