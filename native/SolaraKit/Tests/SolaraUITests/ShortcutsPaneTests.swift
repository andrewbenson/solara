import AppKit
import SolaraModel
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeShortcutsServices: ShortcutsServices {
  var items: [MenuShortcutItem] = ShortcutsFixture.items
  var opened: [[String]] = []
  var loads = 0
  var changes: AsyncStream<Void>.Continuation?

  func menuShortcuts() async -> [MenuShortcutItem] {
    loads += 1
    return items
  }

  func menuShortcutChanges() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    changes = continuation
    return stream
  }

  func openURLs(_ urls: [String]) { opened.append(urls) }
}

@MainActor
final class FakeShortcutRecorder: ShortcutRecording {
  var next: KeyShortcut?
  var cancels = 0

  func record() async -> KeyShortcut? { next }
  func cancel() { cancels += 1 }
}

@MainActor
enum ShortcutsFixture {
  static func item(_ id: String, _ title: String, _ path: [String], _ key: String, _ modifiers: [ShortcutModifier], remappable: Bool = true, aliases: [[String]] = []) -> MenuShortcutItem {
    MenuShortcutItem(id: id, title: title, path: path, defaultShortcut: KeyShortcut(key: key, modifiers: modifiers), remappable: remappable, aliases: aliases)
  }

  static let items: [MenuShortcutItem] = [
    item("std:quit:", "Quit Solara", ["Solara"], "q", [.command]),
    item("std:hide:", "Hide Solara", ["Solara"], "h", [.command]),
    item("newTab", "New Tab", ["File"], "t", [.command]),
    item("newWindow", "New Window", ["File"], "n", [.command]),
    item("newIncognitoWindow", "New Incognito Window", ["File"], "n", [.command, .shift]),
    item("closeTab", "Close Tab", ["File"], "w", [.command]),
    item("std:copy:", "Copy", ["Edit"], "c", [.command]),
    item("copyUrl", "Copy URL", ["Edit"], "c", [.command, .shift]),
    item("system:Edit > Emoji & Symbols", "Emoji & Symbols", ["Edit"], " ", [.control, .command], remappable: false),
    item("nextTab", "Next Tab", ["View", "Tabs"], "}", [.command], aliases: [["\u{F703}", "command", "option"]]),
    item("toggleDevTools", "Developer Tools", ["View", "Developer"], "i", [.command, .option]),
    item("openSplitPane", "Open Split Pane", ["View"], "", []),
    item("std:toggleFullScreen:", "Enter Full Screen", ["Window"], "f", [.function]),
  ]
}

@MainActor
struct ShortcutsPaneTests {
  func model(overrides: ShortcutOverrides = [:]) async -> (ShortcutsPaneModel, FakeSettingsStore, FakeShortcutsServices, FakeShortcutRecorder) {
    let store = FakeSettingsStore()
    store.values["shortcuts"] = .object(JSONObject(overrides.map { ($0.key, JSONValue.array($0.value.map(JSONValue.string))) }))
    let services = FakeShortcutsServices()
    let recorder = FakeShortcutRecorder()
    let model = ShortcutsPaneModel(services: services, store: store, recorder: recorder)
    await model.prepare(SettingsPlace(pane: .shortcuts))
    return (model, store, services, recorder)
  }

  @Test func formatsShortcutsLikeTheMenus() {
    #expect(KeyShortcut(key: "t", modifiers: [.shift, .command]).formatted == "⇧⌘T")
    #expect(KeyShortcut(key: "\u{F708}", modifiers: []).formatted == "F5")
    #expect(KeyShortcut(key: "\u{F703}", modifiers: [.command, .option]).formatted == "⌥⌘→")
    #expect(KeyShortcut(key: " ", modifiers: [.command, .control]).formatted == "⌃⌘Space")
    #expect(KeyShortcut(key: "f", modifiers: [.function]).formatted == "🌐F")
    #expect(KeyShortcut(key: "\t", modifiers: [.control]).formatted == "⌃⇥")
    #expect(KeyShortcut.empty.formatted == "")
  }

  @Test func storedUppercaseKeysMeanShift() {
    let shortcut = KeyShortcut(stored: ["T", "command"])
    #expect(shortcut == KeyShortcut(key: "t", modifiers: [.shift, .command]))
    #expect(shortcut.same(as: KeyShortcut(key: "T", modifiers: [.command])))
    #expect(KeyShortcut(key: "k", modifiers: [.command, .option]).stored == ["k", "option", "command"])
  }

  @Test func anOverrideTakesItsComboFromTheDefaultHolder() async {
    let (model, _, _, _) = await model(overrides: ["newWindow": ["t", "command"]])
    let resolved = model.resolved(model.overrides)
    #expect(resolved.effective("newWindow") == KeyShortcut(key: "t", modifiers: [.command]))
    #expect(resolved.effective("newTab") == .empty)
    #expect(resolved.conflicts(of: "newWindow").isEmpty)
  }

