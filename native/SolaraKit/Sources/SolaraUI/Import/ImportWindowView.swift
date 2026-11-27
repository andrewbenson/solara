import AppKit
import SwiftUI

public struct ImportWindowView: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel
  let starts: Bool

  public init(model: ImportModel, starts: Bool = true) {
    self.model = model
    self.starts = starts
  }

  public var body: some View {
    let colors = ImportColors(scheme)
    VStack(spacing: 0) {
      ScrollView {
        ImportStepBody(model: model)
          .padding(.horizontal, 32)
          .padding(.top, 46)
          .padding(.bottom, 20)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .scrollBounceBehavior(.basedOnSize)
      Rectangle()
        .fill(colors.divider)
        .frame(height: ImportColors.hairline)
      HStack(spacing: 8) {
        ImportStepFooter(model: model)
      }
      .padding(.horizontal, 20)
      .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      ZStack {
        colors.window
        ImportBackdrop()
      }
      .ignoresSafeArea()
    }
    .overlay(alignment: .top) {
      ImportDragRegion()
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
    }
    .ignoresSafeArea()
    .task {
      if starts { await model.start() }
    }
    .task(id: model.pollsDia) {
      if model.pollsDia { await model.pollDia() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.appBecameActive() }
    }
  }
}

struct ImportStepBody: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch model.step {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.top, 80)
      case .choose:
        ImportChooseStep(model: model)
      case .profiles:
        if model.source != nil { ImportProfilesStep(model: model) }
      case .unlock:
        if model.source != nil { ImportUnlockStep(model: model) }
      case .safari:
        ImportSafariStep(model: model)
      case .access:
        if let source = model.source { ImportAccessStep(model: model, source: source) }
      case .dia:
        if model.source != nil { ImportDiaStep(model: model) }
      case .progress:
        ImportProgressStep(model: model)
      case .done:
        ImportDoneStep(model: model)
      }
    }
  }
}

struct ImportChooseStep: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    let colors = ImportColors(scheme)
    ImportTitle(title: "Import from Another Browser", subtitle: "Import once and stay in your flow. Your tabs, passwords, bookmarks and history come with you, and you stay signed in.")
    if !model.available {
      ImportNote(text: "Importing isn't available in this build of \(model.appName).")
    } else if model.browsers.isEmpty {
      ImportNote(text: "No other browsers with data to import were found on this Mac.")
    } else {
      VStack(spacing: 6) {
        ForEach(model.browsers) { browser in
          ImportBrowserRow(browser: browser, selected: model.source?.id == browser.id) { model.choose(browser) }
        }
      }
    }
    if model.showsKinds {
      VStack(alignment: .leading, spacing: 0) {
        ImportSectionLabel(text: "What to import")
        ImportFlow(spacing: 14, lineSpacing: 14) {
          ForEach(model.offeredKinds, id: \.self) { kind in
            Toggle(model.label(kind), isOn: Binding(get: { model.kinds.contains(kind) }, set: { model.setKind(kind, $0) }))
              .toggleStyle(.checkbox)
          }
        }
        if model.isDiaTabs {
          Text("\(model.appName) asks Dia for each profile's open and pinned tabs while Dia is running. \(ImportModel.diaNotShared)")
            .font(.system(size: 12))
            .lineSpacing(2)
            .foregroundStyle(colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
      }
      .padding(.top, 18)
    }
    if let error = model.error { ImportErrorText(text: error) }
  }
}

