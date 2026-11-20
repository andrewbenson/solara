import SolaraLive
import SwiftUI

@MainActor
@Observable
final class LiveFoldersConnectRun {
  var busy = false
  var error: String?
  var finished = false

  func run(_ task: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    error = nil
    Task {
      do {
        try await task()
        finished = true
      } catch {
        self.error = error.localizedDescription
      }
      busy = false
    }
  }
}

struct LiveFoldersConnectSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: LiveFoldersPaneModel
  let source: LiveSourceId
  let appName: String
  @State private var runner = LiveFoldersConnectRun()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        SettingsFavicon(url: source.site, size: 22)
        Text("Connect \(source.name)")
          .font(.system(size: 15, weight: .semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.bottom, 12)
      content
      if let error = runner.error {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(Color(red: 0xE5 / 255, green: 0x53 / 255, blue: 0x4B / 255))
          .padding(.top, 10)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onChange(of: runner.finished) { _, done in
      if done { dismiss() }
    }
  }

  @ViewBuilder
  private var content: some View {
    let config = model.state?.config ?? LiveConfig.defaults
    switch source {
    case .github: LiveFoldersGithubConnect(model: model, runner: runner, appName: appName, clientId: config.githubClientId)
    case .notion: LiveFoldersNotionConnect(model: model, runner: runner)
    case .gdrive: LiveFoldersGoogleConnect(model: model, runner: runner, appName: appName, clientId: config.googleClientId)
    }
  }
}

struct LiveFoldersConnectHelp: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.system(size: 12))
      .lineSpacing(2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 10)
  }
}

struct LiveFoldersConnectField<Field: View>: View {
  let label: String
  let field: Field

  init(_ label: String, @ViewBuilder field: () -> Field) {
    self.label = label
    self.field = field()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
      field
        .textFieldStyle(.roundedBorder)
    }
    .padding(.bottom, 10)
  }
}

struct LiveFoldersConnectActions<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 8) {
      Spacer()
      content
    }
    .padding(.top, 6)
  }
}

private func filled(_ values: String...) -> Bool {
  values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct LiveFoldersGithubConnect: View {
  @Environment(\.dismiss) private var dismiss
  let model: LiveFoldersPaneModel
  let runner: LiveFoldersConnectRun
  let appName: String
  @State private var token = ""
  @State private var clientId: String
  @State private var flow: LiveDeviceFlow?

  init(model: LiveFoldersPaneModel, runner: LiveFoldersConnectRun, appName: String, clientId: String, flow: LiveDeviceFlow? = nil) {
    self.model = model
    self.runner = runner
    self.appName = appName
    _clientId = State(initialValue: clientId)
    _flow = State(initialValue: flow)
  }

  var body: some View {
    if let flow {
      VStack(alignment: .leading, spacing: 0) {
        LiveFoldersConnectHelp("Enter this code on GitHub (it's on your clipboard), then approve \(appName). This sheet closes when you're signed in.")
        Text(flow.userCode)
          .font(.system(size: 26, weight: .semibold, design: .monospaced))
          .tracking(3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
        LiveFoldersConnectActions {
          Button("Cancel") {
            model.services.cancelGithubDeviceFlow(flow)
            self.flow = nil
          }
          Button("Open GitHub") { model.services.openInBrowser(flow.verificationUri) }
            .buttonStyle(.borderedProminent)
        }
      }
      .onDisappear { model.services.cancelGithubDeviceFlow(flow) }
    } else {
      VStack(alignment: .leading, spacing: 0) {
        LiveFoldersConnectHelp("Paste a personal access token (classic: \"repo\" and \"read:org\" scopes; fine-grained: read access to pull requests, checks and metadata).")
        LiveFoldersConnectField("Personal access token") {
          SecureField("", text: $token, prompt: Text(verbatim: "ghp_…"))
            .onSubmit { if !token.isEmpty { connect() } }
        }
        LiveFoldersConnectActions {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(runner.busy ? "Checking…" : "Connect") { connect() }
            .buttonStyle(.borderedProminent)
            .disabled(!filled(token) || runner.busy)
        }
        Divider()
          .padding(.vertical, 14)
        LiveFoldersConnectHelp("Or sign in with your own GitHub OAuth app (Settings › Developer settings › OAuth Apps, with Device Flow enabled).")
        LiveFoldersConnectField("OAuth app client ID") {
          TextField("", text: $clientId, prompt: Text(verbatim: "Iv1.…"))
            .textContentType(.solaraPlainText)
        }
        LiveFoldersConnectActions {
          Button("Sign In with GitHub…") { signIn() }
            .disabled(!filled(clientId) || runner.busy)
        }
      }
    }
  }

  private func connect() {
    let token = token
    runner.run { try await model.services.connectGithub(token: token) }
  }

  private func signIn() {
    let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
    let services = model.services
    runner.run {
      services.setGithubClientId(id)
      let started = try await services.startGithubDeviceFlow(clientId: id)
      flow = started
      services.copyText(started.userCode)
      services.openInBrowser(started.verificationUri)
      try await services.finishGithubDeviceFlow(started)
    }
  }
}

struct LiveFoldersNotionConnect: View {
  @Environment(\.dismiss) private var dismiss
  let model: LiveFoldersPaneModel
  let runner: LiveFoldersConnectRun
  @State private var token = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      LiveFoldersConnectHelp("Create an internal integration at notion.so/my-integrations (read content; read user information for editor names), copy its secret, and share the pages or teamspaces you want with it (••• › Connections).")
      LiveFoldersConnectField("Internal integration secret") {
        SecureField("", text: $token, prompt: Text(verbatim: "ntn_…"))
          .onSubmit { go() }
      }
      LiveFoldersConnectActions {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(runner.busy ? "Checking…" : "Connect") { go() }
          .buttonStyle(.borderedProminent)
          .disabled(!filled(token) || runner.busy)
      }
    }
  }

  private func go() {
    let token = token
    runner.run { try await model.services.connectNotion(token: token) }
  }
}

struct LiveFoldersGoogleConnect: View {
  @Environment(\.dismiss) private var dismiss
  let model: LiveFoldersPaneModel
  let runner: LiveFoldersConnectRun
  let appName: String
  @State private var clientId: String
  @State private var secret = ""

  init(model: LiveFoldersPaneModel, runner: LiveFoldersConnectRun, appName: String, clientId: String) {
    self.model = model
    self.runner = runner
    self.appName = appName
    _clientId = State(initialValue: clientId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      LiveFoldersConnectHelp("In Google Cloud Console, enable the Drive API and create an OAuth client of type \"Desktop app\" (add yourself as a test user). \(appName) opens Google's consent page in a tab and reads the result from its redirect; it asks only to see your files' names and dates.")
      LiveFoldersConnectField("Client ID") {
        TextField("", text: $clientId, prompt: Text(verbatim: "…apps.googleusercontent.com"))
          .textContentType(.solaraPlainText)
      }
      LiveFoldersConnectField("Client secret") {
        SecureField("", text: $secret)
      }
      LiveFoldersConnectActions {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(runner.busy ? "Waiting for Google…" : "Sign In with Google…") { go() }
          .buttonStyle(.borderedProminent)
          .disabled(!filled(clientId, secret) || runner.busy)
      }
    }
  }

  private func go() {
    let clientId = clientId
    let secret = secret
    runner.run { try await model.services.connectGoogleDrive(clientId: clientId, clientSecret: secret) }
  }
}
