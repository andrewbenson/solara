import SwiftUI

struct PasswordDetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: PasswordsPaneModel
  let profile: String
  let saved: SavedPassword
  @State private var username: String
  @State private var password: String?
  @State private var revealed = false
  @State private var editing = false
  @State private var confirmingDelete = false

  init(model: PasswordsPaneModel, profile: String, saved: SavedPassword, revealed: Bool = false, editing: Bool = false) {
    self.model = model
    self.profile = profile
    self.saved = saved
    _username = State(initialValue: saved.username)
    _revealed = State(initialValue: revealed)
    _editing = State(initialValue: editing)
  }

  var body: some View {
    let services = model.services
    let host = services.hostLabel(saved.origin)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        SettingsFavicon(url: saved.origin, profile: profile, size: 22)
        Text(host)
          .font(.system(size: 15, weight: .semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      PasswordsSheetGroup {
        PasswordsSheetRow(title: "Website", description: saved.origin) { EmptyView() }
        Divider()
        PasswordsSheetRow(title: "Username") {
          if editing {
            TextField("", text: $username)
              .textContentType(.solaraPlainText)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          } else {
            HStack(spacing: 4) {
              Text(saved.username)
                .textSelection(.enabled)
              PasswordsIconButton(icon: "doc.on.doc", tooltip: "Copy Username") { services.copy(saved.username) }
            }
          }
        }
        Divider()
        PasswordsSheetRow(title: "Password") {
          if editing {
            Group {
              if revealed {
                TextField("", text: passwordBinding)
              } else {
                SecureField("", text: passwordBinding)
              }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
          } else {
            HStack(spacing: 4) {
              Text(PasswordsText.maskedPassword(password, revealed: revealed))
                .font(revealed && password != nil ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
              PasswordsIconButton(icon: revealed ? "eye.slash" : "eye", tooltip: revealed ? "Hide" : "Show") { revealed.toggle() }
              PasswordsIconButton(icon: "doc.on.doc", tooltip: "Copy Password") {
                if let password, !password.isEmpty { services.copy(password) }
              }
            }
          }
        }
      }
      .padding(.top, 14)
      HStack(spacing: 8) {
        Button("Delete", role: .destructive) { confirmingDelete = true }
          .foregroundStyle(.red)
        Spacer()
        if editing {
          Button("Cancel") { editing = false }
          Button("Save") { Task { await save() } }
            .keyboardShortcut(.defaultAction)
            .disabled(password?.isEmpty ?? true)
        } else {
          Button("Edit") { editing = true }
          Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(.top, 18)
    }
    .padding(20)
    .frame(width: 440)
    .task { password = await services.password(profile: profile, origin: saved.origin, username: saved.username) }
    .onDisappear {
      password = nil
      revealed = false
    }
    .alert("Delete the password for \(host)?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You won't be able to sign in with it automatically anymore.")
    }
  }

  private var passwordBinding: Binding<String> {
    Binding(get: { password ?? "" }, set: { password = $0 })
  }

  private func save() async {
    _ = await model.services.updatePassword(
      profile: profile,
      origin: saved.origin,
      username: saved.username,
      newUsername: username != saved.username ? username : nil,
      newPassword: password
    )
    await model.load(profile)
    dismiss()
  }

  private func remove() async {
    await model.services.deletePassword(profile: profile, origin: saved.origin, username: saved.username)
    await model.load(profile)
    dismiss()
  }
}

struct PasswordsSheetGroup<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) { content }
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(0.04))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          }
      }
  }
}

struct PasswordsSheetRow<Control: View>: View {
  let title: String
  let description: String?
  let control: Control

  init(title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.description = description
    self.control = control()
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let description {
          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 8)
      control
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(minHeight: 40)
  }
}

struct PasswordsIconButton: View {
  let icon: String
  let tooltip: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.08 : 0)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(tooltip)
    .accessibilityLabel(tooltip)
  }
}
