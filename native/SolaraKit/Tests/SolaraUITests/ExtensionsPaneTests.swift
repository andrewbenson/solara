import AppKit
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeExtensionsServices: ExtensionsServices {
  var focusedWindowProfileId: String?
  var ownershipGeneration: Int? = 0
  var onList: (() -> Void)?
  var onInstall: (() -> Void)?
  var lists: [String: [InstalledExtension]] = ["default": ExtensionsFixture.installed, "work": []]
  var calls: [String] = []
  var folder: String? = "/Users/owner/Code/tab-notes"
  var package: Result<ExtensionPackage, ExtensionServiceError> = .success(ExtensionsFixture.package)
  var installError: ExtensionServiceError?
  var configureError: ExtensionServiceError?
  var changes: AsyncStream<ExtensionsChange>.Continuation?

  func listExtensions(profile: String) async throws -> [InstalledExtension] {
    calls.append("list \(profile)")
    onList?()
    return lists[profile] ?? []
  }

  func setExtensionEnabled(_ id: String, enabled: Bool, profile: String) async throws {
    calls.append("setEnabled \(id) \(enabled) \(profile)")
    if let index = lists[profile]?.firstIndex(where: { $0.id == id }) { lists[profile]?[index].enabled = enabled }
  }

  func uninstallExtension(_ id: String, profile: String) async throws {
    calls.append("uninstall \(id) \(profile)")
    lists[profile]?.removeAll { $0.id == id }
  }

  func reloadExtension(_ id: String, profile: String) async throws { calls.append("reload \(id) \(profile)") }

  func configureExtension(_ id: String, profile: String, options: ExtensionConfiguration) async throws {
    calls.append("configure \(id) \(profile) pinned=\(options.pinned.map(String.init) ?? "-") incognito=\(options.incognito.map(String.init) ?? "-") siteAccess=\(options.siteAccess?.rawValue ?? "-")")
    if let configureError { throw configureError }
  }

  func chooseExtensionFolder() async -> String? { folder }

  func inspectUnpackedExtension(path: String) async throws -> ExtensionPackage {
    calls.append("inspect \(path)")
    return try package.get()
  }

  func installExtension(path: String, profile: String) async throws {
    calls.append("install \(path) \(profile)")
    onInstall?()
    if let installError { throw installError }
  }

  func extensionChanges() -> AsyncStream<ExtensionsChange> {
    let (stream, continuation) = AsyncStream<ExtensionsChange>.makeStream()
    changes = continuation
    return stream
  }

  func openWebStoreDetail(_ url: String, profile: String) { calls.append("store \(url) \(profile)") }
  func openInNewTab(_ url: String) { calls.append("tab \(url)") }
}

