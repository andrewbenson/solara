import AppKit
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
enum FieldContentProbe {
  static let unfocused = NSTextContentType(rawValue: "probe.unfocused")

  static func window(_ content: NSView, size: NSSize = NSSize(width: 560, height: 640)) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    content.frame = NSRect(origin: .zero, size: size)
    window.contentView = content
    content.layoutSubtreeIfNeeded()
    return window
  }

  static func hosted(_ view: some View, size: NSSize = NSSize(width: 560, height: 640)) -> NSWindow {
    let host = NSHostingView(rootView: AnyView(view))
    let window = window(host, size: size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    return window
  }

  static func editableFields(_ view: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    if let field = view as? NSTextField, field.isEditable, !(field is NSSecureTextField) { found.append(field) }
    for child in view.subviews { found += editableFields(child) }
    return found
  }

  static func editorTypes(_ window: NSWindow) -> [String] {
    guard let root = window.contentView else { return [] }
    return editableFields(root).map { field in
      guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { return unfocused.rawValue }
      return (editor.contentType ?? NSTextContentType(rawValue: "")).rawValue
    }.sorted()
  }

  static func editorType(of field: NSTextField) -> String {
    let box = NSView()
    box.addSubview(field)
    field.frame = NSRect(x: 20, y: 20, width: 260, height: 24)
    let window = window(box)
    defer { window.close() }
    return editorTypes(window).first ?? unfocused.rawValue
  }
}

@MainActor
@Suite(.serialized) struct NativeFieldAutoFillTests {
  let plain = NSTextContentType.solaraPlainText.rawValue
  let url = NSTextContentType.URL.rawValue

  @Test func plainTextContentIsNotAnAutoFillCategory() {
    let filled: [NSTextContentType] = [.username, .password, .oneTimeCode, .name, .emailAddress, .telephoneNumber, .creditCardNumber, .URL]
    #expect(!NSTextContentType.solaraPlainText.rawValue.isEmpty)
    #expect(!filled.contains(.solaraPlainText))
  }

