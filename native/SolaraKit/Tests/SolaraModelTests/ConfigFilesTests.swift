import Foundation
@testable import SolaraModel
import Testing

func configReader(_ files: [String: String]) -> (String) -> ConfigRead {
  { name in files[name].map { .contents(Data($0.utf8)) } ?? .absent }
}

@Suite struct ConfigFileParseTests {
  @Test func absentFileMeansNoConfig() {
    let load = ConfigFile.load(configReader([:]))
    #expect(load.good)
    #expect(load.contents == nil)
  }

  @Test func settingsKeybindingsAndThemesParse() throws {
    let load = ConfigFile.load(configReader([
      "config.json": """
        {
          "settings": { "sidebarWidth": 240, "showTabNumberHints": false, "appearance": "dark" },
          "keybindings": { "newTab": "cmd+shift+y", "closeTab": "⌥⌘W", "reload": "", "find": ["f", "command"] },
          "theme": "ocean",
          "profiles": { "Work": { "theme": "forest" } }
        }
        """,
      "themes/ocean.json": ##"{ "colors": ["#3366FF", "#00CCAA"], "angle": 90, "grain": 0.2 }"##,
      "themes/forest.json": ##"{ "mode": "dark", "colors": ["#228833"], "dark": { "colors": ["#114411"] } }"##,
    ]))
    #expect(load.problems == [])
    let contents = try #require(load.contents)
    #expect(contents.settings["sidebarWidth"] == 240)
    #expect(contents.settings["showTabNumberHints"] == false)
    #expect(contents.keybindings["newTab"] == ["y", "shift", "command"])
    #expect(contents.keybindings["closeTab"] == ["w", "option", "command"])
    #expect(contents.keybindings["reload"] == [""])
    #expect(contents.keybindings["find"] == ["f", "command"])
    #expect(contents.theme?.name == "ocean")
    #expect(contents.theme?.look["stops"]?.array?.count == 2)
    #expect(contents.theme?.look["angle"] == 90)
    #expect(contents.theme?.look["mode"] == "auto")
    #expect(contents.theme?.look["texture"] == "grain")
    #expect(contents.profileThemes["Work"]?.look["dark"]?["stops"]?.array?.count == 1)
    let work = Profile(id: "p1", name: "work", color: "blue", icon: nil, createdAt: 0)
    let personal = Profile(id: "default", name: "Personal", color: "plum", icon: nil, createdAt: 0)
    #expect(contents.theme(for: work)?.name == "forest")
    #expect(contents.theme(for: personal)?.name == "ocean")
  }

  @Test func invalidJSONNamesTheLine() {
    let load = ConfigFile.load(configReader(["config.json": "{\n  \"settings\": {\n    \"sidebarWidth\": 240,\n  }\n}"]))
    #expect(!load.good)
    #expect(load.contents == nil)
    #expect(load.problems.first?.line == 4)
    #expect(load.problems.first?.message.hasPrefix("isn't valid JSON") == true)
  }