@MainActor
enum ExtensionsFixture {
  static func icon(_ color: NSColor, symbol: String) -> String {
    let size = NSSize(width: 64, height: 64)
    let image = NSImage(size: size, flipped: false) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
      if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 30, weight: .semibold).applying(.init(paletteColors: [.white]))) {
        let glyphSize = glyph.size
        glyph.draw(in: NSRect(x: (rect.width - glyphSize.width) / 2, y: (rect.height - glyphSize.height) / 2, width: glyphSize.width, height: glyphSize.height))
      }
      return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
    return "data:image/png;base64," + png.base64EncodedString()
  }

  static let installed: [InstalledExtension] = [
    InstalledExtension(
      id: "cjpalhdlnbpafiamejdnhcphjbkeiagm",
      name: "uBlock Origin",
      version: "1.62.0",
      description: "Finally, an efficient blocker. Easy on CPU and memory.",
      icon: icon(.systemRed, symbol: "shield.fill"),
      permissions: ["Read and change all your data on all websites", "Manage your downloads"],
      siteAccess: .allSites,
      optionsUrl: "chrome-extension://cjpalhdlnbpafiamejdnhcphjbkeiagm/dashboard.html",
      pinned: true,
      webStoreUrl: "https://chromewebstore.google.com/detail/cjpalhdlnbpafiamejdnhcphjbkeiagm"
    ),
    InstalledExtension(
      id: "nngceckbapebfimnlniiiahkandclblb",
      name: "Bitwarden Password Manager",
      version: "2025.9.1",
      description: "At home, at work, or on the go, Bitwarden easily secures all your passwords.",
      icon: icon(.systemBlue, symbol: "lock.fill"),
      permissions: ["Read and modify data you copy and paste"],
      siteAccess: .onClick,
      incognito: true,
      webStoreUrl: "https://chromewebstore.google.com/detail/nngceckbapebfimnlniiiahkandclblb"
    ),
    InstalledExtension(
      id: "abcdefghijklmnopabcdefghijklmnop",
      name: "Tab Notes",
      version: "0.4.2",
      description: "Sticky notes for each tab.",
      enabled: false,
      icon: "",
      errors: ["Manifest key 'background.persistent' is not supported.", "Could not load icon 'icon128.png'."],
      path: "/Users/owner/Code/tab-notes",
      fromWebStore: false
    ),
  ]

  static let package = ExtensionPackage(
    name: "Tab Notes",
    version: "0.4.2",
    icon: icon(.systemOrange, symbol: "note.text"),
    permissions: ["tabs", "storage", "clipboardRead", "clipboardWrite"],
    hostPermissions: ["https://*.github.com/*"],
    path: "/Users/owner/Code/tab-notes"
  )
}

@MainActor
struct ExtensionsPaneTests {
  func model(focused: String? = nil) async -> (ExtensionsPaneModel, FakeSettingsStore, FakeExtensionsServices) {
    let store = FakeSettingsStore()
    let services = FakeExtensionsServices()
    services.focusedWindowProfileId = focused
    let model = ExtensionsPaneModel(services: services, store: store)
    await model.prepare(SettingsPlace(pane: .extensions, profileId: "default"))
    return (model, store, services)
  }

  @Test func resolvesTheProfileFromThePlaceThenTheFocusedWindowThenTheDefault() async {
    let (model, _, services) = await model(focused: "work")
    #expect(model.profileId(for: SettingsPlace(pane: .extensions, profileId: "default")) == "default")
    #expect(model.profileId(for: SettingsPlace(pane: .extensions)) == "work")
    #expect(model.profileId(for: SettingsPlace(pane: .extensions, profileId: "gone")) == "work")
    services.focusedWindowProfileId = nil
    #expect(model.profileId(for: SettingsPlace(pane: .extensions)) == "default")
  }

  @Test func sortsTheListByNameIgnoringCase() async {
    let (model, _, _) = await model()
    #expect(model.lists["default"]?.map(\.name) == ["Bitwarden Password Manager", "Tab Notes", "uBlock Origin"])
    #expect(model.isLoaded(SettingsPlace(pane: .extensions, profileId: "default")))
    #expect(!model.isLoaded(SettingsPlace(pane: .extensions, profileId: "work")))
  }

  @Test func readsWebStoreLinks() {
    let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    #expect(ExtensionWebStore.extensionId(id) == id)
    #expect(ExtensionWebStore.extensionId("  \(id)\n") == id)
    #expect(ExtensionWebStore.extensionId("https://chromewebstore.google.com/detail/ublock-origin/\(id)") == id)
    #expect(ExtensionWebStore.extensionId("https://chromewebstore.google.com/detail/\(id)?hl=en") == id)
    #expect(ExtensionWebStore.extensionId("https://chrome.google.com/webstore/detail/ublock/\(id)") == id)
    #expect(ExtensionWebStore.extensionId("https://chrome.google.com/extensions/\(id)") == nil)
    #expect(ExtensionWebStore.extensionId("https://example.com/\(id)") == nil)
    #expect(ExtensionWebStore.extensionId("chromewebstore.google.com/detail/\(id)") == nil)
    #expect(ExtensionWebStore.extensionId("ublock origin") == nil)
    #expect(ExtensionWebStore.extensionId("cjpalhdlnbpafiamejdnhcphjbkeiagz") == nil)
  }

