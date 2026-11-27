import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
public final class DownloadsPageModel {
  public var downloads: [DownloadRowState] = []
  public var theme = PageTheme.fallbackLight
  public var query = ""
  public var focusRequest = 0
  @ObservationIgnored public var onEvent: (DownloadsEvent) -> Void = { _ in }
  @ObservationIgnored public var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

  public init() {}

  public var shown: [DownloadRowState] {
    downloads.filter { PageFormat.matches(query, $0.filename, $0.url ?? "") }
  }

  var clearable: Bool { downloads.contains { $0.state != "downloading" } }

  func exists(_ d: DownloadRowState) -> Bool { d.state != "finished" || fileExists(d.path) }
}

public struct DownloadsPageView: View {
  @Bindable var model: DownloadsPageModel

  public init(model: DownloadsPageModel) {
    self.model = model
  }

  public var body: some View {
    let shown = model.shown
    VStack(spacing: 0) {
      PageHeader(title: "Downloads", query: $model.query, placeholder: "Search downloads", focus: model.focusRequest) {
        if model.clearable { PageButton(title: "Clear All") { model.onEvent(.clear) } }
      }
      if shown.isEmpty {
        PageEmptyState(icon: "arrow.down.circle", title: model.query.isEmpty ? "Files you download appear here" : "No search results found")
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(shown) { d in
              DownloadCard(download: d, exists: model.exists(d), onEvent: model.onEvent)
                .frame(maxWidth: PageMetrics.width - 32)
            }
          }
          .padding(.top, 8)
          .padding(.bottom, 40)
          .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
      }
    }
    .environment(\.pageTheme, model.theme)
  }
}

struct DownloadCard: View {
  @Environment(\.pageTheme) private var theme
  let download: DownloadRowState
  let exists: Bool
  let onEvent: (DownloadsEvent) -> Void
  @State private var hovered = false

  var body: some View {
    let d = download
    let done = d.state == "finished" && exists
    let progress = d.total > 0 ? d.received / d.total : 0
    let blocked = DownloadsFormat.awaitsKeep(d)
    HStack(spacing: 14) {
      Image(nsImage: Self.icon(d.path.isEmpty ? d.filename : d.path))
        .resizable()
        .frame(width: 36, height: 36)
        .opacity(exists ? 1 : 0.45)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        OnboardingText(d.filename.isEmpty ? "Preparing…" : d.filename, size: 13.5, weight: 500, color: exists ? theme.textPrimary : theme.textSecondary, lines: 1, strike: !exists)
          .contentShape(Rectangle())
          .onTapGesture { if done { onEvent(.open(d.id)) } }
          .accessibilityAddTraits(done ? .isButton : [])
          .accessibilityAction { if done { onEvent(.open(d.id)) } }
        OnboardingText(PageFormat.hostLabel(d.url ?? ""), size: 12, color: theme.textTertiary, lines: 1)
          .contentShape(Rectangle())
          .onTapGesture { onEvent(.source(d.id)) }
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { onEvent(.source(d.id)) }
        if d.state == "downloading" && !blocked {
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule(style: .circular).fill(theme.rowHover)
              Capsule(style: .circular).fill(d.paused ? theme.textTertiary : theme.accentTheme)
                .frame(width: proxy.size.width * max(progress, 0.03))
            }
          }
          .frame(height: 3)
          .padding(.top, 3)
        }
        OnboardingText(DownloadsFormat.status(d, exists: exists), size: 12, color: blocked ? theme.destructive : theme.textSecondary, lines: 1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if blocked {
        HStack(spacing: 8) {
          PageButton(title: "Keep") { onEvent(.keep(d.id)) }
          PageButton(title: "Discard", kind: .destructive) { onEvent(.cancel(d.id)) }
        }
      } else if d.state == "downloading" {
        HStack(spacing: 8) {
          PageButton(title: d.paused ? "Resume" : "Pause") { onEvent(d.paused ? .resume(d.id) : .pause(d.id)) }
          PageButton(title: "Cancel") { onEvent(.cancel(d.id)) }
        }
      } else if done {
        PageButton(title: "Show in Finder") { onEvent(.reveal(d.id)) }
      }
      PageIconButton(icon: "ellipsis", size: 13, box: 26, radius: 6, tooltip: "More actions") { onEvent(.menu(d.id)) }
      if d.state != "downloading" {
        PageIconButton(icon: "xmark", size: 11, box: 26, radius: 6, tooltip: "Remove from List") { onEvent(.remove(d.id)) }
          .pageProbe("remove:\(d.id)")
      }
    }
    .padding(15)
    .background(RoundedRectangle(cornerRadius: 12, style: .circular).fill(hovered ? theme.rowHover : theme.group))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(theme.groupBorder, lineWidth: 1))
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onDrag {
      guard done else { return NSItemProvider() }
      return NSItemProvider(contentsOf: URL(fileURLWithPath: d.path)) ?? NSItemProvider()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(d.filename)
  }

  static func icon(_ path: String) -> NSImage {
    let image = NSWorkspace.shared.icon(forFile: path)
    if FileManager.default.fileExists(atPath: path) { return image }
    let ext = (path as NSString).pathExtension
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext.isEmpty ? "bin" : ext) ?? .data)
  }
}
