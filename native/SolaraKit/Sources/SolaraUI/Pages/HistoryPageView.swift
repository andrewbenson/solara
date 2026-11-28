import AppKit
import Observation
import SolaraEngine
import SolaraOmnibox
import SwiftUI

public struct PageHistoryEntry: Decodable, Equatable, Sendable, Identifiable {
  public var url: String
  public var title: String
  public var favicon: String?
  public var lastVisit: Double
  public var id: String { url }
}

public enum PageOpenMode: String, Sendable {
  case current, background, foreground, window, split, incognito
}

public enum HistoryPageEvent: Equatable, Sendable {
  case open(String, PageOpenMode)
  case remove([String])
  case deleteSelected([String])
  case clearData(ClearDataRequest)
}

struct HistoryLayout: Equatable {
  struct Day: Equatable {
    var label: String
    var rows: [Row]
  }

  struct Row: Equatable, Identifiable {
    var entry: PageHistoryEntry
    var first: Bool
    var last: Bool
    var id: String { entry.url }
  }

  var days: [Day] = []
  var rows: [PageHistoryEntry] = []

  init() {}

  init(entries: [PageHistoryEntry], query: String, texts: (PageHistoryEntry) -> String, now: Double = Date().timeIntervalSince1970 * 1000) {
    let words = PageFormat.queryWords(query)
    var from = Double.infinity
    var to = -Double.infinity
    for entry in entries {
      if !words.isEmpty {
        let text = texts(entry)
        if !words.allSatisfy({ text.contains($0) }) { continue }
      }
      if entry.lastVisit < from || entry.lastVisit >= to {
        from = PageFormat.dayStart(entry.lastVisit)
        to = PageFormat.nextDay(from)
        days.append(Day(label: PageFormat.dayLabel(from, now: now), rows: []))
      }
      let index = days.count - 1
      days[index].rows.append(Row(entry: entry, first: days[index].rows.isEmpty, last: false))
      rows.append(entry)
    }
    for i in days.indices where !days[i].rows.isEmpty { days[i].rows[days[i].rows.count - 1].last = true }
  }
}

@MainActor
@Observable
public final class HistoryPageModel {
  public var entries: [PageHistoryEntry] = [] { didSet { relayout() } }
  public var query = "" { didSet { if query != oldValue { relayout() } } }
  public var theme = PageTheme.fallbackLight
  public var profileId = ""
  public private(set) var engineProfile = ""
  public var profileName: String?
  public var selected: Set<String> = []
  public var clearOpen = false
  public var clearBusy = false
  public var focusRequest = 0
  public var devHover: String?
  private(set) var layout = HistoryLayout()
  @ObservationIgnored var lastClicked: String?
  @ObservationIgnored public var onEvent: (HistoryPageEvent) -> Void = { _ in }
  @ObservationIgnored private var searchTexts: [String: String] = [:]
  @ObservationIgnored private var initialQuery: String?
  @ObservationIgnored private let catalog: LibraryCatalog?
  @ObservationIgnored private var historyObserver: Task<Void, Never>?

  public init(catalog: LibraryCatalog? = nil) { self.catalog = catalog }

  deinit { historyObserver?.cancel() }

  public var shown: [String] { layout.rows.map(\.url) }

  private func relayout() {
    let next = HistoryLayout(entries: entries, query: query) { [self] entry in
      if let text = searchTexts[entry.url + "\u{1}" + entry.title] { return text }
      let text = PageFormat.searchText(entry.title, entry.url)
      searchTexts[entry.url + "\u{1}" + entry.title] = text
      return text
    }
    if next != layout { layout = next }
  }

  func toggle(_ url: String, shift: Bool) {
    let rows = layout.rows
    if shift, let lastClicked, let from = rows.firstIndex(where: { $0.url == lastClicked }), let to = rows.firstIndex(where: { $0.url == url }) {
      for i in min(from, to)...max(from, to) { selected.insert(rows[i].url) }
    } else if selected.contains(url) {
      selected.remove(url)
    } else {
      selected.insert(url)
    }
    lastClicked = url
  }

  func open(_ url: String, modifiers: NSEvent.ModifierFlags, middle: Bool = false) {
    let mode: PageOpenMode =
      if modifiers.contains(.command) || middle { modifiers.contains(.shift) ? .foreground : .background }
      else if modifiers.contains(.option) { .split }
      else if modifiers.contains(.shift) { .window }
      else { .current }
    onEvent(.open(url, mode))
  }