  @Test func warnsAboutPermissionsLikeChrome() {
    func warnings(_ permissions: [String], _ hosts: [String] = []) -> [String] {
      ExtensionPermissions.warnings(ExtensionPackage(name: "x", version: "1", permissions: permissions, hostPermissions: hosts, path: ""))
    }
    #expect(warnings([]) == [])
    #expect(warnings(["storage"], ["<all_urls>"]) == ["Read and change all your data on all websites"])
    #expect(warnings(["tabs"], ["https://*.github.com/*"]) == ["Read and change your data on all github.com sites", "Read your browsing history"])
    #expect(warnings([], ["https://a.com/*", "https://b.com/*"]) == ["Read and change your data on a.com and b.com"])
    #expect(warnings([], ["https://a.com/*", "https://b.com/*", "https://c.com/*"]) == ["Read and change your data on a.com, b.com, and c.com"])
    #expect(warnings([], ["https://a.com/*", "https://b.com/*", "https://c.com/*", "https://d.com/*"]) == ["Read and change your data on a number of websites"])
    #expect(warnings([], ["chrome://favicon/*"]) == [])
    #expect(warnings(["clipboardRead", "clipboardWrite", "notifications"]) == ["Read and modify data you copy and paste", "Display notifications"])
    #expect(warnings(["clipboardWrite"]) == ["Modify data you copy and paste"])
    #expect(warnings(["declarativeNetRequest"]) == ["Block content on any page"])
    #expect(warnings(["history", "tabs"]) == ["Read and change your browsing history on all your signed-in devices"])
    #expect(warnings(["debugger", "tabs"]) == ["Read and change all your data on all websites"])
  }

  @Test func anInvalidLinkShowsTheErrorSheetAndAValidOneOpensTheStore() async {
    let (model, _, services) = await model()
    model.addFromLink("not a link", profile: "work")
    #expect(model.install?.status == .error("That isn't a link to an extension in the Chrome Web Store."))
    model.cancelInstall()
    model.addFromLink(" cjpalhdlnbpafiamejdnhcphjbkeiagm ", profile: "work")
    #expect(model.install == nil)
    #expect(services.calls.last == "store https://chromewebstore.google.com/detail/cjpalhdlnbpafiamejdnhcphjbkeiagm work")
    model.openWebStore()
    #expect(services.calls.last == "tab https://chromewebstore.google.com/category/extensions")
  }

  @Test func loadsAnUnpackedFolderAndInstallsIt() async {
    let (model, _, services) = await model()
    await model.loadUnpacked(profile: "default")
    let request = model.install
    #expect(request?.status == .ready)
    #expect(request?.title == "Add “Tab Notes”?")
    #expect(request?.warnings == ["Read and change your data on all github.com sites", "Read and modify data you copy and paste", "Read your browsing history"])
    await model.confirmInstall()
    #expect(model.install == nil)
    #expect(services.calls.suffix(2) == ["install /Users/owner/Code/tab-notes default", "list default"])
  }

  @Test func aFailedInstallShowsItsError() async {
    let (model, _, services) = await model()
    services.installError = ExtensionServiceError("Manifest file is missing or unreadable")
    await model.loadUnpacked(profile: "default")
    await model.confirmInstall()
    #expect(model.install?.status == .error("Manifest file is missing or unreadable"))
    services.package = .failure(ExtensionServiceError("Not a folder"))
    await model.loadUnpacked(profile: "default")
    #expect(model.install?.status == .error("Not a folder"))
    #expect(model.install?.source == .unpacked)
    services.folder = nil
    model.cancelInstall()
    await model.loadUnpacked(profile: "default")
    #expect(model.install == nil)
  }