struct ImportProfilesStep: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    let colors = ImportColors(scheme)
    let app = model.appName
    let source = model.source!
    if model.bySpaces {
      ImportTitle(title: "Select spaces to import", subtitle: "We'll import your \(source.name) spaces, tabs, and folders to \(app).")
      intro("Customize which spaces to bring over to \(app). Each space becomes a profile, and the spaces of one \(source.name) profile share its logins, cookies, extensions and history, as in \(source.name).", colors)
      VStack(spacing: 6) {
        ForEach(model.allSpaces) { space in
          ImportSelectRow(
            selected: model.spaces.contains(space.id),
            onToggle: { model.toggleSpace(space.id, $0) },
            title: space.name.isEmpty ? "Space" : space.name,
            subtitle: "\(importPlural(space.pinnedCount, "pinned tab")) · \(importPlural(space.tabCount, "tab"))"
          ) { ImportSpaceIcon(space: space) }
        }
        if source.sidebar == .zen {
          ForEach(model.spaceless) { profile in
            ImportSelectRow(
              selected: model.sourceProfiles.contains(profile.id),
              onToggle: { model.toggleSourceProfile(profile.id, $0) },
              title: profile.name,
              subtitle: profile.isDefault ? "Default profile" : nil
            ) { ImportMonogram(name: profile.name, color: profile.color) }
          }
        }
      }
    } else {
      if model.isDiaTabs {
        ImportTitle(title: "Choose Dia profiles", subtitle: "Select the profiles whose tabs you want to bring over.")
      } else {
        ImportTitle(title: "Unlock your data for import", subtitle: "Select the profiles you want to import.")
      }
      intro("Customize which profiles to bring over to \(app). The first goes into your selected profile; the others become new profiles.", colors)
      VStack(spacing: 6) {
        ForEach(source.profiles) { profile in
          ImportSelectRow(
            selected: model.sourceProfiles.contains(profile.id),
            onToggle: { model.toggleSourceProfile(profile.id, $0) },
            title: profile.name,
            subtitle: model.isDiaTabs ? model.diaSummary(profile.id) : (profile.email ?? (profile.isDefault ? "Default profile" : nil))
          ) {
            if profile.avatarPath != nil, let path = profile.avatarPath, NSImage(contentsOfFile: path) != nil {
              ImportFileIcon(path: path, size: 28, round: true)
            } else {
              ImportMonogram(name: profile.name, color: profile.color)
            }
          }
        }
      }
    }
  }

  private func intro(_ text: String, _ colors: ImportColors) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(colors.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 10)
  }
}

struct ImportHandoffGraphic: View {
  @Environment(\.colorScheme) private var scheme
  let iconPath: String?
  let symbol: String

  var body: some View {
    let colors = ImportColors(scheme)
    HStack(spacing: 16) {
      if iconPath != nil { ImportFileIcon(path: iconPath, size: 56) }
      Image(systemName: "arrow.right")
        .font(.system(size: 16))
        .foregroundStyle(colors.textTertiary)
        .frame(width: 20, height: 20)
      Image(systemName: symbol)
        .font(.system(size: 30))
        .foregroundStyle(colors.icon)
        .frame(width: 56, height: 56)
    }
  }
}

struct ImportCenteredText: View {
  @Environment(\.colorScheme) private var scheme
  let text: String
  let primary: Bool
  let maxWidth: CGFloat

