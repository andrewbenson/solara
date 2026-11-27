import AppKit
import Observation
import SolaraLive
import SwiftUI

extension LiveSourceId: Identifiable {
  public var id: String { rawValue }

  public var name: String {
    switch self {
    case .github: "GitHub"
    case .notion: "Notion"
    case .gdrive: "Google Drive"
    }
  }

  public var site: String {
    switch self {
    case .github: "https://github.com"
    case .notion: "https://www.notion.so"
    case .gdrive: "https://drive.google.com"
    }
  }

  var settingsAnchor: String {
    switch self {
    case .github: "liveFolders.github"
    case .notion: "liveFolders.notion"
    case .gdrive: "liveFolders.gdrive"
    }
  }

  var settingsDescription: String {
    switch self {
    case .github: "Your open pull requests and the ones waiting for your review, with checks and conflicts."
    case .notion: "Pages recently edited in your workspace."
    case .gdrive: "Documents recently changed in your Drive."
    }
  }
}

public struct LiveFolderError: Sendable, Equatable {
  public var kind: LiveErrorKind
  public var source: LiveSourceId

  public init(kind: LiveErrorKind, source: LiveSourceId) {
    self.kind = kind
    self.source = source
  }
}

public enum LiveFolderFetchState: String, Sendable {
  case initializing
  case idle
  case updating
  case error
}

public struct LiveFolderStatus: Sendable, Equatable {
  public var state: LiveFolderFetchState
  public var lastFetch: Date?
  public var error: LiveFolderError?

  public init(state: LiveFolderFetchState, lastFetch: Date?, error: LiveFolderError?) {
    self.state = state
    self.lastFetch = lastFetch
    self.error = error
  }
}

public struct LiveFolderSummary: Sendable, Equatable, Identifiable {
  public var id: String
  public var profileId: String
  public var kind: LiveFolderKind
  public var name: String
  public var sources: [LiveSourceId]
  public var groupStacks: Bool
  public var showCompleted: Bool
  public var status: LiveFolderStatus?
  public var hiddenCount: Int

  public init(id: String, profileId: String, kind: LiveFolderKind, name: String, sources: [LiveSourceId], groupStacks: Bool, showCompleted: Bool, status: LiveFolderStatus?, hiddenCount: Int) {
    self.id = id
    self.profileId = profileId
    self.kind = kind
    self.name = name
    self.sources = sources
    self.groupStacks = groupStacks
    self.showCompleted = showCompleted
    self.status = status
    self.hiddenCount = hiddenCount
  }
}

public struct LiveFoldersState: Sendable, Equatable {
  public var folders: [LiveFolderSummary]
  public var accounts: [LiveSourceId: LiveAccount]
  public var config: LiveConfig
  public var mocked: Bool

  public init(folders: [LiveFolderSummary], accounts: [LiveSourceId: LiveAccount], config: LiveConfig, mocked: Bool = false) {
    self.folders = folders
    self.accounts = accounts
    self.config = config
    self.mocked = mocked
  }
}

public struct LiveDeviceFlow: Sendable, Equatable, Identifiable {
  public var id: String
  public var userCode: String
  public var verificationUri: String

  public init(id: String, userCode: String, verificationUri: String) {
    self.id = id
    self.userCode = userCode
    self.verificationUri = verificationUri
  }
}

public struct LiveConnectError: LocalizedError, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

@MainActor
public protocol LiveFoldersServices: AnyObject {
  func liveFoldersState() async -> LiveFoldersState
  func liveFoldersChanges() -> AsyncStream<LiveFoldersState>
  func refreshFolder(_ id: String) async
  func deleteFolder(_ id: String)
  func updateFolder(_ id: String, groupStacks: Bool?, showCompleted: Bool?)
  func disconnect(_ source: LiveSourceId) async
  func connectGithub(token: String) async throws
  func setGithubClientId(_ clientId: String)
  func startGithubDeviceFlow(clientId: String) async throws -> LiveDeviceFlow
  func finishGithubDeviceFlow(_ flow: LiveDeviceFlow) async throws
  func cancelGithubDeviceFlow(_ flow: LiveDeviceFlow)
  func connectNotion(token: String) async throws
  func connectGoogleDrive(clientId: String, clientSecret: String) async throws
  func copyText(_ text: String)
  func openInBrowser(_ url: String)
}

