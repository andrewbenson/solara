import AppKit
import SolaraLive
import SwiftUI

public struct SidebarLiveCardState: Decodable, Equatable, Sendable {
  public struct Look: Decodable, Equatable, Sendable {
    public var dark: Bool
    public var panel: String
    public var panelBorder: String
    public var shadowOpacity: Double
    public var textPrimary: String
    public var textSecondary: String
    public var divider: String
    public var rowHover: String
    public var accent: String
    public var toolbarHover: String
    public var toolbarPressed: String
    public var urlPill: String
    public var success: String
    public var failure: String
    public var pending: String
    public var draft: String
    public var conflict: String
    public var ciTrack: String
  }

  public struct Line: Decodable, Equatable, Sendable {
    public var symbol: String
    public var tone: String
    public var text: String
  }

  public struct Check: Decodable, Equatable, Sendable {
    public var name: String
    public var url: String?
  }

  public struct PullRequest: Decodable, Equatable, Sendable {
    public var author: String
    public var avatar: String?
    public var place: String
    public var draft: Bool
    public var success: Int
    public var pending: Int
    public var failure: Int
    public var summary: Line?
    public var failing: [Check]
    public var conflicting: Bool
    public var review: Line?
    public var comments: String
    public var additions: Int
    public var deletions: Int
    public var files: String?
  }

  public struct Document: Decodable, Equatable, Sendable {
    public var icon: String?
    public var direct: Bool
    public var meta: String
    public var edited: String?
  }

  public var id: String
  public var url: String
  public var title: String
  public var width: Double
  public var anchor: [Double]
  public var profileId: String
  public var look: Look
  public var pr: PullRequest?
  public var doc: Document?

  public var anchorRect: CGRect {
    anchor.count == 4 ? CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3]) : .zero
  }

  public static func decode(_ value: Any?) -> SidebarLiveCardState? {
    guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(SidebarLiveCardState.self, from: data)
  }
}