  @Test func findBarFieldsDeclarePlainText() {
    #expect(FindField().contentType == .solaraPlainText)
    #expect(FieldContentProbe.editorType(of: FindField()) == plain)
    let bar = FindBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 79))
    let fields = FieldContentProbe.editableFields(bar)
    #expect(fields.count == 2)
    #expect(fields.allSatisfy { $0 is FindField && $0.contentType == .solaraPlainText })
  }

  @Test func sidebarRenameFieldDeclaresPlainText() {
    let field = SidebarRenameField(initial: "Tab", placeholder: "Tab", font: .systemFont(ofSize: 13), color: .labelColor)
    #expect(field.contentType == .solaraPlainText)
    #expect(FieldContentProbe.editorType(of: field) == plain)
  }

  @Test func groupCardSearchFieldDeclaresPlainText() {
    #expect(GroupCardSearchField().contentType == .solaraPlainText)
    #expect(FieldContentProbe.editorType(of: GroupCardSearchField()) == plain)
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    #expect(FieldContentProbe.editableFields(card).map(\.contentType) == [.solaraPlainText])
  }

  @Test func iconPickerFieldDeclaresPlainText() {
    #expect(IconPickerField().contentType == .solaraPlainText)
    #expect(FieldContentProbe.editorType(of: IconPickerField()) == plain)
    #expect(SidebarIconPickerView(frame: .zero).field.contentType == .solaraPlainText)
  }

  @Test func tabSearchFieldDeclaresPlainText() {
    let panel = TabSearchPanelView(favicons: SidebarFavicons())
    let fields = FieldContentProbe.editableFields(panel)
    #expect(fields.count == 1)
    #expect(fields.first?.contentType == .solaraPlainText)
  }

  @Test func promptFieldDeclaresPlainTextAndKeepsItsValues() {
    let field = NSTextField.solaraPromptField(value: "Reading", placeholder: "Folder name")
    #expect(field.stringValue == "Reading")
    #expect(field.placeholderString == "Folder name")
    #expect(field.frame.size == NSSize(width: 260, height: 24))
    #expect(field.contentType == .solaraPlainText)
    #expect(FieldContentProbe.editorType(of: NSTextField.solaraPromptField()) == plain)
  }

  @Test func pageSearchFieldDeclaresPlainText() {
    let window = FieldContentProbe.hosted(PageSearchField(text: .constant(""), placeholder: "Search Bookmarks"))
    defer { window.close() }
    #expect(FieldContentProbe.editorTypes(window) == [plain])
  }

  @Test func bookmarkFormNamesArePlainTextAndAddressesAreURLs() {
    let model = BookmarkFormModel()
    model.kind = .addBookmark
    let bookmark = FieldContentProbe.hosted(BookmarkFormPanel(model: model, width: 420))
    defer { bookmark.close() }
    #expect(FieldContentProbe.editorTypes(bookmark) == [url, plain].sorted())
    let folderModel = BookmarkFormModel()
    folderModel.kind = .newFolder
    let folder = FieldContentProbe.hosted(BookmarkFormPanel(model: folderModel, width: 420))
    defer { folder.close() }
    #expect(FieldContentProbe.editorTypes(folder) == [plain])
  }

  @Test func autofillSheetsDeclarePlainText() {
    let (model, _, context) = AutofillPaneTests.fixture()
    let address = FieldContentProbe.hosted(AutofillAddressSheet(model: model, profile: "default", saved: nil).environment(\.settingsContext, context), size: NSSize(width: 560, height: 760))
    defer { address.close() }
    let addressTypes = FieldContentProbe.editorTypes(address)
    #expect(addressTypes.count == AutofillAddressField.allCases.count)
    #expect(addressTypes.allSatisfy { $0 == plain })
    let card = FieldContentProbe.hosted(AutofillCardSheet(model: model, profile: "default", saved: nil).environment(\.settingsContext, context))
    defer { card.close() }
    #expect(FieldContentProbe.editorTypes(card) == [plain, plain])
  }

  @Test func passwordUsernameDeclaresPlainTextAndThePasswordStaysSecure() throws {
    let (model, services, _, context) = PasswordsPaneTests.fixture()
    let saved = try #require(services.saved["default"]?.first)
    let window = FieldContentProbe.hosted(PasswordDetailSheet(model: model, profile: "default", saved: saved, editing: true).environment(\.settingsContext, context))
    defer { window.close() }
    #expect(FieldContentProbe.editorTypes(window) == [plain])
  }

  @Test func profileNameFieldsDeclarePlainText() async {
    let store = FakeSettingsStore()
    let model = ProfilesPaneModel(services: FakeProfilesServices(store: store, profiles: ProfilesFixture.profiles), store: store)
    await model.prepare(SettingsPlace(pane: .profiles, profileId: "default"))
    let (context, _) = SettingsFixture.context()
    let details = FieldContentProbe.hosted(ProfileDetailsPane(model: model, profileId: "default").environment(\.settingsContext, context))
    defer { details.close() }
    #expect(FieldContentProbe.editorTypes(details) == [plain])
    let create = FieldContentProbe.hosted(CreateProfileSheet(model: model) {}.environment(\.settingsContext, context))
    defer { create.close() }
    #expect(FieldContentProbe.editorTypes(create) == [plain])
  }

  @Test func syncPairingNameDeclaresPlainText() {
    let service = TrustedPairingTestService()
    let model = SyncTrustedPairingModel(service: service, now: { service.clock })
    let window = FieldContentProbe.hosted(SyncPairingNameRepairView(model: model))
    defer { window.close() }
    #expect(FieldContentProbe.editorTypes(window) == [plain])
  }

  @Test func liveFolderClientIdsDeclarePlainTextAndSecretsStaySecure() async {
    let (context, model, _) = await LiveFoldersPaneTests.loaded()
    let github = FieldContentProbe.hosted(LiveFoldersGithubConnect(model: model, runner: LiveFoldersConnectRun(), appName: "Solara", clientId: "Iv1.abc").environment(\.settingsContext, context))
    defer { github.close() }
    #expect(FieldContentProbe.editorTypes(github) == [plain])
    let google = FieldContentProbe.hosted(LiveFoldersGoogleConnect(model: model, runner: LiveFoldersConnectRun(), appName: "Solara", clientId: "id.apps.googleusercontent.com").environment(\.settingsContext, context))
    defer { google.close() }
    #expect(FieldContentProbe.editorTypes(google) == [plain])
  }

  @Test func searchEngineSheetsDeclareNamesAsPlainTextAndAddressesAsURLs() {
    let store = FakeSettingsStore()
    let engines = FieldContentProbe.hosted(EngineSheet(model: SearchEnginePaneModel(services: FakeSearchEngineServices(), store: store), engine: nil) {})
    defer { engines.close() }
    #expect(FieldContentProbe.editorTypes(engines) == [url, plain, plain].sorted())
    let rules = FieldContentProbe.hosted(RuleSheet(model: EnginesPaneModel(services: FakeEnginesServices(store: store), store: store), site: nil, initialEngine: "webkit") {})
    defer { rules.close() }
    #expect(FieldContentProbe.editorTypes(rules) == [url])
  }

  @Test func siteAndStoreLinkFieldsDeclareURLs() async {
    let store = FakeSettingsStore()
    let keepAwake = FieldContentProbe.hosted(KeepAwakeSiteSheet(store: store) { _ in })
    defer { keepAwake.close() }
    #expect(FieldContentProbe.editorTypes(keepAwake) == [url])
    let model = ExtensionsPaneModel(services: FakeExtensionsServices(), store: store)
    await model.prepare(SettingsPlace(pane: .extensions, profileId: "default"))
    let (context, _) = SettingsFixture.context()
    let extensions = FieldContentProbe.hosted(ExtensionsList(model: model, profileId: "default", profile: "default").environment(\.settingsContext, context))
    defer { extensions.close() }
    #expect(FieldContentProbe.editorTypes(extensions) == [url])
  }
}