enum LiveFoldersText {
  static func connectedAs(_ source: LiveSourceId, _ account: LiveAccount) -> String {
    guard let name = account.name, !name.isEmpty, name != account.login else { return account.login }
    return source == .github || source == .gdrive ? "\(name) (\(account.login))" : name
  }

  static func sourceDescription(_ source: LiveSourceId, _ account: LiveAccount?) -> String {
    guard let account else { return source.settingsDescription }
    return "Connected as \(connectedAs(source, account))"
  }

  static func statusText(_ folder: LiveFolderSummary, now: Date) -> String {
    let fetch = fetchText(folder.status, now: now)
    return folder.hiddenCount > 0 ? "\(fetch) · \(folder.hiddenCount) hidden until you refresh" : fetch
  }

  static func fetchText(_ status: LiveFolderStatus?, now: Date) -> String {
    guard let status, status.state != .initializing else { return "Loading…" }
    if status.state == .updating { return "Updating…" }
    if let error = status.error { return errorText(error.kind, error.source) }
    guard let lastFetch = status.lastFetch else { return "Not updated yet" }
    let minutes = Int((now.timeIntervalSince(lastFetch) / 60).rounded(.down))
    if minutes < 1 { return "Updated just now" }
    if minutes < 60 { return "Updated \(minutes) min ago" }
    return "Updated \(minutes / 60) hr ago"
  }

  static func errorText(_ kind: LiveErrorKind, _ source: LiveSourceId) -> String {
    let name = source.name
    switch kind {
    case .notConfigured: return "Connect \(name) in Settings"
    case .signedOut: return "Sign back in to \(name)"
    case .sso: return "\(name) needs Single Sign-On for this organization"
    case .rateLimited: return "\(name) rate limit exceeded. Try again in a few minutes."
    case .network: return "Couldn't connect to \(name)"
    case .other: return "We're having trouble connecting to \(name)"
    }
  }

  static func folderDescription(_ folder: LiveFolderSummary, profileName: String, now: Date) -> String {
    "\(profileName) · \(folder.sources.map(\.name).joined(separator: ", ")) · \(statusText(folder, now: now))"
  }
}

@MainActor
@Observable
public final class LiveFoldersPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: LiveFoldersServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored private var listening: Task<Void, Never>?
  var state: LiveFoldersState?

  public init(services: LiveFoldersServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { state != nil }

  public func prepare(_ place: SettingsPlace) async {
    listen()
    if state == nil { state = await services.liveFoldersState() }
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(LiveFoldersPane(model: self))
  }

  private func listen() {
    guard listening == nil else { return }
    let changes = services.liveFoldersChanges()
    listening = Task { [weak self] in
      for await next in changes {
        guard let self else { return }
        self.state = next
      }
    }
  }

  var folders: [LiveFolderSummary] { state?.folders ?? [] }

  var anchoredOptionsFolderId: String? { folders.first { $0.kind == .pullRequests }?.id }

  func account(_ source: LiveSourceId) -> LiveAccount? { state?.accounts[source] }

  func profileName(_ folder: LiveFolderSummary) -> String {
    store.profiles.first { $0.id == folder.profileId }?.name ?? "Profile"
  }

  func setGroupStacks(_ folder: LiveFolderSummary, _ on: Bool) {
    patchFolder(folder.id) { $0.groupStacks = on }
    services.updateFolder(folder.id, groupStacks: on, showCompleted: nil)
  }

  func setShowCompleted(_ folder: LiveFolderSummary, _ on: Bool) {
    patchFolder(folder.id) { $0.showCompleted = on }
    services.updateFolder(folder.id, groupStacks: nil, showCompleted: on)
  }

  func refresh(_ folder: LiveFolderSummary) {
    Task { await services.refreshFolder(folder.id) }
  }

  func delete(_ folder: LiveFolderSummary) {
    services.deleteFolder(folder.id)
  }

  func disconnect(_ source: LiveSourceId) {
    state?.accounts[source] = nil
    Task { await services.disconnect(source) }
  }

  private func patchFolder(_ id: String, _ change: (inout LiveFolderSummary) -> Void) {
    guard let index = state?.folders.firstIndex(where: { $0.id == id }) else { return }
    change(&state!.folders[index])
  }
}