extension SidebarLiveCardState {
  public static func itemKey(_ hoverId: String) -> (folderId: String, itemId: String) {
    let parts = hoverId.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    return (parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
  }

  public init(id: String, item: LiveItem, anchor: [Double], look: Look, now: Double) {
    self.id = id
    url = item.url
    title = item.title
    width = item.pr == nil ? 280 : 300
    self.anchor = anchor
    profileId = ""
    self.look = look
    pr = item.pr.map { Self.pullRequest($0, section: item.section) }
    doc = item.pr == nil ? Self.document(item, now: now) : nil
  }

  static func reviewLine(_ review: ReviewDecision?, section: PullRequestSection?) -> Line? {
    switch review {
    case nil: nil
    case .approved: Line(symbol: "checkmark.seal.fill", tone: "success", text: "Approved")
    case .changesRequested: Line(symbol: "arrow.uturn.backward.circle.fill", tone: "failure", text: "Changes Requested")
    case .required: Line(symbol: "eye", tone: "secondary", text: section == .authored ? "Review required" : "Needs your review")
    }
  }

  static func pullRequest(_ pr: PullRequestInfo, section: PullRequestSection?) -> PullRequest {
    let summary = GitHub.summarizeChecks(pr.checks).map { summary in
      let symbol = switch summary.tone {
      case .success: "checkmark.circle.fill"
      case .failure: "xmark.circle.fill"
      default: "clock.fill"
      }
      return Line(symbol: symbol, tone: summary.tone.rawValue, text: summary.text)
    }
    let failing = pr.checks.filter { $0.state == .failure }
    let comments = (pr.comments == 1 ? "1 comment" : "\(pr.comments) comments") + (pr.unresolvedThreads > 0 ? " · \(pr.unresolvedThreads) unresolved" : "")
    return PullRequest(
      author: pr.author, avatar: pr.authorAvatar, place: "\(pr.repo) #\(pr.number)", draft: pr.draft,
      success: pr.checks.filter { $0.state == .success || $0.state == .neutral }.count,
      pending: pr.checks.filter { $0.state == .pending || $0.state == .queued }.count,
      failure: failing.count, summary: summary, failing: failing.map { Check(name: $0.name, url: $0.url) },
      conflicting: pr.mergeable == .conflicting, review: reviewLine(pr.review, section: section), comments: comments,
      additions: pr.additions, deletions: pr.deletions,
      files: pr.changedFiles > 0 ? "\(pr.changedFiles) \(pr.changedFiles == 1 ? "file" : "files")" : nil)
  }

  static func document(_ item: LiveItem, now: Double) -> Document {
    let direct = item.icon.map { $0.hasPrefix("http:") || $0.hasPrefix("https:") } ?? false
    let place = item.doc?.place ?? item.subtitle
    let meta = [item.doc?.kind, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    let edited = item.updatedAt > 0 ? "Edited \(Meetings.ago(item.updatedAt, now: now))" + (item.doc?.editedBy.flatMap { $0.isEmpty ? nil : " by \($0)" } ?? "") : nil
    return Document(icon: item.icon, direct: direct, meta: meta, edited: edited)
  }
}

public enum SidebarLiveCardEvent: Equatable, Sendable {
  case openItem
  case open(String)
}

@MainActor
@Observable
final class SidebarLiveCardModel {
  var state: SidebarLiveCardState?
  var showAll = false
  @ObservationIgnored var onEvent: (SidebarLiveCardEvent) -> Void = { _ in }
  @ObservationIgnored var onHeight: (CGFloat) -> Void = { _ in }
  @ObservationIgnored weak var favicons: SidebarFavicons?
}

public final class SidebarLiveCardView: NSView {
  public var onEvent: ((SidebarLiveCardEvent) -> Void)?
  public var onPointer: ((Bool) -> Void)?
  public var onResize: (() -> Void)?
  public var state: SidebarLiveCardState? { model.state }
  private let model = SidebarLiveCardModel()
  private let surface = SurfaceLayer()
  private let body: NSHostingController<SidebarLiveCardBody>
  private var hosting: NSView { body.view }
  private var tracking: NSTrackingArea?
  private var inside = false
  private var bodyHeight: CGFloat = 0

  public override var isFlipped: Bool { true }

  public init(favicons: SidebarFavicons?) {
    model.favicons = favicons
    body = NSHostingController(rootView: SidebarLiveCardBody(model: model, state: nil))
    body.sizingOptions = []
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    surface.radius = 12
    surface.border = 0.5
    surface.glowColor = .black
    surface.glowRadius = 16
    surface.glowOffset = CGSize(width: 0, height: 6)
    layer?.addSublayer(surface)
    addSubview(hosting)
    model.onEvent = { [weak self] in self?.onEvent?($0) }
    model.onHeight = { [weak self] height in self?.bodyChanged(height) }
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarLiveCardState) {
    if model.state?.id != next.id { model.showAll = false }
    if model.state != next {
      model.state = next
      body.rootView = SidebarLiveCardBody(model: model, state: next)
    }
    let look = next.look
    surface.fill = CSSColor(look.panel)?.ns
    surface.borderTint = CSSColor(look.panelBorder)?.ns
    surface.glowOpacity = look.shadowOpacity * 0.8
    hosting.appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
    let width = CGFloat(next.width)
    bodyHeight = body.sizeThatFits(in: NSSize(width: width - 24, height: 10_000)).height
    setFrameSize(NSSize(width: width, height: bodyHeight + 24))
    needsLayout = true
  }

  public var height: CGFloat { frame.height }

  private func bodyChanged(_ height: CGFloat) {
    guard abs(height - bodyHeight) > 0.25 else { return }
    bodyHeight = height
    setFrameSize(NSSize(width: frame.width, height: height + 24))
    needsLayout = true
    onResize?()
  }

  public override func layout() {
    super.layout()
    PrimitiveMotion.setInstantly { surface.frame = bounds }
    hosting.frame = bounds.insetBy(dx: 12, dy: 12)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(isHitBy(event)) }
  public override func mouseExited(with event: NSEvent) { pointer(false) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { pointer(false) }
  }

  @objc private func devPointer(_ note: Notification) { pointer(DevPointer.inside(self, note)) }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }

  public override func mouseDown(with event: NSEvent) {}
}

struct LiveLine {
  static let title = LiveLine(height: 18, font: .systemFont(ofSize: 13.5, weight: .semibold))

  let spacing: CGFloat
  let above: CGFloat
  let below: CGFloat

  init(height: CGFloat, font: NSFont) {
    let natural = font.ascender - font.descender + font.leading
    spacing = height - natural
    above = spacing / 2 + 0.5
    below = spacing / 2
  }
}

private func color(_ text: String) -> Color { Color(nsColor: CSSColor(text)?.ns ?? .clear) }

struct SidebarLiveCardBody: View {
  let model: SidebarLiveCardModel
  let state: SidebarLiveCardState?