  @Test func overridingOntoAFixedShortcutConflicts() async {
    let (model, _, _, _) = await model(overrides: ["newTab": [" ", "control", "command"]])
    let resolved = model.resolved(model.overrides)
    let newTab = ShortcutsFixture.items[2]
    let others = model.conflicts(of: newTab, in: resolved)
    #expect(others.map(\.title) == ["Emoji & Symbols"])
    #expect(ShortcutsPaneModel.conflictText(others) == "This shortcut conflicts with another shortcut: Emoji & Symbols")
    #expect(ShortcutsPaneModel.conflictText(others + others) == "This shortcut conflicts with other shortcuts: Emoji & Symbols, Emoji & Symbols")
    model.filter = .conflicts
    #expect(Set(model.shown(resolved, overrides: model.overrides).map(\.id)) == ["newTab", "system:Edit > Emoji & Symbols"])
  }

  @Test func aliasesBindAfterTheDefault() async {
    let (model, _, _, _) = await model()
    let resolved = model.resolved(model.overrides)
    #expect(resolved.bindings["nextTab"] == [KeyShortcut(key: "}", modifiers: [.command]), KeyShortcut(key: "\u{F703}", modifiers: [.option, .command])])
  }

  @Test func recordingTheDefaultRemovesTheOverride() async {
    let (model, store, _, recorder) = await model(overrides: ["newTab": ["y", "command"]])
    let newTab = ShortcutsFixture.items[2]
    recorder.next = KeyShortcut(key: "t", modifiers: [.command])
    await model.record(newTab)
    #expect(model.overrides["newTab"] == nil)
    #expect(model.recording == nil)
    recorder.next = KeyShortcut(key: "k", modifiers: [.command, .option])
    await model.record(newTab)
    #expect(model.overrides["newTab"] == ["k", "option", "command"])
    recorder.next = nil
    let before = store.patches.count
    await model.record(newTab)
    #expect(store.patches.count == before)
  }

  @Test func clearingKeepsAnEmptyOverrideOnlyWhenThereIsADefault() async {
    let (model, _, _, _) = await model(overrides: ["openSplitPane": ["p", "control"]])
    model.clear(ShortcutsFixture.items[2])
    #expect(model.overrides["newTab"] == [""])
    #expect(model.resolved(model.overrides).effective("newTab") == .empty)
    model.clear(ShortcutsFixture.items[11])
    #expect(model.overrides["openSplitPane"] == nil)
    model.resetAll()
    #expect(model.overrides.isEmpty)
  }

  @Test func filtersByQueryAndCustomization() async {
    let (model, _, _, _) = await model(overrides: ["closeTab": ["w", "control"]])
    let overrides = model.overrides
    let resolved = model.resolved(overrides)
    model.query = "tab new"
    #expect(model.shown(resolved, overrides: overrides).map(\.id) == ["newTab"])
    model.query = "⌃W"
    #expect(model.shown(resolved, overrides: overrides).map(\.id) == ["closeTab"])
    model.query = "developer"
    #expect(model.shown(resolved, overrides: overrides).map(\.id) == ["toggleDevTools"])
    model.query = ""
    model.filter = .customized
    #expect(model.shown(resolved, overrides: overrides).map(\.id) == ["closeTab"])
    model.filter = .all
    #expect(ShortcutsPaneModel.menus(of: model.shown(resolved, overrides: overrides)) == ["Solara", "File", "Edit", "View", "Window"])
    #expect(ShortcutsPaneModel.pathText(ShortcutsFixture.items[9]) == "Tabs")
    #expect(ShortcutsPaneModel.pathText(ShortcutsFixture.items[2]) == nil)
  }

  @Test func precedenceDefaultsComeFromTheMenuAndChoicesAreStoredOnlyWhenTheyDiffer() async {
    let store = FakeSettingsStore()
    store.values["shortcutPrecedence"] = .object(["findInPage": "solara", "nextTab": "sometimes"])
    let services = FakeShortcutsServices()
    let nextTab = MenuShortcutItem(id: "nextTab", title: "Next Tab", path: ["Tabs"], defaultShortcut: KeyShortcut(key: "}", modifiers: [.command]), remappable: true, defaultPrecedence: .solara)
    let find = MenuShortcutItem(id: "findInPage", title: "Find…", path: ["Edit"], defaultShortcut: KeyShortcut(key: "f", modifiers: [.command]), remappable: true, defaultPrecedence: .both)
    let quit = MenuShortcutItem(id: "std:quit:", title: "Quit", path: ["Solara"], defaultShortcut: KeyShortcut(key: "q", modifiers: [.command]), remappable: true, defaultPrecedence: .solara, precedenceFixed: true)
    let emoji = ShortcutsFixture.items[8]
    services.items = [nextTab, find, quit, emoji]
    let model = ShortcutsPaneModel(services: services, store: store, recorder: FakeShortcutRecorder())
    await model.prepare(SettingsPlace(pane: .shortcuts))

    #expect(model.precedences == ["findInPage": .solara])
    #expect(model.precedence(of: nextTab, in: model.precedences) == .solara)
    #expect(model.precedence(of: find, in: model.precedences) == .solara)
    #expect(model.precedence(of: emoji, in: model.precedences) == nil)
    model.setPrecedence(quit, .website)
    #expect(model.precedences["std:quit:"] == nil)
    store.values["shortcutPrecedence"] = .object(["findInPage": "solara", "std:quit:": "website"])
    #expect(model.precedence(of: quit, in: model.precedences) == .solara)
    store.values["shortcutPrecedence"] = .object(["findInPage": "solara"])

    model.filter = .customized
    let resolved = model.resolved(model.overrides)
    #expect(model.shown(resolved, overrides: model.overrides, precedences: model.precedences).map(\.id) == ["findInPage"])

    model.setPrecedence(nextTab, .website)
    #expect(model.precedences["nextTab"] == .website)
    model.setPrecedence(find, .both)
    #expect(model.precedences["findInPage"] == nil)
    model.reset(nextTab)
    #expect(model.precedences.isEmpty)

    model.setPrecedence(nextTab, .both)
    store.values["shortcuts"] = .object(["nextTab": ["k", "command"]])
    model.resetAll()
    #expect(model.precedences.isEmpty)
    #expect(model.overrides.isEmpty)
  }