  @Test func anInstallCallbackFromTheOldOwnerDoesNotRefreshOrShowItsError() async {
    let (model, _, services) = await model()
    await model.loadUnpacked(profile: "default")
    services.calls = []
    services.installError = ExtensionServiceError("Old install failed")
    services.onInstall = {
      services.ownershipGeneration = 1
    }
    await model.confirmInstall()
    #expect(services.calls == ["install /Users/owner/Code/tab-notes default"])
    #expect(model.install == nil)
    #expect(!model.isLoaded(SettingsPlace(pane: .extensions, profileId: "default")))
    services.onInstall = nil
  }

  @Test func aListFromTheOldOwnerDoesNotPopulateTheNewOwnersPane() async {
    let (model, _, services) = await model()
    let place = SettingsPlace(pane: .extensions, profileId: "work")
    services.lists["work"] = ExtensionsFixture.installed
    services.onList = {
      services.ownershipGeneration = 1
    }
    await model.prepare(place)
    #expect(!model.isLoaded(place))
    services.onList = nil
    services.lists["work"] = []
    await model.prepare(place)
    #expect(model.isLoaded(place))
    #expect(model.lists["work"] == [])
  }

  @Test func aRemovalConfirmationFromTheOldOwnerDoesNotUninstall() async {
    let (model, _, services) = await model()
    model.requestRemoval(ExtensionsFixture.installed[0], profile: "default")
    services.calls = []
    services.ownershipGeneration = 1
    await model.confirmRemoval()
    #expect(services.calls.isEmpty)
    #expect(model.removal == nil)
  }

  @Test func togglingPatchesAtOnceThenRefreshes() async {
    let (model, _, services) = await model()
    services.calls = []
    await model.setEnabled("default", "abcdefghijklmnopabcdefghijklmnop", true)
    #expect(services.calls == ["setEnabled abcdefghijklmnopabcdefghijklmnop true default", "list default"])
    #expect(model.lists["default"]?.first { $0.name == "Tab Notes" }?.enabled == true)
    services.calls = []
    await model.setPinned("default", "nngceckbapebfimnlniiiahkandclblb", true)
    #expect(services.calls == ["configure nngceckbapebfimnlniiiahkandclblb default pinned=true incognito=- siteAccess=-"])
    #expect(model.lists["default"]?.first { $0.name.hasPrefix("Bitwarden") }?.pinned == true)
    services.configureError = ExtensionServiceError("no")
    services.calls = []
    await model.setPinned("default", "nngceckbapebfimnlniiiahkandclblb", false)
    #expect(services.calls.last == "list default")
    #expect(model.lists["default"]?.first { $0.name.hasPrefix("Bitwarden") }?.pinned == false)
    services.configureError = nil
    services.calls = []
    await model.configure("default", "nngceckbapebfimnlniiiahkandclblb", ExtensionConfiguration(siteAccess: .specificSites))
    #expect(services.calls == ["configure nngceckbapebfimnlniiiahkandclblb default pinned=- incognito=- siteAccess=specificSites", "list default"])
    services.calls = []
    await model.reload("default", "abcdefghijklmnopabcdefghijklmnop")
    #expect(services.calls == ["reload abcdefghijklmnopabcdefghijklmnop default", "list default"])
  }

  @Test func removingAsksFirstThenUninstallsTheSelectedProfile() async {
    let (model, _, services) = await model()
    let ext = ExtensionsFixture.installed[0]
    model.requestRemoval(ext, profile: "default")
    #expect(model.removal?.title == "Remove “uBlock Origin”?")
    #expect(model.removal?.message == "Its data and settings will be removed too.")
    #expect(ExtensionRemoval(profile: "default", ext: ExtensionsFixture.installed[2]).message == "The extension's folder stays on your Mac.")
    services.calls = []
    await model.confirmRemoval()
    #expect(services.calls == ["uninstall cjpalhdlnbpafiamejdnhcphjbkeiagm default", "list default"])
    #expect(model.lists["default"]?.count == 2)
    #expect(model.removal == nil)
  }

