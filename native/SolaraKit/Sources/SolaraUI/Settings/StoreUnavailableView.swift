import AppKit
import SolaraStore
import SwiftUI

public struct StoreUnavailableView: View {
  public enum Context: Equatable, Sendable {
    case settings
    case launch
  }

  public enum Choice: String, CaseIterable, Sendable {
    case quit
    case safeMode
    case showFolder
    case report
  }

  public struct Actions {
    public var quit: () -> Void
    public var showDataFolder: (URL) -> Void
    public var openInSafeMode: () -> Void
    public var reportBug: () -> Void

    public init(
      quit: @escaping () -> Void, showDataFolder: @escaping (URL) -> Void, openInSafeMode: @escaping () -> Void = {},
      reportBug: @escaping () -> Void = {}
    ) {
      self.quit = quit
      self.showDataFolder = showDataFolder
      self.openInSafeMode = openInSafeMode
      self.reportBug = reportBug
    }
  }

  public struct ReportedLink: Equatable, Sendable {
    public let link: String
    public let copied: Bool

    public init(link: String, copied: Bool) {
      self.link = link
      self.copied = copied
    }
  }

  let failure: StoreUnavailable
  let appName: String
  let context: Context
  let choices: [Choice]
  let reported: ReportedLink?
  let actions: Actions

  public init(failure: StoreUnavailable, appName: String, quit: @escaping () -> Void, showDataFolder: @escaping (URL) -> Void) {
    self.init(
      failure: failure, appName: appName, context: .settings,
      choices: Self.choices(
        failure: failure, context: .settings, safeModeAvailable: false, folderExists: Self.folderExists(failure.dataFolder), reportAvailable: false),
      reported: nil, actions: Actions(quit: quit, showDataFolder: showDataFolder))
  }

  public init(failure: StoreUnavailable, appName: String, context: Context, choices: [Choice], reported: ReportedLink?, actions: Actions) {
    self.failure = failure
    self.appName = appName
    self.context = context
    self.choices = choices
    self.reported = reported
    self.actions = actions
  }

  public static func choices(
    failure: StoreUnavailable, context: Context, safeModeAvailable: Bool, folderExists: Bool, reportAvailable: Bool
  ) -> [Choice] {
    var shown: [Choice] = []
    if context == .launch && reportAvailable { shown.append(.report) }
    if failure.dataFolder != nil && folderExists { shown.append(.showFolder) }
    if context == .launch && failure.offersSafeMode && safeModeAvailable && !failure.launchWasSafeMode { shown.append(.safeMode) }
    shown.append(.quit)
    return shown
  }

  public static func folderExists(_ folder: URL?) -> Bool {
    var directory: ObjCBool = false
    guard let folder else { return false }
    return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue
  }

  public var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.yellow)
        .accessibilityHidden(true)
      Text(title)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      Text(explanation)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text(failure.detail)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Details: \(failure.detail)")
      if let reported {
        VStack(spacing: 6) {
          Text(reportNote(reported))
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Text(reported.link)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
      }
      HStack(spacing: 10) {
        ForEach(choices, id: \.self) { choice in
          button(choice)
        }
      }
      .controlSize(.large)
      .padding(.top, 6)
    }
    .padding(32)
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  func button(_ choice: Choice) -> some View {
    switch choice {
    case .report:
      Button("Report a Bug", action: actions.reportBug)
    case .showFolder:
      Button("Show Data Folder") {
        if let folder = failure.dataFolder { actions.showDataFolder(folder) }
      }
    case .safeMode:
      Button("Open in Safe Mode", action: actions.openInSafeMode)
    case .quit:
      Button("Quit \(appName)", action: actions.quit)
        .keyboardShortcut(.defaultAction)
    }
  }

  func reportNote(_ reported: ReportedLink) -> String {
    reported.copied
      ? "The report link is copied. Paste it into a browser to file the report."
      : "Open this link in a browser to file the report."
  }

  var title: String {
    switch context {
    case .settings: "\(appName) couldn't open its settings"
    case .launch: "\(appName) couldn't open your windows and tabs"
    }
  }

  var explanation: String {
    let reason = switch failure.cause {
    case .refused:
      "\(appName) couldn't safely read the file that holds your windows, tabs and settings, so it left the file as it was instead of risking your data. If a newer version of \(appName) wrote it, update \(appName) and open it again."
    case .openFailed:
      "\(appName) couldn't open its data folder. Nothing in it was changed, moved or reset. Quit and open \(appName) again; if this keeps happening, the details below say what went wrong."
    }
    guard context == .launch, failure.launchWasSafeMode else { return reason }
    return reason + " This launch was already in safe mode."
  }
}