  var body: some View {
    let colors = ImportColors(scheme)
    Text(text)
      .font(.system(size: primary ? 13 : 12))
      .lineSpacing(primary ? 2.5 : 2)
      .multilineTextAlignment(.center)
      .foregroundStyle(primary ? colors.textPrimary : colors.textSecondary)
      .frame(maxWidth: maxWidth)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ImportUnlockStep: View {
  let model: ImportModel

  var body: some View {
    let app = model.appName
    let source = model.source!
    let many = model.sourceProfiles.count > 1
    ImportTitle(
      title: "Unlock your data for import",
      subtitle: "\(app) can securely import logins, cookies and cards from your previous browser, so you stay signed in and don't have to enter your passwords again."
    )
    VStack(spacing: 14) {
      ImportHandoffGraphic(iconPath: source.iconPath, symbol: "lock.fill")
      ImportCenteredText(
        text: many
          ? "Some data is encrypted, so macOS will ask for your computer password once for each selected profile."
          : "Some data is encrypted, so macOS will ask for your computer password to bring it securely into \(app).",
        primary: true,
        maxWidth: 420
      )
      ImportCenteredText(
        text: "macOS may ask whether \(app) can use “\(model.keychainItem)” from your keychain: it's the key \(source.name) encrypts passwords, cookies, cards and open tabs with. Click Allow. Your data stays on this Mac.",
        primary: false,
        maxWidth: 420
      )
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 10)
    if let error = model.error { ImportErrorText(text: error) }
  }
}

struct ImportSafariStep: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    let colors = ImportColors(scheme)
    let app = model.appName
    if model.fullDiskAccess {
      ImportTitle(title: "Import from Safari", subtitle: "\(app) can read Safari directly. Bring your bookmarks, history, Reading List, open tabs and sign-ins into \(app).")
      HStack(spacing: 12) {
        if model.source?.iconPath != nil { ImportFileIcon(path: model.source?.iconPath, size: 40) }
        VStack(alignment: .leading, spacing: 0) {
          Text("Bookmarks, history, Reading List and tabs")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colors.textPrimary)
          Text("Full Disk Access is granted.")
            .font(.system(size: 12))
            .foregroundStyle(colors.textSecondary)
            .padding(.top, 1)
          Toggle("Cookies (stay signed in)", isOn: Binding(get: { model.safariCookies }, set: { model.safariCookies = $0 }))
            .toggleStyle(.checkbox)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button("Import from Safari") { Task { await model.importSafariDirect() } }
          .buttonStyle(.borderedProminent)
      }
      .padding(.bottom, 18)
      ImportSectionLabel(text: "Passwords and payment cards can't be read directly — import them from an export file:")
      drop
    } else {
      ImportTitle(title: "Give \(app) access to Safari", subtitle: "To import Safari's bookmarks, history and tabs directly, \(app) needs Full Disk Access.")
      ImportFullDiskAccessSteps(model: model)
      ImportSectionLabel(text: "Or import everything (including passwords) from an export file:")
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(["Open Safari", "File menu › Export Browsing Data to File", "Upload the .zip file to \(app)"].enumerated()), id: \.offset) { index, line in
          Text("\(index + 1). \(line)")
            .font(.system(size: 12))
            .foregroundStyle(colors.textSecondary)
        }
      }
      .padding(.bottom, 12)
      drop
    }
    if let error = model.error { ImportErrorText(text: error) }
  }

  private var drop: some View {
    ImportFileDrop(
      onFile: { path in Task { await model.importSafari(path: path) } },
      onChoose: { Task { await model.chooseSafariExport() } }
    )
  }
}

struct ImportFullDiskAccessSteps: View {
  let model: ImportModel

  var body: some View {
    ImportSettingsSteps(
      steps: ["Click “Open Full Disk Access Settings” below", "Turn on \(model.appName) in the list", "Come back here: we'll continue automatically"],
      openTitle: "Open Full Disk Access Settings",
      onOpen: { model.services.openFullDiskAccessSettings() },
      onRecheck: { Task { await model.recheckAccess() } }
    )
  }
}

struct ImportAccessStep: View {
  let model: ImportModel
  let source: ImportBrowser

  var body: some View {
    let app = model.appName
    ImportTitle(
      title: "Give \(app) access to \(source.name)",
      subtitle: "macOS protects \(source.name)'s data from other apps. To import your bookmarks, history, tabs, passwords and cookies, \(app) needs Full Disk Access."
    )
    ImportFullDiskAccessSteps(model: model)
    if let error = model.error { ImportErrorText(text: error) }
  }
}

struct ImportDiaStep: View {
  let model: ImportModel