  @Test func wrongTypesUnknownAndRefusedKeysAreNamed() {
    let load = ConfigFile.load(configReader([
      "config.json": """
        {
          "settings": {
            "sidebarWidth": "wide",
            "SHOWFULLURL": true,
            "cliControl": true,
            "tabLayout": "bottom"
          },
          "keybindings": { "newTab": "t" },
          "colour": 1
        }
        """,
    ]))
    #expect(load.contents == nil)
    let byKey = Dictionary(load.problems.map { ($0.key ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byKey["settings.sidebarWidth"]?.line == 3)
    #expect(byKey["settings.sidebarWidth"]?.message == "expected a number from 140 to 600")
    #expect(byKey["settings.SHOWFULLURL"]?.message.contains("did you mean \"showFullUrl\"") == true)
    #expect(byKey["settings.cliControl"]?.message.hasPrefix("can't be set from a file") == true)
    #expect(byKey["settings.tabLayout"]?.message == #"expected one of "sidebar", "top""#)
    #expect(byKey["keybindings.newTab"]?.message.contains("needs cmd or ctrl") == true)
    #expect(byKey["colour"] != nil)
    #expect(byKey["settings.sidebarWidth"]?.summary(in: ConfigLocation(url: URL(fileURLWithPath: "/tmp/cfg"), display: "~/.config/solara"))
      == "~/.config/solara/config.json, line 3: settings.sidebarWidth: expected a number from 140 to 600")
  }

  @Test func missingAndBrokenThemesAreProblems() {
    let missing = ConfigFile.load(configReader(["config.json": #"{ "theme": "nope" }"#]))
    #expect(missing.problems.map(\.message) == ["there's no themes/nope.json"])
    let broken = ConfigFile.load(configReader([
      "config.json": #"{ "theme": "bad" }"#,
      "themes/bad.json": #"{ "colors": ["blue"], "grain": 4 }"#,
    ]))
    #expect(broken.problems.map(\.file) == ["themes/bad.json", "themes/bad.json"])
    #expect(broken.files.contains("themes/bad.json"))
  }

  @Test func unknownShortcutNamesAreProblemsWhenTheListIsKnown() {
    let load = ConfigFile.load(configReader(["config.json": #"{ "keybindings": { "nope": "cmd+k" } }"#]), knownShortcuts: ["newTab"])
    #expect(load.problems.first?.key == "keybindings.nope")
  }

  @Test func catalogCoversEveryDefaultSetting() {
    let covered = Set(ConfigCatalog.settings.map(\.key)).union(ConfigCatalog.refused.keys)
    let missing = Settings.defaults.values.keys.filter { !covered.contains($0) }
    #expect(missing == [])
    for (key, kind) in ConfigCatalog.settings {
      guard let value = Settings.defaults.values[key] else { continue }
      #expect(kind.accepts(value), "\(key)'s default must pass its own check")
    }
  }

  @Test func docsListEverySettingKey() throws {
    let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../docs/config-files.md").standardizedFileURL
    let text = try String(contentsOf: docs, encoding: .utf8)
    for (key, _) in ConfigCatalog.settings { #expect(text.contains("`\(key)`"), "docs/config-files.md lacks \(key)") }
  }
}

@Suite struct ConfigKeysTests {
  @Test func readableAndGlyphFormsMatchTheStoredForm() {
    let cases: [(String, [String])] = [
      ("cmd+t", ["t", "command"]),
      ("Cmd+Shift+T", ["t", "shift", "command"]),
      ("⇧⌘T", ["t", "shift", "command"]),
      ("ctrl+alt+k", ["k", "control", "option"]),
      ("cmd++", ["+", "command"]),
      ("cmd+left", ["\u{F702}", "command"]),
      ("F5", ["\u{F708}"]),
      ("cmd+return", ["\r", "command"]),
      ("none", [""]),
    ]
    for (text, stored) in cases {
      #expect((try? ConfigKeys.parse(text).get()) == stored, "\(text)")
    }
  }

  @Test func badKeysSayWhy() {
    #expect(throws: ConfigKeyFailure.self) { try ConfigKeys.parse("hyper+k").get() }
    #expect(throws: ConfigKeyFailure.self) { try ConfigKeys.parse("cmd+").get() }
    #expect(throws: ConfigKeyFailure.self) { try ConfigKeys.parse("shift+k").get() }
    #expect(throws: ConfigKeyFailure.self) { try ConfigKeys.parse("cmd+banana").get() }
  }
}

@Suite struct SettingsFileLayerTests {
  static let layer = SettingsFileLayer(source: "~/.config/solara/config.json", values: ["sidebarWidth": 240, "appearance": "dark"], shortcuts: ["newTab": ["y", "command"]])

  static var own: Settings {
    Settings.defaults.choosing(["appearance": "light", "shortcuts": ["newTab": ["n", "command"], "closeTab": ["w", "option", "command"]]])
  }

  @Test func theFileWinsAndTheUsersValuesWaitBeneath() {
    let settings = Self.own.applyingFile(Self.layer)
    #expect(settings["sidebarWidth"] == 240)
    #expect(settings["appearance"] == "dark")
    #expect(settings["shortcuts"]?["newTab"] == ["y", "command"])
    #expect(settings["shortcuts"]?["closeTab"] == ["w", "option", "command"])
    #expect(settings.ownValues["appearance"] == "light")
    #expect(settings.ownValues["sidebarWidth"] == 190)
    #expect(settings.ownValues["shortcuts"]?["newTab"] == ["n", "command"])
    #expect(settings.fileSource("appearance") == "~/.config/solara/config.json")
    #expect(settings.fileSource("showFullUrl") == nil)
    #expect(settings.fileSource(shortcut: "newTab") != nil)
    #expect(settings.fileSource(shortcut: "closeTab") == nil)
  }

  @Test func writesToFileKeysLandBeneathAndOthersAsToday() {
    let settings = Self.own.applyingFile(Self.layer)
    let written = settings.choosing(["appearance": "auto", "showFullUrl": true])
    #expect(written["appearance"] == "dark")
    #expect(written.ownValues["appearance"] == "auto")
    #expect(written["showFullUrl"] == true)
    #expect(written.chosen?.contains("showFullUrl") == true)
    let synced = written.merging(["sidebarWidth": 300])
    #expect(synced["sidebarWidth"] == 240)
    #expect(synced.ownValues["sidebarWidth"] == 300)
    #expect(synced.applyingFile(nil)["sidebarWidth"] == 300)
    #expect(synced.applyingFile(nil)["appearance"] == "auto")
    #expect(synced.applyingFile(nil).fileLayer == nil)
  }

  @Test func shortcutWritesKeepTheFilesBindings() {
    let settings = Self.own.applyingFile(Self.layer)
    let reset = settings.choosing(["shortcuts": [:]])
    #expect(reset["shortcuts"] == ["newTab": ["y", "command"]])
    #expect(reset.ownValues["shortcuts"] == [:])
    let edited = settings.choosing(["shortcuts": ["newTab": ["y", "command"], "closeTab": ["q", "command"]]])
    #expect(edited["shortcuts"]?["closeTab"] == ["q", "command"])
    #expect(edited.ownValues["shortcuts"]?["newTab"] == ["n", "command"])
    #expect(edited.applyingFile(nil)["shortcuts"]?["newTab"] == ["n", "command"])
  }

  @Test func rebindingAFileShortcutIsKeptBeneathTheFile() {
    let settings = Self.own.applyingFile(Self.layer)
    let edited = settings.choosing(["shortcuts": ["newTab": ["k", "command"], "closeTab": ["w", "option", "command"]]])
    #expect(edited["shortcuts"]?["newTab"] == ["y", "command"])
    #expect(edited.ownValues["shortcuts"]?["newTab"] == ["k", "command"])
    #expect(edited.applyingFile(nil)["shortcuts"]?["newTab"] == ["k", "command"])
    var incoming = settings.values
    incoming["shortcuts"] = ["newTab": ["j", "command"], "closeTab": ["w", "option", "command"]]
    let replaced = settings.replacingValues(incoming)
    #expect(replaced["shortcuts"]?["newTab"] == ["y", "command"])
    #expect(replaced.applyingFile(nil)["shortcuts"]?["newTab"] == ["j", "command"])
  }

  @Test func wholeReplacementOfACoveredKeyLandsBeneathTheFile() {
    let settings = Self.own.applyingFile(Self.layer)
    var incoming = settings.values
    incoming["sidebarWidth"] = 300
    let replaced = settings.replacingValues(incoming)
    #expect(replaced["sidebarWidth"] == 240)
    #expect(replaced.ownValues["sidebarWidth"] == 300)
    #expect(replaced.applyingFile(nil)["sidebarWidth"] == 300)
    let echoed = replaced.replacingValues(replaced.values)
    #expect(echoed.ownValues["sidebarWidth"] == 300)
    #expect(echoed.ownValues["appearance"] == "light")
    #expect(echoed.ownValues["shortcuts"]?["newTab"] == ["n", "command"])
  }

  @Test func theReplicaCarriesOwnValuesOnlyForCoveredKeys() {
    let settings = Self.own.applyingFile(Self.layer)
    let fileOwn = settings.replicaJSON[SettingsFileLayer.replicaKey]
    #expect(fileOwn?["covered"] == ["appearance", "shortcuts", "sidebarWidth"])
    #expect(fileOwn?["own"]?["appearance"] == "light")
    #expect(fileOwn?["own"]?["shortcuts"]?["newTab"] == ["n", "command"])
    #expect(settings.replicaJSON["appearance"] == "dark")
    #expect(Self.own.replicaJSON == Self.own.json)
    #expect(settings.applyingFile(nil).replicaJSON == settings.applyingFile(nil).json)
    var incoming = settings.replicaJSON.object ?? [:]
    incoming["showFullUrl"] = true
    let replaced = settings.replacingValues(incoming)
    #expect(replaced.values[SettingsFileLayer.replicaKey] == nil)
    #expect(replaced.ownValues[SettingsFileLayer.replicaKey] == nil)
    #expect(Settings(values: incoming).values[SettingsFileLayer.replicaKey] == nil)
  }

  @Test func replacingTheLayerStartsFromTheUsersValues() {
    let first = Self.own.applyingFile(Self.layer)
    let second = first.applyingFile(SettingsFileLayer(source: "x", values: ["showFullUrl": true]))
    #expect(second["appearance"] == "light")
    #expect(second["sidebarWidth"] == 190)
    #expect(second["showFullUrl"] == true)
    #expect(second.ownValues["showFullUrl"] == false)
    #expect(second["shortcuts"]?["newTab"] == ["n", "command"])
  }

  @Test func wholeReplacementKeepsTheLayer() {
    let settings = Self.own.applyingFile(Self.layer)
    var incoming = settings.values
    incoming["appearance"] = "light"
    incoming["showFullUrl"] = true
    let replaced = settings.replacingValues(incoming)
    #expect(replaced["appearance"] == "dark")
    #expect(replaced["showFullUrl"] == true)
    #expect(replaced.ownValues["appearance"] == "light")
  }
}

@Suite struct ProfileFileThemeTests {
  @Test func aFileThemeShadowsTheProfilesOwn() {
    let own: JSONValue = ["stops": [], "mode": "light"]
    let look: JSONValue = ["stops": [], "mode": "dark"]
    var profile = Profile(id: "p", name: "P", color: "plum", icon: nil, createdAt: 0, theme: own)
    profile = profile.applyingFileTheme(look, name: "ocean", source: "config.json")
    #expect(profile.theme == look)
    #expect(profile.ownTheme == own)
    #expect(profile.own.theme == own)
    #expect(profile.ownJSONValue["theme"] == own)
    profile.setOwnTheme(nil)
    #expect(profile.theme == look)
    #expect(profile.ownTheme == nil)
    #expect(profile.own.fileTheme == nil)
  }

  @Test func theReplicaSeesTheOwnThemeButDiskNeverDoes() throws {
    let own: JSONValue = ["stops": [], "mode": "light"]
    let look: JSONValue = ["stops": [], "mode": "dark"]
    let profile = Profile(id: "p", name: "P", color: "plum", icon: nil, createdAt: 0, theme: own).applyingFileTheme(look, name: "ocean", source: "config.json")
    #expect(profile.json["theme"] == look)
    #expect(profile.json[ProfileFileTheme.replicaKey]?["own"] == own)
    #expect(profile.json[ProfileFileTheme.replicaKey]?["name"] == "ocean")
    #expect(profile.ownJSONValue[ProfileFileTheme.replicaKey] == nil)
    let echoed = try Profile(json: profile.json)
    #expect(echoed.extra[ProfileFileTheme.replicaKey] == nil)
    #expect(echoed.fileTheme == nil)
    #expect(echoed.json[ProfileFileTheme.replicaKey] == nil)
  }
}

@Suite struct ConfigProblemsTests {
  @Test func ownersKeepTheirOwnProblems() {
    let registry = ConfigProblems()
    let config = ConfigProblem(file: "config.json", key: "settings.x", line: 2, message: "bad")
    let hooks = ConfigProblem(file: "hooks.json", message: "bad")
    #expect(registry.set([config], for: "config") == [config])
    #expect(registry.set([hooks], for: "hooks") == [hooks])
    #expect(registry.set([], for: "hooks") == [])
    #expect(registry.all == [config])
    #expect(registry.set([config], for: "config") == [])
  }
}

@Suite(.serialized) struct ConfigDirectoryTests {
  final class Seen: @unchecked Sendable {
    let lock = NSLock()
    var names: [Set<String>] = []
    func add(_ set: Set<String>) { lock.withLock { names.append(set) } }
    var all: Set<String> { lock.withLock { names.reduce(into: Set<String>()) { $0.formUnion($1) } } }
    func reset() { lock.withLock { names = [] } }
  }

  static func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "cfg34-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func wait(_ seen: Seen, for name: String, seconds: Double = 5) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if seen.all.contains(name) { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }

  @Test func restartsRacingStopsNeverLeaveAStreamRunning() throws {
    let root = try Self.scratch()
    let directory = ConfigDirectory(location: ConfigLocation(url: root), debounce: 0.05, delivery: DispatchQueue(label: "cfg34-race"))
    for _ in 0..<50 {
      let id = directory.observe { _ in }
      let restarted = DispatchSemaphore(value: 0)
      directory.work.async {
        directory.restartStream()
        restarted.signal()
      }
      directory.removeObserver(id)
      restarted.wait()
      directory.work.sync {}
      #expect(directory.streamCount == 0)
    }
    let id = directory.observe { _ in }
    directory.work.sync { directory.restartStream() }
    #expect(directory.streamCount == 1)
    directory.removeObserver(id)
    directory.work.sync {}
    #expect(directory.streamCount == 0)
  }

  @Test func onlyRegularFilesAreRead() throws {
    let root = try Self.scratch()
    let pipe = root.appending(path: "config.json")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(ConfigDirectory.read(pipe) == .unreadable("isn't a regular file"))
    #expect(ConfigDirectory.read(root) == .unreadable("is a folder, not a file"))
    #expect(ConfigDirectory.read(root.appending(path: "missing.json")) == .absent)
  }

  @Test func writesRenamesAndThemesAreSeen() throws {
    let root = try Self.scratch()
    let directory = ConfigDirectory(location: ConfigLocation(url: root), debounce: 0.05, delivery: DispatchQueue(label: "cfg34-test"))
    let seen = Seen()
    let id = directory.observe { seen.add($0) }
    defer { directory.removeObserver(id) }
    try Data(#"{"settings":{}}"#.utf8).write(to: root.appending(path: "config.json"))
    #expect(Self.wait(seen, for: "config.json"))
    seen.reset()
    let temp = root.appending(path: ".config.json.swp")
    try Data(#"{"settings":{"showFullUrl":true}}"#.utf8).write(to: temp)
    _ = try FileManager.default.replaceItemAt(root.appending(path: "config.json"), withItemAt: temp)
    #expect(Self.wait(seen, for: "config.json"))
    seen.reset()
    try FileManager.default.createDirectory(at: root.appending(path: "themes"), withIntermediateDirectories: true)
    try Data(##"{"colors":["#123456"]}"##.utf8).write(to: root.appending(path: "themes/ocean.json"))
    #expect(Self.wait(seen, for: "themes/ocean.json"))
    seen.reset()
    try Data(#"{"settings":{"showFullUrl":true}}"#.utf8).write(to: root.appending(path: "config.json"))
    Thread.sleep(forTimeInterval: 0.4)
    #expect(!seen.all.contains("config.json"), "an identical save isn't a change")
  }

  @Test func aFolderCreatedLaterIsWatched() throws {
    let parent = try Self.scratch()
    let root = parent.appending(path: "solara", directoryHint: .isDirectory)
    let directory = ConfigDirectory(location: ConfigLocation(url: root), debounce: 0.05, delivery: DispatchQueue(label: "cfg34-test-late"))
    let seen = Seen()
    let id = directory.observe { seen.add($0) }
    defer { directory.removeObserver(id) }
    #expect(directory.read("config.json") == .absent)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appending(path: "config.json"))
    #expect(Self.wait(seen, for: "config.json"))
  }

  @Test func resolveHonoursTestIsolation() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(ConfigLocation.resolve(environment: [:], home: home)?.url.path == "/Users/someone/.config/solara")
    #expect(ConfigLocation.resolve(environment: [:], home: home)?.display == "~/.config/solara")
    #expect(ConfigLocation.resolve(environment: ["SOLARA_DATA_DIR": "/tmp/x"], home: home) == nil)
    #expect(ConfigLocation.resolve(environment: ["SOLARA_BACKGROUND": "1"], home: home) == nil)
    #expect(ConfigLocation.resolve(environment: ["SOLARA_DATA_DIR": "/tmp/x", "SOLARA_CONFIG_DIR": "/tmp/cfg"], home: home)?.url.path == "/tmp/cfg")
    #expect(ConfigLocation.resolve(environment: ["SOLARA_CONFIG_DIR": "rel"], home: home, currentDirectory: "/work")?.url.path == "/work/rel")
  }
}