  var body: some View {
    Group {
      if let state {
        if let pr = state.pr {
          LivePullRequestCard(state: state, pr: pr, model: model)
        } else {
          LiveDocumentCard(state: state, model: model)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onHeight($0) }
  }
}

struct LivePullRequestCard: View {
  let state: SidebarLiveCardState
  let pr: SidebarLiveCardState.PullRequest
  let model: SidebarLiveCardModel

  var body: some View {
    let look = state.look
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        LiveAvatar(uri: pr.avatar, name: pr.author, dark: look.dark, text: color(look.textPrimary))
        (Text(pr.author).fontWeight(.semibold).foregroundColor(color(look.textPrimary)) + Text(" · \(pr.place)"))
          .font(.system(size: 12))
          .foregroundStyle(color(look.textSecondary))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if pr.draft { LiveChip(text: "Draft", color: color(look.draft)) }
      }
      Text(state.title)
        .font(.system(size: 13.5, weight: .semibold))
        .lineSpacing(LiveLine.title.spacing)
        .padding(.top, LiveLine.title.above)
        .padding(.bottom, LiveLine.title.below)
        .foregroundStyle(color(look.textPrimary))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      if let summary = pr.summary {
        VStack(alignment: .leading, spacing: 6) {
          LiveCIBar(success: pr.success, pending: pr.pending, failure: pr.failure, look: look)
          LiveStatusLine(line: summary, look: look)
          ForEach(Array((model.showAll ? pr.failing : Array(pr.failing.prefix(3))).enumerated()), id: \.offset) { _, check in
            LiveFailingRow(check: check, look: look) { if let url = check.url { model.onEvent(.open(url)) } }
          }
          if pr.failing.count > 3 && !model.showAll {
            LiveLink(text: "Show all \(pr.failing.count) failures", color: color(look.accent)) { model.showAll = true }
          }
        }
      }
      if pr.conflicting {
        HStack(spacing: 8) {
          LiveStatusLine(line: .init(symbol: "exclamationmark.triangle.fill", tone: "conflict", text: "This branch has conflicts"), look: look)
            .frame(maxWidth: .infinity)
          LiveSmallButton(title: "Resolve Conflicts", look: look) { model.onEvent(.open("\(state.url)/conflicts")) }
        }
      }
      if let review = pr.review { LiveStatusLine(line: review, look: look) }
      Rectangle().fill(color(look.divider)).frame(height: 0.5)
      HStack(alignment: .center, spacing: 10) {
        Button { model.onEvent(.openItem) } label: {
          HStack(spacing: 4) {
            Image(systemName: "bubble.left").font(.system(size: 10.5)).frame(width: 14, height: 14)
            Text(pr.comments).font(.system(size: 11.5))
          }
          .foregroundStyle(color(look.textSecondary))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Spacer(minLength: 0)
        if pr.additions > 0 || pr.deletions > 0 {
          (Text("+\(pr.additions)").foregroundColor(color(look.success)) + Text(" ") + Text("\u{2212}\(pr.deletions)").foregroundColor(color(look.failure))
            + Text(pr.files.map { " · \($0)" } ?? ""))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(color(look.textSecondary))
        }
      }
    }
  }
}

struct LiveDocumentCard: View {
  let state: SidebarLiveCardState
  let model: SidebarLiveCardModel

  var body: some View {
    let look = state.look
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        LiveTabIcon(spec: TabIconSpec(
          url: state.url, favicon: state.doc?.direct == true ? state.doc?.icon : nil, customIcon: state.doc?.direct == true ? nil : state.doc?.icon,
          profileId: state.profileId, direct: state.doc?.direct == true), dark: look.dark, favicons: model.favicons)
          .frame(width: 16, height: 16)
        Text(state.title)
          .font(.system(size: 13.5, weight: .semibold))
          .lineSpacing(18 - 16.5)
          .foregroundStyle(color(look.textPrimary))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let doc = state.doc {
        Text(doc.meta).font(.system(size: 12)).foregroundStyle(color(look.textSecondary)).lineLimit(1)
        if let edited = doc.edited { Text(edited).font(.system(size: 12)).foregroundStyle(color(look.textSecondary)).lineLimit(1) }
      }
    }
  }
}

struct LiveTabIcon: NSViewRepresentable {
  let spec: TabIconSpec
  let dark: Bool
  weak var favicons: SidebarFavicons?