  func menu(for entry: PageHistoryEntry, in view: NSView?, at point: NSPoint?) {
    let menu = NSMenu()
    let target = PageMenuTarget()
    func item(_ title: String, _ run: @escaping () -> Void) {
      let made = NSMenuItem(title: title, action: #selector(PageMenuTarget.run(_:)), keyEquivalent: "")
      made.target = target
      made.representedObject = PageMenuAction(run)
      menu.addItem(made)
    }
    let url = entry.url
    item("Open in New Tab") { [weak self] in self?.onEvent(.open(url, .foreground)) }
    item("Open in New Window") { [weak self] in self?.onEvent(.open(url, .window)) }
    item("Open in Incognito Window") { [weak self] in self?.onEvent(.open(url, .incognito)) }
    menu.addItem(.separator())
    item("Copy Link") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(cleanUrl(url), forType: .string)
    }
    item("More from This Site") { [weak self] in self?.query = PageFormat.hostLabel(url) }
    menu.addItem(.separator())
    item("Remove from History") { [weak self] in self?.onEvent(.remove([url])) }
    objc_setAssociatedObject(menu, &PageMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    PageMenuTarget.show(menu, in: view, at: point)
  }

  public func apply(snapshot: HistorySnapshot) {
    let next = snapshot.ready ? snapshot.entries.map { entry in
      PageHistoryEntry(url: entry.url, title: entry.title, favicon: nil, lastVisit: entry.lastVisit)
    } : []
    if entries != next { entries = next }
    let urls = Set(next.map(\.url))
    if !selected.isSubset(of: urls) { selected.formIntersection(urls) }
  }

  private func observeHistory() {
    historyObserver?.cancel()
    guard let catalog else { return }
    let profile = engineProfile
    apply(snapshot: catalog.history(engineProfile: profile))
    historyObserver = Task { [weak self] in
      for await snapshot in catalog.observe(engineProfile: profile) {
        guard !Task.isCancelled, self?.engineProfile == profile else { return }
        self?.apply(snapshot: snapshot)
      }
    }
  }

  public func leaveScope() {
    historyObserver?.cancel()
    historyObserver = nil
  }

  public func setScope(profileId: String, engineProfile: String, profileName: String?, query: String, theme: PageTheme) {
    if self.theme != theme { self.theme = theme }
    if self.profileName != profileName { self.profileName = profileName }
    let changedProfile = self.profileId != profileId
    if changedProfile {
      self.profileId = profileId
      selected = []
      lastClicked = nil
      clearOpen = false
      clearBusy = false
    }
    if changedProfile || self.engineProfile != engineProfile {
      self.engineProfile = engineProfile
      entries = []
      observeHistory()
    }
    if changedProfile || initialQuery != query {
      initialQuery = query
      self.query = query
    }
  }
}

final class PageMenuAction: NSObject {
  let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
}

final class PageMenuTarget: NSObject {
  nonisolated(unsafe) static var key = 0

  @objc func run(_ item: NSMenuItem) { (item.representedObject as? PageMenuAction)?.run() }

  @MainActor
  static func show(_ menu: NSMenu, in view: NSView?, at point: NSPoint?) {
    let event = NSApp.currentEvent
    guard let host = view ?? event?.window?.contentView else { return }
    let location = point ?? host.convert(event?.locationInWindow ?? .zero, from: nil)
    menu.popUp(positioning: nil, at: location, in: host)
  }
}

public struct HistoryPageView: View {
  @Bindable var model: HistoryPageModel
  let favicons: PageFavicons?

  public init(model: HistoryPageModel, favicons: PageFavicons?) {
    self.model = model
    self.favicons = favicons
  }

  public var body: some View {
    let layout = model.layout
    let selecting = !model.selected.isEmpty
    ZStack {
      VStack(spacing: 0) {
        PageHeader(title: "History", query: $model.query, placeholder: "Search history", focus: model.focusRequest) {
          if selecting {
            OnboardingText("\(model.selected.count) selected", size: 12, color: model.theme.textSecondary, lines: 1).fixedSize()
            PageButton(title: "Cancel") { model.selected = [] }
            PageButton(title: "Delete", kind: .primary) { model.onEvent(.deleteSelected(Array(model.selected))) }
          } else {
            PageButton(title: "Clear Browsing Data…") { model.clearOpen = true }
          }
        }
        if layout.rows.isEmpty {
          PageEmptyState(icon: "clock", title: model.query.isEmpty ? "Your browsing history appears here" : "No search results found")
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(layout.days.enumerated()), id: \.offset) { _, day in
                HistoryDayHeader(label: day.label)
                ForEach(day.rows) { row in
                  HistoryRowView(row: row, selected: model.selected.contains(row.entry.url), selecting: selecting, model: model)
                }
              }
            }
            .frame(maxWidth: PageMetrics.width)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
          }
          .scrollContentBackground(.hidden)
        }
      }
      if model.clearOpen {
        ClearDataDialogView(profileName: model.profileName, busy: model.clearBusy, onClose: { model.clearOpen = false }) { request in
          model.clearBusy = true
          model.onEvent(.clearData(request))
        }
      }
    }
    .environment(\.pageTheme, model.theme)
    .environment(\.pageFavicons, favicons)
  }
}

