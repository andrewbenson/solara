import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ExperimentsSectionTests {
  func scratchDefaults() -> UserDefaults {
    let name = "ExperimentsSectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func model(environment: [String: String] = [:], defaults: UserDefaults, distribution: Bool = false) -> ExperimentsModel {
    let running = LaunchSwitches(environment: environment, defaults: defaults, distribution: distribution, skipStored: false)
    return ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
  }

  func row(_ model: ExperimentsModel, _ name: LaunchSwitch) -> ExperimentsModel.Row {
    model.rows.first { $0.name == name }!
  }

  @Test func theRowsAreTheRemainingInterfaceSwitchesWithTheirDependencies() {
    let model = model(defaults: scratchDefaults())
    #expect(model.rows.map(\.name) == [.nativeShell, .shellPanes, .nativeTopStrip, .nativeSidePanel])
    #expect(!model.rows.contains { $0.name == .nativePagesPool || $0.name == .shellMainTop })
    #expect(row(model, .shellPanes).needs == "Needs Native window.")
    #expect(row(model, .nativeShell).needs == nil)
  }

  @Test func aRowWhoseDependencyIsOffIsGreyedUntilItIsTurnedOn() {
    let defaults = scratchDefaults()
    let model = model(defaults: defaults)
    #expect(row(model, .nativeShell).on)
    #expect(row(model, .shellPanes).enabled)
    #expect(row(model, .nativeShell).enabled)
    #expect(!model.pendingRelaunch)
    model.set(.nativeShell, false)
    #expect(defaults.string(forKey: "SOLARA_NATIVE_SHELL") == "0")
    #expect(!row(model, .shellPanes).enabled)
    #expect(model.pendingRelaunch)
    model.set(.nativeShell, true)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
    #expect(row(model, .shellPanes).enabled)
    #expect(!model.pendingRelaunch)
  }

  @Test func aSwitchSetWithoutItsDependencyShowsOffAndSaysWhy() {
    let environment = model(environment: ["SOLARA_NATIVE_SHELL": "0", "SOLARA_SHELL_PANES": "1"], defaults: scratchDefaults())
    #expect(!row(environment, .shellPanes).on)
    #expect(row(environment, .shellPanes).waiting == "Off until Native window is on.")
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_SHELL_PANES")
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    let saved = model(defaults: defaults)
    #expect(!row(saved, .shellPanes).on)
    #expect(!row(saved, .shellPanes).enabled)
    #expect(row(saved, .shellPanes).waiting == "Off until Native window is on.")
    #expect(!saved.pendingRelaunch)
    saved.set(.nativeShell, true)
    #expect(row(saved, .shellPanes).on)
    #expect(row(saved, .shellPanes).waiting == nil)
    #expect(saved.pendingRelaunch)
  }

  @Test func turnAllOffClearsEverySavedSwitch() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_SHELL_PANES")
    defaults.set("1", forKey: "SOLARA_SHELL_MAIN_TOP")
    let model = model(defaults: defaults)
    model.turnAllOff()
    #expect(defaults.object(forKey: "SOLARA_SHELL_PANES") == nil)
    #expect(defaults.object(forKey: "SOLARA_SHELL_MAIN_TOP") == nil)
    #expect(model.pendingRelaunch)
  }

  @Test func theSectionStaysHiddenUntilOptionOrASavedOrEnvironmentSwitch() {
    let empty = model(defaults: scratchDefaults())
    empty.reveal(optionHeld: false)
    #expect(!empty.revealed)
    empty.reveal(optionHeld: true)
    #expect(empty.revealed)
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_SHELL_PANES")
    let saved = model(defaults: defaults)
    saved.reveal(optionHeld: false)
    #expect(saved.revealed)
    let environment = model(environment: ["SOLARA_SHELL_PANES": "1"], defaults: scratchDefaults())
    environment.reveal(optionHeld: false)
    #expect(environment.revealed)
  }

  @Test func anIsolatedInstanceShowsItsEnvironmentAndCannotSave() {
    let defaults = scratchDefaults()
    let model = model(environment: ["SOLARA_DATA_DIR": "/tmp/x", "SOLARA_NATIVE_SHELL": "1"], defaults: defaults)
    #expect(!model.stored.writable)
    #expect(model.note.hasPrefix("This instance has its own data folder"))
    #expect(row(model, .nativeShell).on)
    #expect(row(model, .nativeShell).fromEnvironment)
    #expect(model.rows.allSatisfy { !$0.enabled })
    model.set(.shellPanes, true)
    #expect(defaults.object(forKey: "SOLARA_SHELL_PANES") == nil)
  }

  @Test func aSafeLaunchAfterFailedLaunchesSaysSoAndLeavesTheSwitchesAlone() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_SHELL_PANES")
    defaults.set(2, forKey: "SolaraLaunchSwitchFailedLaunches")
    let running = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false })
    let model = ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
    model.reveal(optionHeld: false)
    #expect(model.revealed)
    #expect(model.note.hasPrefix("This launch is in safe mode."))
    #expect(row(model, .nativeShell).on && row(model, .shellPanes).on)
    #expect(defaults.string(forKey: "SOLARA_SHELL_PANES") == "1")
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
  }

  @Test func aDistributionBuildShowsTheDefaultOnSwitchesOnAndLocked() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    let running = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: true, optionHeld: { true })
    let model = ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
    #expect(model.note.hasPrefix("This launch is in safe mode."))
    #expect(model.rows.allSatisfy { $0.on && !$0.enabled })
    #expect(defaults.string(forKey: "SOLARA_NATIVE_SHELL") == "0")
  }
}