  @Test func precedenceTitlesNameTheApp() {
    #expect(ShortcutPrecedence.solara.title(app: "Solara Dev") == "Prefer Solara Dev")
    #expect(ShortcutPrecedence.website.title(app: "Solara") == "Prefer Website")
    #expect(ShortcutPrecedence.both.title(app: "") == "Use Both")
  }

  @Test func readsKeysLikeTheShellRecorder() {
    #expect(ShortcutKeyReader.outcome(keyCode: 53, flags: [], characters: "\u{1b}") == .cancel)
    #expect(ShortcutKeyReader.outcome(keyCode: 53, flags: [.function], characters: "\u{1b}") == .cancel)
    #expect(ShortcutKeyReader.outcome(keyCode: 53, flags: [.command], characters: "\u{1b}") == .record(KeyShortcut(key: "\u{1b}", modifiers: [.command])))
    #expect(ShortcutKeyReader.outcome(keyCode: 0, flags: [], characters: "a") == .reject)
    #expect(ShortcutKeyReader.outcome(keyCode: 0, flags: [.shift, .option], characters: "a") == .reject)
    #expect(ShortcutKeyReader.outcome(keyCode: 0, flags: [.command, .shift], characters: "A") == .record(KeyShortcut(key: "a", modifiers: [.shift, .command])))
    #expect(ShortcutKeyReader.outcome(keyCode: 96, flags: [.function], characters: "\u{F708}") == .record(KeyShortcut(key: "\u{F708}", modifiers: [])))
    #expect(ShortcutKeyReader.outcome(keyCode: 124, flags: [.function, .command, .option], characters: "\u{F703}") == .record(KeyShortcut(key: "\u{F703}", modifiers: [.option, .command])))
    #expect(ShortcutKeyReader.outcome(keyCode: 3, flags: [.function, .control], characters: "f") == .record(KeyShortcut(key: "f", modifiers: [.control, .function])))
    #expect(ShortcutKeyReader.outcome(keyCode: 0, flags: [.command], characters: "") == .ignore)
  }

  @Test func readsMouseDownAsCancelAndPassesItOn() throws {
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    #expect(ShortcutKeyReader.outcome(event) == .cancelAndPass)
  }

  @Test func reloadsWhenTheMenuBarChanges() async throws {
    let (model, _, services, _) = await model()
    #expect(services.loads == 1)
    services.items = Array(ShortcutsFixture.items.prefix(2))
    services.changes?.yield()
    for _ in 0..<50 where model.items?.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.items?.count == 2)
  }

  @Test func editsExtensionShortcutsInChrome() async {
    let (model, _, services, recorder) = await model()
    model.services.openURLs([ShortcutsPaneModel.extensionShortcutsURL])
    #expect(services.opened == [["chrome://extensions/shortcuts"]])
    model.recording = "newTab"
    model.cancelRecording()
    #expect(recorder.cancels == 1)
    #expect(model.recording == nil)
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersShortcuts() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, store) = SettingsFixture.context()
    store.values["shortcuts"] = ["newTab": [" ", "control", "command"], "closeTab": ["w", "control", "command"], "newWindow": [""]]
    let model = ShortcutsPaneModel(services: FakeShortcutsServices(), store: store, recorder: FakeShortcutRecorder())
    context.panes[.shortcuts] = model
    await model.prepare(SettingsPlace(pane: .shortcuts))
    try await Snapshot.renderPanes(context, [.shortcuts])
    model.recording = "newWindow"
    for dark in [false, true] {
      let view = ShortcutsPane(model: model).environment(\.settingsContext, context)
      try await Snapshot.render(view, size: NSSize(width: 640, height: 900), dark: dark, to: directory.appendingPathComponent("shortcuts-recording-\(dark ? "dark" : "light").png"))
    }
    model.recording = nil
    model.query = "zzz"
    for dark in [false, true] {
      let view = ShortcutsPane(model: model).environment(\.settingsContext, context)
      try await Snapshot.render(view, size: NSSize(width: 640, height: 400), dark: dark, to: directory.appendingPathComponent("shortcuts-empty-\(dark ? "dark" : "light").png"))
    }
  }
}