  var body: some View {
    let app = model.appName
    switch model.diaStatus {
    case .checking, .reading:
      ImportTitle(title: "Reading Dia's tabs", subtitle: "Asking Dia for its profiles, open tabs and pinned tabs...", spinner: true)
    case .notInstalled:
      ImportTitle(title: "Dia isn't installed", subtitle: "Install Dia and open it to import its tabs into \(app).")
    case .notRunning:
      ImportTitle(title: "Open Dia to import its tabs", subtitle: "\(app) asks Dia for its tabs, so Dia has to be running. Open it and this continues on its own.")
      HStack(spacing: 10) {
        Button("Open Dia") { Task { await model.openDia() } }
          .buttonStyle(.borderedProminent)
        Button("Check Again") { Task { await model.refreshDia() } }
      }
    case .notDetermined:
      ImportTitle(title: "Allow \(app) to read Dia's tabs", subtitle: "Dia shares its tabs through AppleScript, and macOS asks you before an app can use it.")
      VStack(spacing: 14) {
        ImportHandoffGraphic(iconPath: model.source?.iconPath, symbol: "square.on.square")
        ImportCenteredText(
          text: "When you continue, macOS asks whether “\(app)” may control “Dia”. Click Allow, and \(app) asks Dia for its profiles, open tabs and pinned tabs. It only reads them: nothing in Dia changes.",
          primary: true,
          maxWidth: 440
        )
        ImportCenteredText(text: ImportModel.diaNotShared, primary: false, maxWidth: 440)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 10)
    case .denied:
      ImportTitle(title: "\(app) can't read Dia's tabs", subtitle: "macOS doesn't allow \(app) to control Dia. You can allow it in System Settings › Privacy & Security › Automation.")
      ImportSettingsSteps(
        steps: ["Click “Open Automation Settings” below", "Under \(app), turn on Dia", "Come back here: we'll continue automatically"],
        openTitle: "Open Automation Settings",
        onOpen: { model.services.openAutomationSettings() },
        onRecheck: { Task { await model.refreshDia() } }
      )
    case .granted:
      ImportTitle(title: "Import tabs from Dia", subtitle: ImportModel.diaNotShared)
      Button("Try Again") { Task { await model.readDia() } }
    }
    if let error = model.error { ImportErrorText(text: error) }
  }
}

struct ImportProgressStep: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    let colors = ImportColors(scheme)
    ImportTitle(title: model.progressTitle, subtitle: model.progressSubtitle, spinner: true)
    Text("Hold on while we fetch your data...")
      .font(.system(size: 12))
      .foregroundStyle(colors.textSecondary)
      .padding(.bottom, 12)
    VStack(spacing: 6) {
      ForEach(Array(model.progressRows.enumerated()), id: \.element.kind) { index, row in
        ImportCategoryRow(kind: row.kind, status: row.status, index: index)
      }
    }
  }
}

#if DEBUG
@MainActor
public enum ImportRestoreButtonProbe {
  public static var frame: CGRect?
  public static var presses = 0
}
#endif

