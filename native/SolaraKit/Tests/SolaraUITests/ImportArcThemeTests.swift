import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@Suite struct ImportArcThemeTests {
  static let red = #"{"background":{"single":{"_0":{"style":{"color":{"_0":{"blendedSingleColor":{"_0":{"color":{"red":1,"green":0,"blue":0},"modifiers":{"intensityFactor":0.7,"noiseFactor":0.2,"overlay":"denim"},"translucencyStyle":"light"}}}}}}}}}"#

  func parse(_ object: Any) -> JSONValue? {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return ImportArcTheme.parse(String(decoding: data, as: UTF8.self))
  }

  func fixture(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("packages/import/fixtures/arc-themes/\(name).json"), encoding: .utf8)
  }

  func compare(_ actual: JSONValue, _ expected: JSONValue) {
    switch (actual, expected) {
    case (.number(let a), .number(let b)): #expect(abs(a - b) <= 1e-12)
    case (.array(let a), .array(let b)):
      #expect(a.count == b.count)
      for (a, b) in zip(a, b) { compare(a, b) }
    case (.object(let a), .object(let b)):
      #expect(Set(a.keys) == Set(b.keys))
      for key in b.keys { if let a = a[key], let b = b[key] { compare(a, b) } }
    default: #expect(actual == expected)
    }
  }

  @Test func completeGoldensMatchTheTypeScriptParser() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let goldens = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("packages/import/fixtures/arc-theme-goldens.json")))
    for golden in try #require(goldens.array) {
      let input = try #require(golden["input"])
      let expected = try #require(golden["expected"])
      let parsed = ImportArcTheme.parse(input.text())
      if expected.isNull { #expect(parsed == nil) }
      else { compare(try #require(parsed), expected) }
    }
  }

  @Test func knownRedHasExactCoordinatesAndDefaults() throws {
    let theme = try #require(ImportArcTheme.parse(Self.red))
    #expect(theme == ["stops": [["color": ["r": 1, "g": 0, "b": 0, "a": 1], "x": 1, "y": 0.5]], "intensity": 0.7, "grain": 0.2, "texture": "denim", "translucency": 1, "mode": "light"])
  }

  @Test func existingFixturesKeepExtendedColorsOverlaysAndAppearance() throws {
    let green = try #require(ImportArcTheme.parse(try fixture("green-pink")))
    #expect(green["stops"]?.array?.count == 2)
    #expect(green["mode"] == "light")
    #expect(green["intensity"] == 0.8)
    let blue = try #require(ImportArcTheme.parse(try fixture("blue-teal")))
    #expect(blue["stops"]?.array?.count == 3)
    #expect(blue["mode"] == "auto")
    #expect(blue["intensity"] == 0.75)
    #expect(blue["grain"] == 0.3)
    let orange = try #require(ImportArcTheme.parse(try fixture("single-orange")))
    #expect(orange["stops"]?.array?.first?["color"] == ["r": 1.0721, "g": 0.4103, "b": -0.0207, "a": 1])
    #expect(orange["texture"] == "sand")
    #expect(orange["grain"] == 1)
    #expect(orange["mode"] == "dark")
    let basic = try #require(ImportArcTheme.parse(try fixture("basic-appearance")))
    #expect(basic["mode"] == "auto")
    #expect(basic["translucency"] == 0)
    #expect(basic["grain"] == 0)
    #expect(basic["stops"]?.array?.first?["color"] == ["r": 0.86, "g": 0.9, "b": 0.97, "a": 1])
    #expect(basic["dark"]?["stops"]?.array?.first?["color"] == ["r": 0.08, "g": 0.1, "b": 0.16, "a": 1])
    for theme in [green, blue, orange, basic] { #expect(theme["angle"] == nil) }
  }

  @Test func malformedBooleanChannelsAndBoundaryValuesAreRejected() {
    for input in ["", "{", "[]", "null", "{}", Self.red.replacingOccurrences(of: "\"red\":1", with: "\"red\":01"), Self.red.replacingOccurrences(of: "\"red\":1", with: "\"red\":true"), Self.red.replacingOccurrences(of: "\"red\":1", with: "\"red\":4")] {
      #expect(ImportArcTheme.parse(input) == nil)
    }
    #expect(ImportArcTheme.parse(Self.red + String(repeating: " ", count: 65536)) == nil)
    let utf16Oversize = String(Self.red.dropLast()) + ",\"ignored\":\"" + String(repeating: "🌱", count: 32768) + "\"}"
    #expect(ImportArcTheme.parse(String(utf16Oversize)) == nil)
    #expect(ImportArcTheme.parse(Self.red.replacingOccurrences(of: "\"red\":1", with: "\"red\":3.9")) != nil)
  }

  @Test func settingsChoicesPreserveSpaceOrderAndSanitizedLooks() throws {
    let basic = try fixture("basic-appearance")
    let extended = try fixture("single-orange")
    let choices = ArcThemeChoice.imported(from: [
      (id: "missing", name: "Missing", emoji: nil, theme: nil),
      (id: "z", name: "Research", emoji: "🔬", theme: basic),
      (id: "malformed", name: "Malformed", emoji: "❌", theme: "{"),
      (id: "out-of-range", name: "Out of range", emoji: nil, theme: Self.red.replacingOccurrences(of: "\"red\":1", with: "\"red\":4")),
      (id: "a", name: "Studio", emoji: nil, theme: extended)
    ])
    #expect(choices.map(\.id) == ["z", "a"])
    #expect(choices.map(\.name) == ["Research", "Studio"])
    #expect(choices.map(\.emoji) == ["🔬", nil])
    #expect(choices.map(\.title) == ["🔬  Research", "Studio"])
    for (choice, raw) in zip(choices, [basic, extended]) {
      let encoded = try JSONValue.parse(JSONEncoder().encode(choice.theme))
      compare(encoded, try #require(ImportArcTheme.parse(raw)))
    }
  }

  @Test func settingsChoicesAreEmptyWhenDiscoveryIsUnavailable() {
    #expect(ArcThemeChoice.imported(from: nil).isEmpty)
    #expect(ArcThemeChoice.imported(from: []).isEmpty)
  }

  @Test func forcedDarkAndSingleAppearanceTakePrecedence() throws {
    var raw = try JSONSerialization.jsonObject(with: Data(try fixture("basic-appearance").utf8)) as! [String: Any]
    raw["windowAppearance"] = ["single": ["_0": "dark"]]
    let dark = try #require(parse(raw))
    #expect(dark["mode"] == "dark")
    #expect(dark["dark"] == nil)
    #expect(dark["stops"]?.array?.first?["color"] == ["r": 0.08, "g": 0.1, "b": 0.16, "a": 1])
  }
}

@MainActor
@Suite struct ImportThemeAdoptionTests {
  @Test func successRequiresAcknowledgementBeforeThemePlacement() async {
    let (runs, engine, runner, control) = ImportSidebarRunTests().setup()
    let written = await runner.placeSidebarSpace(ImportSidebarRunTests.space(theme: ImportArcThemeTests.red), profile: "default", favicons: [], control: control)
    #expect(written?.tabs == 2)
    #expect(engine.themeAdoptions == ["default"])
    #expect(engine.workspaceThemes.first! == ImportArcTheme.parse(ImportArcThemeTests.red))
    #expect(!runner.themeAdoptionFailed)
    #expect(runs.pendingWrites == 0)
  }

  @Test func rejectionAndThrownFailureKeepTabsButOmitTheme() async {
    for throwsError in [false, true] {
      let (_, engine, runner, control) = ImportSidebarRunTests().setup()
      engine.themeAnswer = false
      engine.themeThrows = throwsError
      let written = await runner.placeSidebarSpace(ImportSidebarRunTests.space(theme: ImportArcThemeTests.red), profile: "default", favicons: [], control: control)
      #expect(written?.tabs == 2)
      #expect(engine.workspaceThemes.count == 1)
      #expect(engine.workspaceThemes[0] == nil)
      #expect(runner.themeAdoptionFailed)
    }
  }

  @Test func timeoutIsDrainVisibleAndLateSuccessNeverWritesTheme() async {
    let (runs, engine, runner, control) = ImportSidebarRunTests().setup()
    runs.themeAdoptionDeadline = .milliseconds(1)
    var release: CheckedContinuation<Void, Never>?
    engine.onThemeAdopt = { await withCheckedContinuation { release = $0 } }
    let written = await runner.placeSidebarSpace(ImportSidebarRunTests.space(theme: ImportArcThemeTests.red), profile: "default", favicons: [], control: control)
    #expect(written?.tabs == 2)
    #expect(runner.themeAdoptionFailed)
    #expect(runs.pendingWrites == 1)
    #expect(engine.workspaceThemes[0] == nil)
    release?.resume()
    for _ in 0..<100 where runs.pendingWrites > 0 { await Task.yield() }
    #expect(runs.pendingWrites == 0)
    #expect(engine.workspaces.count == 1)
    #expect(engine.workspaceThemes[0] == nil)
  }

  @Test func deletionOrCancellationDuringAcknowledgementStopsPlacement() async {
    for cancel in [false, true] {
      let (_, engine, runner, control) = ImportSidebarRunTests().setup()
      engine.onThemeAdopt = {
        if cancel { control.stop() } else { engine.missingProfiles.insert("default") }
      }
      #expect(await runner.placeSidebarSpace(ImportSidebarRunTests.space(theme: ImportArcThemeTests.red), profile: "default", favicons: [], control: control) == nil)
      #expect(engine.workspaces.isEmpty)
    }
  }

  @Test func failedThemeReportsExactNoteAndAppearanceKindsWhileKeepingCounts() async {
    let suite = ImportSidebarRunTests()
    let (runs, engine, runner, _) = suite.setup()
    runs.browsers = [suite.source()]
    engine.themeAnswer = false
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: [], spaces: [ImportSidebarRunTests.space(theme: ImportArcThemeTests.red)]))
    let result = await runner.run(suite.request())
    #expect(result.counts.tabs == 2)
    #expect(result.notes == ["The imported theme could not be adopted; the existing theme was kept."])
    #expect(result.status == [.tabs: .failed, .spaces: .failed, .pinnedTabs: .failed])
    #expect(result.failures.map(\.kind) == [.tabs, .spaces, .pinnedTabs])
  }

  @Test func absentAndInvalidThemesNeverRequestAdoption() async {
    for theme in [Optional<String>.none, "{}"] {
      let (_, engine, runner, control) = ImportSidebarRunTests().setup()
      _ = await runner.placeSidebarSpace(ImportSidebarRunTests.space(theme: theme), profile: "default", favicons: [], control: control)
      #expect(engine.themeAdoptions.isEmpty)
      #expect(engine.workspaceThemes[0] == nil)
    }
  }
}