struct HistoryDayHeader: View {
  @Environment(\.pageTheme) private var theme
  let label: String

  var body: some View {
    OnboardingText(label, size: 12.5, weight: 600, color: theme.textSecondary, lines: 1)
      .offset(y: -0.5)
      .padding(.horizontal, 30)
      .padding(.bottom, 8)
      .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .bottomLeading)
      .accessibilityAddTraits(.isHeader)
  }
}

struct HistoryRowView: View {
  @Environment(\.pageTheme) private var theme
  let row: HistoryLayout.Row
  let selected: Bool
  let selecting: Bool
  let model: HistoryPageModel
  @State private var hovered = false

  var body: some View {
    let entry = row.entry
    let lit = hovered || model.devHover == entry.url
    let radius: CGFloat = 10
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: row.first ? radius : 0, bottomLeadingRadius: row.last ? radius : 0,
      bottomTrailingRadius: row.last ? radius : 0, topTrailingRadius: row.first ? radius : 0, style: .circular)
    HStack(spacing: 12) {
      ZStack(alignment: .trailing) {
        if lit || selecting {
          PageCheckbox(on: selected, label: nil) { model.toggle(entry.url, shift: false) }
        }
      }
      .frame(width: 14)
      OnboardingText(PageFormat.timeLabel(entry.lastVisit), size: 12, color: theme.textSecondary, lines: 1)
        .offset(y: -0.5)
        .frame(width: 64, alignment: .leading)
      HStack(spacing: 10) {
        PageFavicon(url: entry.url, favicon: entry.favicon, profileId: model.profileId)
        HStack(spacing: 9.5) {
          OnboardingText(entry.title.isEmpty ? entry.url : entry.title, size: 13, color: theme.textPrimary, lines: 1)
          OnboardingText(PageFormat.hostLabel(entry.url), size: 12, color: theme.textTertiary, lines: 1)
            .frame(maxWidth: 220, alignment: .leading)
            .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .gesture(TapGesture().modifiers(.shift).onEnded { click(shift: true, flags: [.shift]) })
      .onTapGesture { click(shift: false, flags: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)) }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isLink)
      .accessibilityAction(named: selected ? "Deselect" : "Select") { model.toggle(entry.url, shift: false) }
      .accessibilityAction(named: "More Actions") { model.menu(for: entry, in: nil, at: nil) }
      ZStack {
        if lit {
          PageIconButton(icon: "ellipsis", size: 13, box: 26, radius: 6, tooltip: "More actions") { model.menu(for: entry, in: nil, at: nil) }
        }
      }
      .frame(width: 26)
    }
    .padding(.horizontal, 12)
    .frame(maxHeight: .infinity)
    .background(shape.fill(selected ? theme.selected : lit ? theme.rowHover : theme.group))
    .overlay(alignment: .bottom) {
      if !row.last { Rectangle().fill(theme.separator).frame(height: 1).padding(.horizontal, 12) }
    }
    .padding(.horizontal, 16)
    .frame(height: 38)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu { HistoryRowMenu(entry: entry, model: model) }
    .pageProbe("row:\(entry.url)")
  }

  private func click(shift: Bool, flags: NSEvent.ModifierFlags) {
    if selecting { return model.toggle(row.entry.url, shift: shift) }
    model.open(row.entry.url, modifiers: flags)
  }
}

struct HistoryRowMenu: View {
  let entry: PageHistoryEntry
  let model: HistoryPageModel

  var body: some View {
    Button("Open in New Tab") { model.onEvent(.open(entry.url, .foreground)) }
    Button("Open in New Window") { model.onEvent(.open(entry.url, .window)) }
    Button("Open in Incognito Window") { model.onEvent(.open(entry.url, .incognito)) }
    Divider()
    Button("Copy Link") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(cleanUrl(entry.url), forType: .string)
    }
    Button("More from This Site") { model.query = PageFormat.hostLabel(entry.url) }
    Divider()
    Button("Remove from History") { model.onEvent(.remove([entry.url])) }
  }
}