struct ImportDoneStep: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    let colors = ImportColors(scheme)
    if !model.failures.isEmpty {
      ImportTitle(title: model.summary.isEmpty ? "Import failed" : "Partially imported", subtitle: "Only some of your data imported. Please try again!")
      Text("Some import steps failed:")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(colors.textPrimary)
        .padding(.bottom, 6)
      ForEach(Array(model.failures.enumerated()), id: \.offset) { _, failure in
        Text(ImportModel.failureLine(failure))
          .font(.system(size: 13))
          .foregroundStyle(colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 3)
      }
      if let line = model.importedLine {
        Text(line)
          .font(.system(size: 12))
          .foregroundStyle(colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 12)
      }
      leftBehind(colors, centered: false)
      extensionList(colors)
      Text("You can retry the import later from the app menu.")
        .font(.system(size: 12))
        .foregroundStyle(colors.textTertiary)
        .padding(.top, 12)
    } else {
      VStack(spacing: 12) {
        ImportSuccessMark()
        Text("You're all set")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(colors.textPrimary)
        Text(model.importedLine ?? "There was nothing new to import.")
          .font(.system(size: 13))
          .foregroundStyle(colors.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        leftBehind(colors, centered: true)
        extensionList(colors)
        if model.arcHolders > 0 {
          restoreArcButton
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 40)
    }
  }

  private var restoreArcButton: some View {
    let button = Button("Restore Arc Folders as Groups") {
      #if DEBUG
      ImportRestoreButtonProbe.presses += 1
      #endif
      Task { await model.restoreArcFolders() }
    }
    #if DEBUG
    return button.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      ImportRestoreButtonProbe.frame = $0
    }
    .onDisappear { ImportRestoreButtonProbe.frame = nil }
    #else
    return button
    #endif
  }

  @ViewBuilder
  private func leftBehind(_ colors: ImportColors, centered: Bool) -> some View {
    if !model.notes.isEmpty {
      Text(model.notes.joined(separator: " "))
        .font(.system(size: 12))
        .lineSpacing(2)
        .foregroundStyle(colors.textTertiary)
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    }
  }

  @ViewBuilder
  private func extensionList(_ colors: ImportColors) -> some View {
    if !model.extensions.list.isEmpty {
      VStack(spacing: 8) {
        Text(model.extensionsIntro)
          .font(.system(size: 12))
          .foregroundStyle(colors.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Text(model.extensions.list.map(\.name).joined(separator: ", "))
          .font(.system(size: 12))
          .foregroundStyle(colors.textPrimary)
          .multilineTextAlignment(.center)
          .lineLimit(3)
        if model.extensions.opened {
          Text(model.extensionsOpenedLine)
            .font(.system(size: 12))
            .foregroundStyle(colors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Button(model.openExtensionsTitle) { model.openInWebStore() }
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 14)
    }
  }
}

struct ImportTargetPicker: View {
  @Environment(\.colorScheme) private var scheme
  let model: ImportModel

  var body: some View {
    if model.targets.count > 1 {
      HStack(spacing: 8) {
        Text("Import into")
          .font(.system(size: 12))
          .lineLimit(1)
          .fixedSize()
          .foregroundStyle(ImportColors(scheme).textSecondary)
        Picker("", selection: Binding(get: { model.target }, set: { model.target = $0 })) {
          ForEach(model.targets) { target in
            Text(target.name).tag(target.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 130)
        .fixedSize()
      }
    }
  }
}

struct ImportStepFooter: View {
  let model: ImportModel

  var body: some View {
    switch model.step {
    case .loading:
      EmptyView()
    case .choose:
      if model.available {
        Button("Bookmarks HTML File…") { Task { await model.importHTML() } }
      }
      Spacer(minLength: 0)
      ImportTargetPicker(model: model)
      Button("Cancel") { model.close() }
      Button("Continue") { Task { await model.next() } }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canContinueChoose)
    case .profiles:
      Button("Back") { model.goBack(to: .choose) }
      Spacer(minLength: 0)
      ImportTargetPicker(model: model)
      Button("Continue") { Task { await model.next() } }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canContinueProfiles)
    case .unlock:
      Button("Back") { model.goBack(to: model.unlockBackStep) }
      Spacer(minLength: 0)
      Button("Skip Encrypted Data") { Task { await model.skipEncrypted() } }
      Button(model.unlocking ? "Waiting for password..." : "Continue") { Task { await model.unlock() } }
        .buttonStyle(.borderedProminent)
        .disabled(model.unlocking)
    case .safari:
      Button("Back") { model.goBack(to: .choose) }
      Spacer(minLength: 0)
      ImportTargetPicker(model: model)
      Button("Cancel") { model.close() }
    case .access:
      Button("Back") { model.goBack(to: .choose) }
      Spacer(minLength: 0)
      Button("Cancel") { model.close() }
    case .dia:
      Button("Back") { model.goBack(to: .choose) }
      Spacer(minLength: 0)
      ImportTargetPicker(model: model)
      Button("Cancel") { model.close() }
      if model.diaStatus == .notDetermined {
        Button(model.asking ? "Waiting for macOS..." : "Continue") { Task { await model.allowDia() } }
          .buttonStyle(.borderedProminent)
          .disabled(model.asking)
      }
    case .progress:
      Spacer(minLength: 0)
      Button("Cancel") { model.cancelProgress() }
    case .done:
      Spacer(minLength: 0)
      if !model.failures.isEmpty {
        Button("Try Again") { model.tryAgain() }
      }
      Button(model.failures.isEmpty ? "Finish importing" : "Continue") { model.close() }
        .buttonStyle(.borderedProminent)
    }
  }
}

struct ImportFlow: Layout {
  var spacing: CGFloat
  var lineSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        y += line + lineSpacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += line + lineSpacing
        x = bounds.minX
        line = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}