  func makeNSView(context: Context) -> TabIconView { TabIconView() }

  func updateNSView(_ view: TabIconView, context: Context) {
    view.favicons = favicons
    var host = SidebarHostState(profileId: spec.profileId, dark: dark)
    host.theme = [:]
    view.set(spec, palette: SidebarPalette(host))
  }
}

struct LiveAvatar: View {
  let uri: String?
  let name: String
  let dark: Bool
  let text: Color
  @State private var failed = false

  private var initials: String {
    let parts = name.split(whereSeparator: { " ._-".contains($0) || $0.isWhitespace }).prefix(2)
    let letters = parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    return letters.isEmpty ? "?" : letters
  }

  var body: some View {
    ZStack {
      Circle().fill(Color(nsColor: CSSColor(dark ? "#4A4A4F" : "#D5D5DA")?.ns ?? .gray))
      Text(initials).font(.system(size: 20 * 0.42, weight: .semibold)).foregroundStyle(text)
      if let uri, let url = URL(string: uri), !failed {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image): image.resizable()
          case .failure: Color.clear.onAppear { failed = true }
          default: Color.clear
          }
        }
      }
    }
    .frame(width: 20, height: 20)
    .clipShape(Circle())
  }
}

struct LiveChip: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .frame(height: 17)
      .overlay(Capsule().strokeBorder(color, lineWidth: 0.5))
  }
}

struct LiveCIBar: View {
  let success: Int
  let pending: Int
  let failure: Int
  let look: SidebarLiveCardState.Look
  @State private var dim = false

  var body: some View {
    GeometryReader { proxy in
      let parts = [(success, look.success), (pending, look.pending), (failure, look.failure)].filter { $0.0 > 0 }
      let gaps = CGFloat(max(0, parts.count - 1)) * 2
      let total = CGFloat(success + pending + failure)
      HStack(spacing: 2) {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
          Rectangle()
            .fill(color(part.1))
            .opacity(part.1 == look.pending && dim ? 0.45 : 1)
            .frame(width: total > 0 ? (proxy.size.width - gaps) * CGFloat(part.0) / total : 0)
        }
      }
    }
    .frame(height: 6)
    .background(color(look.ciTrack))
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .onAppear { pulse() }
    .onChange(of: pending) { pulse() }
  }

  private func pulse() {
    guard pending > 0 else { return dim = false }
    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
  }
}

struct LiveStatusLine: View {
  let line: SidebarLiveCardState.Line
  let look: SidebarLiveCardState.Look

  private var tint: Color {
    switch line.tone {
    case "success": color(look.success)
    case "failure": color(look.failure)
    case "pending": color(look.pending)
    case "conflict": color(look.conflict)
    default: color(look.textSecondary)
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: line.symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14, height: 14)
      Text(line.text).font(.system(size: 12)).foregroundStyle(color(look.textPrimary)).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LiveFailingRow: View {
  let check: SidebarLiveCardState.Check
  let look: SidebarLiveCardState.Look
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(color(look.failure)).frame(width: 12, height: 12)
        Text(check.name).font(.system(size: 12)).foregroundStyle(color(look.textPrimary)).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if hovered {
          Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(color(look.textSecondary)).frame(width: 12, height: 12)
        }
      }
      .padding(.horizontal, 5)
      .frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? color(look.rowHover) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

struct LiveLink: View {
  let text: String
  let color: Color
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Text(text).font(.system(size: 12)).foregroundStyle(color).underline(hovered)
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

struct LiveSmallButton: View {
  let title: String
  let look: SidebarLiveCardState.Look
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color(look.textPrimary))
        .padding(.horizontal, 9)
        .frame(height: 24)
    }
    .buttonStyle(LiveSmallButtonStyle(look: look, hovered: hovered))
    .onHover { hovered = $0 }
  }
}

struct LiveSmallButtonStyle: ButtonStyle {
  let look: SidebarLiveCardState.Look
  let hovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    let fill = configuration.isPressed ? look.toolbarPressed : hovered ? look.toolbarHover : look.urlPill
    configuration.label.background(RoundedRectangle(cornerRadius: 7).fill(color(fill)))
  }
}