  @Test func refreshesWhenTheEngineReportsAChange() async throws {
    let (model, _, services) = await model()
    services.lists["default"] = [ExtensionsFixture.installed[1]]
    services.changes?.yield(ExtensionsChange(profile: "default", id: "x", event: .uninstalled))
    for _ in 0..<50 where model.lists["default"]?.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.lists["default"]?.count == 1)
  }

  @Test func concurrentRefreshesShareOneListCall() async {
    let (model, _, services) = await model()
    services.calls = []
    async let first = model.refresh("default")
    async let second = model.refresh("default")
    _ = await (first, second)
    #expect(services.calls == ["list default"])
  }

  @Test func detailShowsOnlyForItsOwnProfileAndAMissingOneIsGone() async {
    let (model, _, _) = await model()
    let ublock = SettingsPlace(pane: .extensions, profileId: "default", detail: "cjpalhdlnbpafiamejdnhcphjbkeiagm")
    #expect(model.selected(ublock)?.name == "uBlock Origin")
    #expect(!model.isGone(ublock))
    let missing = SettingsPlace(pane: .extensions, profileId: "default", detail: "ppppppppppppppppppppppppppppppp")
    #expect(model.selected(missing) == nil)
    #expect(model.isGone(missing))
    let unresolved = SettingsPlace(pane: .extensions, detail: "cjpalhdlnbpafiamejdnhcphjbkeiagm")
    #expect(model.selected(unresolved) == nil)
    #expect(model.isGone(unresolved))
  }

  @Test func openingAndLeavingADetailWalksTheHistory() async {
    let (model, _, _) = await model()
    let navigation = SettingsNavigation(place: SettingsPlace(pane: .extensions))
    let ext = ExtensionsFixture.installed[0]
    model.openDetail(ext, profileId: "default", navigation: navigation)
    #expect(navigation.place == SettingsPlace(pane: .extensions, profileId: "default", detail: ext.id))
    #expect(navigation.back == [SettingsPlace(pane: .extensions, profileId: "default")])
    model.showList(profileId: "default", navigation: navigation)
    #expect(navigation.place == SettingsPlace(pane: .extensions, profileId: "default"))
    #expect(navigation.canGoForward)
    let direct = SettingsNavigation(place: SettingsPlace(pane: .extensions, profileId: "default", detail: ext.id))
    model.showList(profileId: "default", navigation: direct)
    #expect(direct.place == SettingsPlace(pane: .extensions, profileId: "default"))
    #expect(direct.back.count == 1)
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersExtensions() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, store) = SettingsFixture.context()
    let services = FakeExtensionsServices()
    let model = ExtensionsPaneModel(services: services, store: store)
    context.panes[.extensions] = model
    for profile in ["default", "work"] { await model.prepare(SettingsPlace(pane: .extensions, profileId: profile)) }
    let places = [
      SettingsPlace(pane: .extensions, profileId: "work"),
      SettingsPlace(pane: .extensions, profileId: "default", detail: "cjpalhdlnbpafiamejdnhcphjbkeiagm"),
      SettingsPlace(pane: .extensions, profileId: "default", detail: "abcdefghijklmnopabcdefghijklmnop"),
    ]
    try await Snapshot.renderPanes(context, [.extensions], places: places) { place in
      ["extensions", place.detail == nil ? place.profileId : place.detail.map { String($0.prefix(6)) }].compactMap { $0 }.joined(separator: "-")
    }
    await model.loadUnpacked(profile: "default")
    let ready = try #require(model.install)
    let invalid = ExtensionInstallRequest(profile: "default", source: .webStore, status: .error(ExtensionWebStore.invalidLinkMessage), package: nil)
    for (name, request) in [("ready", ready), ("error", invalid)] {
      for dark in [false, true] {
        let view = ExtensionInstallSheet(model: model, request: request).environment(\.settingsContext, context)
        try await Snapshot.render(view, size: NSSize(width: 400, height: 280), dark: dark, to: directory.appendingPathComponent("extensions-install-\(name)-\(dark ? "dark" : "light").png"))
      }
    }
  }
}