struct LiveFoldersPane: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  @State private var connecting: LiveSourceId?

  var body: some View {
    SettingsForm {
      SettingsSection(
        description: "Right-click empty sidebar space and choose New Live Folder. Folders refresh every few minutes.",
        anchor: "liveFolders.folders"
      ) {
        EmptyView()
      }

      ForEach(model.folders) { folder in
        LiveFoldersFolderSection(model: model, folder: folder, anchored: folder.id == model.anchoredOptionsFolderId)
      }

      SettingsSection("Pull Requests") {
        LiveFoldersSourceRow(model: model, source: .github, connecting: $connecting)
      }

      SettingsSection("Documents") {
        LiveFoldersSourceRow(model: model, source: .notion, connecting: $connecting)
        LiveFoldersSourceRow(model: model, source: .gdrive, connecting: $connecting)
      }

      if model.state?.mocked == true {
        Section {
          Text("Development build: services are served by SOLARA_LIVE_MOCK.")
            .font(.caption)
            .foregroundStyle(Color(red: 0xD2 / 255, green: 0x99 / 255, blue: 0x22 / 255))
        }
      }
    }
    .sheet(item: $connecting) { source in
      LiveFoldersConnectSheet(model: model, source: source, appName: context?.appName ?? "")
    }
  }
}

struct LiveFoldersFolderSection: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  let folder: LiveFolderSummary
  let anchored: Bool

  var body: some View {
    Section {
      TimelineView(.everyMinute) { timeline in
        SettingRow(title: folder.name, description: LiveFoldersText.folderDescription(folder, profileName: model.profileName(folder), now: timeline.date)) {
          HStack(spacing: 6) {
            Button("Refresh") { model.refresh(folder) }
            Button("Delete", role: .destructive) { model.delete(folder) }
              .liveSettingsControl("live.delete.\(folder.id)")
          }
        }
      }
      if folder.kind == .pullRequests {
        option("liveFolders.groupStacks", isOn: Binding(get: { folder.groupStacks }, set: { model.setGroupStacks(folder, $0) }))
        option("liveFolders.showCompleted", isOn: Binding(get: { folder.showCompleted }, set: { model.setShowCompleted(folder, $0) }))
      }
    }
  }

  private func option(_ id: String, isOn: Binding<Bool>) -> some View {
    let entry = context?.index.entry(id)
    return SettingRow(anchored ? id : nil, title: entry?.title, description: entry.flatMap(\.displayCaption).map(RowDescription.text) ?? .none) {
      Toggle("", isOn: isOn)
        .labelsHidden()
        .toggleStyle(.settingsSwitch)
    }
  }
}

struct LiveFoldersSourceRow: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  let source: LiveSourceId
  @Binding var connecting: LiveSourceId?

  var body: some View {
    let account = model.account(source)
    SettingsAnchor(source.settingsAnchor) {
      LabeledContent {
        if account != nil {
          Button("Disconnect") { model.disconnect(source) }
        } else {
          Button("Connect…") { connecting = source }
            .liveSettingsControl("live.connect.\(source.rawValue)")
        }
      } label: {
        HStack(spacing: 10) {
          SettingsFavicon(url: source.site, size: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(context?.index.entry(source.settingsAnchor)?.title ?? source.name)
            Text(LiveFoldersText.sourceDescription(source, account))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}