struct TextFieldContentTypeGuardTests {
  struct Site: Hashable, CustomStringConvertible {
    let file: String
    let line: Int
    let text: String
    var description: String { "\(file):\(line): \(text)" }
  }

  struct Exemption {
    let file: String
    let text: String
    let reason: String
  }

  static let exemptions = [
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/LiveFoldersConnectSheet.swift", text: #"SecureField("", text: $token, prompt: Text(verbatim: "ghp_…"))"#, reason: "secure"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/LiveFoldersConnectSheet.swift", text: #"SecureField("", text: $token, prompt: Text(verbatim: "ntn_…"))"#, reason: "secure"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/LiveFoldersConnectSheet.swift", text: #"SecureField("", text: $secret)"#, reason: "secure"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/PasswordsDetailSheet.swift", text: #"TextField("", text: passwordBinding)"#, reason: "secure: the revealed password"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/PasswordsDetailSheet.swift", text: #"SecureField("", text: passwordBinding)"#, reason: "secure"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/PasswordsPane.swift", text: "let field = NSSearchField()", reason: "search"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/ProfileIconPopover.swift", text: "private let search = NSSearchField()", reason: "search"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/Panes/ShortcutsPane.swift", text: "let field = NSSearchField()", reason: "search"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Settings/SettingsSearchField.swift", text: "let field = NSSearchField()", reason: "search"),
    Exemption(file: "native/SolaraKit/Sources/SolaraUI/Sidebar/SidebarPrimitives.swift", text: "class FadeLabel: NSTextField", reason: "read-only"),
    Exemption(file: "packages/settings/ios/Hosted/HostedModule.swift", text: #"let field = NSTextField(string: "")"#, reason: "debug"),
    Exemption(file: "packages/settings/ios/SettingsDev.swift", text: #"SecureField("", text: .constant(""))"#, reason: "debug"),
    Exemption(file: "packages/settings/ios/SettingsDev.swift", text: "NSSecureTextField(frame:", reason: "debug"),
    Exemption(file: "packages/solaracore/ios/WebKitTab.swift", text: "let field = NSTextField(frame:", reason: "WebKit prompt(): a page's input keeps the system offer"),
  ]

  static var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  static func sources() throws -> [(String, String)] {
    let manager = FileManager.default
    var dirs = [root.appendingPathComponent("native/SolaraKit/Sources")]
    let packages = root.appendingPathComponent("packages")
    for name in try manager.contentsOfDirectory(atPath: packages.path).sorted() {
      let ios = packages.appendingPathComponent(name).appendingPathComponent("ios")
      if manager.fileExists(atPath: ios.path) { dirs.append(ios) }
    }
    var files: [(String, String)] = []
    for dir in dirs {
      guard let walk = manager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
      for case let url as URL in walk where url.pathExtension == "swift" {
        let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        files.append((relative, try String(contentsOf: url, encoding: .utf8)))
      }
    }
    return files.sorted { $0.0 < $1.0 }
  }

  static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  }

  static func uncovered() throws -> [Site] {
    var sites: [Site] = []
    for (file, text) in try sources() {
      let lines = text.components(separatedBy: "\n")
      for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
        for match in matches(#"class\s+\w+\s*:\s*(NSTextField|NSSecureTextField|NSSearchField|NSTokenField|NSComboBox)\b"#, line) {
          let rest = lines[index...].joined(separator: "\n")
          let body = rest.range(of: "\n}\n").map { String(rest[..<$0.lowerBound]) } ?? rest
          if !body.contains("contentType =") { sites.append(Site(file: file, line: index + 1, text: (line as NSString).substring(with: match.range))) }
        }
        for match in matches(#"(?<![A-Za-z])(NSTextField|NSSecureTextField|NSSearchField|NSTokenField|NSComboBox|TextField|SecureField)\("#, line) {
          let start = line.index(line.startIndex, offsetBy: match.range.location)
          let tail = String(line[start...])
          if tail.range(of: #"^NSTextField\((labelWithString|wrappingLabelWithString|labelWithAttributedString)"#, options: .regularExpression) != nil { continue }
          let kind = (line as NSString).substring(with: match.range(at: 1))
          var covered = line.contains("solaraPromptField")
          if kind == "TextField" || kind == "SecureField" {
            let following = lines[(index + 1)..<min(lines.count, index + 9)]
            for next in following {
              if next.contains(".textContentType(") { covered = true; break }
              if next.range(of: #"(?<![A-Za-z])(TextField|SecureField)\("#, options: .regularExpression) != nil { break }
            }
          } else {
            let window = lines[index..<min(lines.count, index + 9)].joined(separator: "\n")
            if window.contains("contentType =") { covered = true }
            if let name = matches(#"(?:let|var)\s+(\w+)\s*=\s*"# + kind, line).first.map({ (line as NSString).substring(with: $0.range(at: 1)) }),
              !matches(#"\b"# + name + #"\.contentType\s*="#, text).isEmpty {
              covered = true
            }
          }
          if !covered { sites.append(Site(file: file, line: index + 1, text: line.trimmingCharacters(in: .whitespaces))) }
        }
      }
    }
    return sites
  }

  @Test func everyEditableTextFieldDeclaresAContentTypeOrIsExempt() throws {
    let sites = try Self.uncovered()
    let missing = sites.filter { site in !Self.exemptions.contains { site.file == $0.file && site.text.contains($0.text) } }
    #expect(missing.isEmpty, "Set contentType (NSTextField.solaraPromptField, .textContentType(.solaraPlainText) or .URL), or add an exemption: \(missing)")
    let unused = Self.exemptions.filter { exemption in !sites.contains { $0.file == exemption.file && $0.text.contains(exemption.text) } }
    #expect(unused.isEmpty, "Exemptions that match no field any more: \(unused.map { "\($0.file): \($0.text)" })")
  }

  @Test func theGuardSeesFieldsInBothTrees() throws {
    let files = try Self.sources().map(\.0)
    #expect(files.contains("native/SolaraKit/Sources/SolaraUI/Find/FindBarView.swift"))
    #expect(files.contains("packages/shell/ios/ShellModule.swift"))
    #expect(Self.exemptions.allSatisfy { exemption in files.contains(exemption.file) })
  }
}
