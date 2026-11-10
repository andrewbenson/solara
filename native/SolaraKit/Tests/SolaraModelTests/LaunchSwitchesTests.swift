import Foundation
import Synchronization
import Testing
@testable import SolaraModel

@Suite struct LaunchSwitchesTests {
  static let defaultOn: Set<LaunchSwitch> = [
    .nativeShell, .nativeTopStrip, .nativeBookmarksBar, .nativeBookmarks,
    .shellPanes, .nativePagesPool, .shellMainTop, .nativeTabSleep,
  ]
  static let shippedSurfaces = defaultOn.filter { !$0.storable(distribution: true) && $0 != .nativeBookmarks }

  func scratchDefaults() -> UserDefaults {
    let name = "LaunchSwitchesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func allNeeds(_ name: LaunchSwitch) -> [String: String] {
    name.needs.reduce(into: [:]) { env, need in
      env[need.rawValue] = "1"
      env.merge(allNeeds(need)) { a, _ in a }
    }
  }

  @Test func environmentValuesReadAsTheOldEqualsOneAndNotZeroChecksDid() {
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) {
      let on = Self.defaultOn.contains(name)
      for (text, expected) in [("", on), ("1", true), ("0", false), ("true", on), ("off", on)] {
        let switches = LaunchSwitches(environment: allNeeds(name).merging([name.rawValue: text]) { _, b in b }, defaults: nil, distribution: false, skipStored: false)
        let old = on ? text != "0" : text == "1"
        #expect(switches.isOn(name, defaultOn: on) == expected, "\(name.rawValue)=\(text)")
        #expect(expected == old, "\(name.rawValue)=\(text)")
      }
      #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).isOn(name, defaultOn: on) == on)
    }
  }

  @Test func distributionOwnsBookmarksWithoutFlags() {
    let switches = LaunchSwitches(environment: [:], defaults: nil, distribution: true, skipStored: false)
    #expect(switches.isOn(.nativeBookmarks))
  }

  @Test func distributionOffOverridesCannotReviveJS() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_BOOKMARKS")
    for environment in [[:], ["SOLARA_NATIVE_BOOKMARKS": "0"], ["SOLARA_NATIVE_BOOKMARKS": "1", "SOLARA_NATIVE_SCOPE": "settings"]] {
      let switches = LaunchSwitches(environment: environment, defaults: defaults, distribution: true, skipStored: false)
      #expect(switches.isOn(.nativeBookmarks))
      #expect(!switches.fromEnvironment(.nativeBookmarks))
      #expect(!LaunchSwitch.nativeBookmarks.storable(distribution: true))
    }
  }

  @Test func nativeBookmarkOwnershipRequiresAnIsolatedDevelopmentOptIn() {
    let flag = "SOLARA_NATIVE_BOOKMARKS"
    let own = [flag: "1", "SOLARA_DATA_DIR": "/tmp/bookmark-owner"]
    let selected = LaunchSwitches(environment: own, defaults: nil, distribution: false, skipStored: false)
    #expect(selected.isOn(.nativeBookmarks))
    #expect(LaunchSwitches(environment: own, defaults: nil, distribution: true, skipStored: false).isOn(.nativeBookmarks))
    for env in [[:], [flag: "1"], [flag: "1", "SOLARA_BACKGROUND": "1"], [flag: "1", "SOLARA_DATA_DIR": ""]] {
      #expect(!LaunchSwitches(environment: env, defaults: nil, distribution: false, skipStored: false).isOn(.nativeBookmarks))
    }
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: flag)
      #expect(LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false).isOn(.nativeBookmarks) == distribution)
      StoredLaunchSwitches(defaults: defaults, distribution: distribution).set(.nativeBookmarks, true)
      #expect(!LaunchSwitch.nativeBookmarks.storable(distribution: distribution))
    }
  }

  @Test func nativeBookmarkOwnershipIsIndependentOfBarShellAndSyncSwitches() {
    let enabled = LaunchSwitches(environment: [
      "SOLARA_NATIVE_BOOKMARKS": "1", "SOLARA_DATA_DIR": "/tmp/bookmark-owner",
      "SOLARA_NATIVE_BOOKMARKS_BAR": "0", "SOLARA_NATIVE_SHELL": "0", "SOLARA_SYNC_REDESIGN": "0",
    ], defaults: nil, distribution: false, skipStored: false)
    #expect(enabled.isOn(.nativeBookmarks))
    #expect(!enabled.isOn(.nativeBookmarksBar))
    #expect(!enabled.isOn(.syncRedesign))
    let old = LaunchSwitches(environment: ["SOLARA_SYNC_REDESIGN": "1", "SOLARA_DATA_DIR": "/tmp/bookmark-owner"], defaults: nil, distribution: false, skipStored: false)
    #expect(!old.isOn(.nativeBookmarks))
  }

  @Test func nativeTabSleepIsOnByDefaultAndCanBeDisabledInDevelopment() {
    for distribution in [false, true] {
      let initial = LaunchSwitches(environment: [:], defaults: nil, distribution: distribution, skipStored: false)
      #expect(initial.isOn(.nativeTabSleep))
      let disabled = LaunchSwitches(environment: ["SOLARA_NATIVE_TAB_SLEEP": "0"], defaults: nil, distribution: distribution, skipStored: false)
      #expect(disabled.isOn(.nativeTabSleep) == distribution)
      #expect(disabled.fromEnvironment(.nativeTabSleep) == !distribution)
      #expect(!LaunchSwitch.nativeTabSleep.storable(distribution: distribution))
    }
  }

  @Test func theNativeBookmarksBarIsOnByDefaultInDevelopmentAndDistribution() {
    for distribution in [false, true] {
      let initial = LaunchSwitches(environment: [:], defaults: nil, distribution: distribution, skipStored: false)
      #expect(initial.isOn(.nativeBookmarksBar))
    }
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_BOOKMARKS_BAR")
    let shipped = LaunchSwitches(
      environment: ["SOLARA_NATIVE_BOOKMARKS_BAR": "0"], defaults: defaults, distribution: true, skipStored: false)
    #expect(shipped.isOn(.nativeBookmarksBar))
    #expect(!shipped.fromEnvironment(.nativeBookmarksBar))
    #expect(!LaunchSwitch.nativeBookmarksBar.storable(distribution: true))
  }

  @Test func theNativeBookmarksBarStillRequiresTheNativeWindow() {
    let noWindow = LaunchSwitches(
      environment: ["SOLARA_NATIVE_SHELL": "0"], defaults: nil, distribution: false, skipStored: false)
    #expect(noWindow.requested(.nativeBookmarksBar, defaultOn: true))
    #expect(!noWindow.isOn(.nativeBookmarksBar))
    #expect(noWindow.unmetNeeds(.nativeBookmarksBar) == [.nativeShell])
    #expect(noWindow.refusals.contains("SOLARA_NATIVE_BOOKMARKS_BAR is on but stays off: it needs SOLARA_NATIVE_SHELL=1"))
  }

  @Test func theNativeBookmarksBarCanBeSavedAndTheEnvironmentCanDisableItInDevelopment() {
    let bar = LaunchSwitch.nativeBookmarksBar
    #expect(!LaunchSwitch.experiments.contains(bar))
    let defaults = scratchDefaults()
    let stored = StoredLaunchSwitches(defaults: defaults, distribution: false)
    stored.set(bar, false)
    #expect(stored.value(bar) == false)
    let savedOff = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!savedOff.isOn(bar))
    let enabled = LaunchSwitches(environment: [bar.rawValue: "1"], defaults: defaults, distribution: false, skipStored: false)
    #expect(enabled.isOn(bar))
    #expect(enabled.fromEnvironment(bar))
    stored.set(bar, true)
    #expect(stored.value(bar) == true)
    let savedOn = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(savedOn.isOn(bar))
    let disabled = LaunchSwitches(environment: [bar.rawValue: "0"], defaults: defaults, distribution: false, skipStored: false)
    #expect(!disabled.isOn(bar))
    #expect(disabled.fromEnvironment(bar))
    stored.clear()
    #expect(defaults.object(forKey: bar.rawValue) == nil)
    #expect(LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false).isOn(bar))
  }

  @Test func theSyncRedesignIsReadOnlyByInstancesWithTheirOwnDataFolderOfBuildsNotSignedForDistribution() {
    let on = ["SOLARA_SYNC_REDESIGN": "1", "SOLARA_DATA_DIR": "/tmp/x"]
    #expect(LaunchSwitches(environment: on, defaults: nil, distribution: false, skipStored: false).isOn(.syncRedesign, defaultOn: false))
    let distributed = LaunchSwitches(environment: on, defaults: nil, distribution: true, skipStored: false)
    #expect(!distributed.isOn(.syncRedesign, defaultOn: false))
    #expect(!distributed.fromEnvironment(.syncRedesign))
    let ownersAdHocBuild = LaunchSwitches(environment: ["SOLARA_SYNC_REDESIGN": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!ownersAdHocBuild.isolated)
    #expect(!ownersAdHocBuild.isOn(.syncRedesign, defaultOn: false), "a launch on the real data folder never turns it on")
    #expect(!ownersAdHocBuild.fromEnvironment(.syncRedesign))
    let hiddenOnTheRealFolder = LaunchSwitches(environment: ["SOLARA_SYNC_REDESIGN": "1", "SOLARA_BACKGROUND": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(hiddenOnTheRealFolder.isolated)
    #expect(!hiddenOnTheRealFolder.isOn(.syncRedesign, defaultOn: false), "a hidden launch that forgot its data folder still opens the real one")
    let emptyDataFolder = LaunchSwitches(environment: ["SOLARA_SYNC_REDESIGN": "1", "SOLARA_DATA_DIR": ""], defaults: nil, distribution: false, skipStored: false)
    #expect(!emptyDataFolder.isOn(.syncRedesign, defaultOn: false), "an empty data folder is the real one, as the host reads it")
  }

  @Test func theSyncRedesignIsNeverStored() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_SYNC_REDESIGN")
    for distribution in [false, true] {
      #expect(!LaunchSwitch.syncRedesign.storable(distribution: distribution))
      #expect(!LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false).isOn(.syncRedesign, defaultOn: false))
      let stored = StoredLaunchSwitches(defaults: scratchDefaults(), distribution: distribution)
      stored.set(.syncRedesign, true)
      #expect(stored.value(.syncRedesign) == nil)
      #expect(!stored.any)
    }
  }

  @Test func theEnvironmentWinsOverAStoredValue() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    let switches = LaunchSwitches(environment: ["SOLARA_NATIVE_SHELL": "0"], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.nativeShell, defaultOn: false))
    #expect(switches.fromEnvironment(.nativeShell))
    let invalid = LaunchSwitches(environment: ["SOLARA_NATIVE_SHELL": "yes"], defaults: defaults, distribution: false, skipStored: false)
    #expect(invalid.isOn(.nativeShell, defaultOn: false))
    #expect(!invalid.fromEnvironment(.nativeShell))
  }

  @Test func aStoredValueForARetiredSwitchIsIgnoredAndClearedOnTheNextWrite() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_SIDE_PANEL")
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    defaults.set("1", forKey: "SOLARA_NATIVE_BOOKMARKS_BAR")
    #expect(LaunchSwitch(rawValue: "SOLARA_NATIVE_SIDE_PANEL") == nil)
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.nativeShell))
    #expect(switches.isOn(.nativeTopStrip))
    #expect(switches.requested(.nativeBookmarksBar, defaultOn: false))
    let stored = StoredLaunchSwitches(defaults: defaults, distribution: false)
    #expect(stored.value(.nativeShell) == false)
    stored.set(.nativeTopStrip, true)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SIDE_PANEL") == nil)
    #expect(stored.value(.nativeShell) == false)
    #expect(stored.value(.nativeBookmarksBar) == true)
    #expect(stored.value(.nativeTopStrip) == true)
  }

  @Test func storedValuesCountOnlyAsOneOrZero() {
    let defaults = scratchDefaults()
    defaults.set(true, forKey: "SOLARA_NATIVE_PAGES_POOL")
    defaults.set("on", forKey: "SOLARA_SHELL_PANES")
    defaults.set(1, forKey: "SOLARA_NATIVE_TOP_STRIP")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(switches.isOn(.nativePagesPool, defaultOn: false))
    #expect(!switches.isOn(.shellPanes, defaultOn: false))
    #expect(switches.isOn(.nativeTopStrip, defaultOn: false))
  }

  @Test func anIsolatedInstanceIgnoresStoredValuesAndCannotWriteThem() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    for env in [["SOLARA_BACKGROUND": "1"], ["SOLARA_DATA_DIR": "/tmp/x"]] {
      let switches = LaunchSwitches(environment: env, defaults: defaults, distribution: false, skipStored: false)
      #expect(switches.isolated)
      #expect(!switches.isOn(.nativeShell, defaultOn: false))
      let stored = StoredLaunchSwitches(switches, defaults: defaults)
      #expect(!stored.writable)
      #expect(stored.value(.nativeShell) == nil)
      stored.set(.nativePagesPool, true)
      #expect(defaults.object(forKey: "SOLARA_NATIVE_PAGES_POOL") == nil)
    }
  }

  @Test func theShippedSurfacesInDistributionAndTheScopeAreNeverReadFromDefaults() {
    let defaults = scratchDefaults()
    #expect(Self.shippedSurfaces.contains(.shellMainTop))
    for name in Self.shippedSurfaces { defaults.set("0", forKey: name.rawValue) }
    defaults.set("settingsAndDownloads", forKey: LaunchSwitches.scopeVariable)
    for distribution in [false, true] {
      let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false)
      for name in Self.shippedSurfaces {
        let expected = distribution || !name.storable(distribution: false)
        #expect(switches.isOn(name, defaultOn: true) == expected, "\(name.rawValue)")
      }
      #expect(switches.scope == nil)
    }
  }

  @Test func aDistributionBuildIgnoresStoredValuesForEveryDefaultOnSwitch() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.onByDefault { defaults.set("0", forKey: name.rawValue) }
    let shipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    let dev = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    for name in LaunchSwitch.onByDefault {
      #expect(shipped.isOn(name), "\(name.rawValue)")
      if name.storable(distribution: false) { #expect(!dev.isOn(name), "\(name.rawValue)") }
      #expect(!name.storable(distribution: true))
    }
    let overridden = LaunchSwitches(environment: LaunchSwitch.onByDefault.reduce(into: [:]) { $0[$1.rawValue] = "0" }, defaults: defaults, distribution: true, skipStored: false)
    for name in LaunchSwitch.onByDefault {
      #expect(overridden.isOn(name), "\(name.rawValue)")
      #expect(!overridden.fromEnvironment(name), "\(name.rawValue)")
    }
    let devOverride = LaunchSwitches(environment: ["SOLARA_NATIVE_SHELL": "0"], defaults: defaults, distribution: false, skipStored: false)
    #expect(!devOverride.isOn(.nativeShell))
  }

  @Test func aSafeModeDecisionDoesNotChangeStoredSwitches() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    let held = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { true })
    #expect(held.safeMode)
    #expect(!held.isOn(.nativeShell))
    #expect(defaults.string(forKey: "SOLARA_NATIVE_SHELL") == "0")
  }

  @Test func writingAndClearingTouchOnlyTheAllowedKeys() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_GONE")
    defaults.set("1", forKey: "SOLARA_TEST_REAUTH")
    defaults.set("1", forKey: "SOLARA_SHELL_MAIN_TOP")
    let stored = StoredLaunchSwitches(defaults: defaults, distribution: true)
    stored.set(.nativeShell, true)
    stored.set(.shellPanes, false)
    stored.set(.nativePagesPool, true)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
    #expect(defaults.object(forKey: "SOLARA_SHELL_PANES") == nil)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_PAGES_POOL") == nil)
    #expect(defaults.string(forKey: "SOLARA_NATIVE_GONE") == "1")
    #expect(defaults.string(forKey: "SOLARA_TEST_REAUTH") == "1")
    #expect(!stored.any)
    stored.set(.nativeShell, nil)
    #expect(!stored.any)
    stored.set(.nativePagesPool, false)
    stored.clear()
    #expect(defaults.object(forKey: "SOLARA_NATIVE_GONE") == nil)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_PAGES_POOL") == nil)
    #expect(defaults.string(forKey: "SOLARA_SHELL_MAIN_TOP") == "1")
  }

  @Test func dependenciesMatchTheCallSites() {
    #expect(LaunchSwitch.shellPanes.needs == [.nativeShell])
    #expect(LaunchSwitch.nativePagesPool.needs == [.nativeShell])
    #expect(LaunchSwitch.shellMainTop.needs == [.shellPanes, .nativePagesPool])
    #expect(LaunchSwitch.nativeTopStrip.needs.isEmpty)
    #expect(LaunchSwitch.nativeBookmarksBar.needs == [.nativeShell])
    #expect(LaunchSwitch.onByDefault == Self.defaultOn)
  }

  @Test func aSwitchWhoseNeedsAreOffStaysOffAndTheLaunchSaysWhy() {
    let alone = LaunchSwitches(environment: ["SOLARA_SHELL_MAIN_TOP": "1", "SOLARA_SHELL_PANES": "0", "SOLARA_NATIVE_PAGES_POOL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(alone.requested(.shellMainTop, defaultOn: false))
    #expect(!alone.isOn(.shellMainTop, defaultOn: false))
    #expect(alone.unmetNeeds(.shellMainTop) == [.shellPanes])
    #expect(alone.refusals == [
      "SOLARA_SHELL_MAIN_TOP is on but stays off: it needs SOLARA_SHELL_PANES=1",
    ])
    let met = LaunchSwitches(
      environment: ["SOLARA_SHELL_MAIN_TOP": "1", "SOLARA_SHELL_PANES": "1", "SOLARA_NATIVE_PAGES_POOL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(met.isOn(.shellMainTop, defaultOn: false))
    #expect(met.refusals.isEmpty)

    let top = LaunchSwitches(environment: ["SOLARA_SHELL_MAIN_TOP": "1", "SOLARA_NATIVE_SHELL": "1", "SOLARA_NATIVE_PAGES_POOL": "0"], defaults: nil, distribution: false, skipStored: false)
    #expect(!top.isOn(.shellMainTop, defaultOn: false))
    #expect(top.refusals == [
      "SOLARA_SHELL_MAIN_TOP is on but stays off: it needs SOLARA_NATIVE_PAGES_POOL=1",
    ])

    let noShell = LaunchSwitches(
      environment: ["SOLARA_NATIVE_SHELL": "0", "SOLARA_SHELL_MAIN_TOP": "1", "SOLARA_SHELL_PANES": "1", "SOLARA_NATIVE_PAGES_POOL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!noShell.isOn(.shellMainTop, defaultOn: false))
    #expect(noShell.unmetNeeds(.shellMainTop) == [.shellPanes, .nativePagesPool])
    #expect(noShell.refusals.count == 4)
    #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
    #expect(LaunchSwitches(environment: ["SOLARA_NATIVE_SHELL": "0", "SOLARA_SHELL_PANES": "0", "SOLARA_NATIVE_PAGES_POOL": "0", "SOLARA_SHELL_MAIN_TOP": "0", "SOLARA_NATIVE_BOOKMARKS_BAR": "0"], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
  }

  @Test func theOneArgumentReadUsesTheSwitchsOwnDefault() {
    let empty = LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false)
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) {
      #expect(empty.isOn(name) == (LaunchSwitch.onByDefault.contains(name) && empty.unmetNeeds(name).isEmpty), "\(name.rawValue)")
    }
    let off = LaunchSwitches(environment: LaunchSwitch.onByDefault.reduce(into: [:]) { $0[$1.rawValue] = "0" }, defaults: nil, distribution: false, skipStored: false)
    #expect(LaunchSwitch.onByDefault.allSatisfy { !off.isOn($0) })
  }

  @Test func theNativeInterfaceIsOnByDefaultEvenWithASavedZeroInDistribution() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    let shipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    #expect(LaunchSwitch.onByDefault.allSatisfy { shipped.isOn($0) })
    let dev = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!dev.isOn(.nativeShell))
  }

  @Test func aSavedSwitchWhoseNeedsWereTurnedOffStaysOff() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "SOLARA_NATIVE_SHELL")
    defaults.set("1", forKey: "SOLARA_SHELL_PANES")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.shellPanes, defaultOn: false))
    #expect(switches.refusals.count == 4)
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    let withShell = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(withShell.isOn(.shellPanes, defaultOn: false))
    #expect(withShell.refusals.isEmpty)
  }

  @Test func twoUnfinishedLaunchesTriggerSafeModeWithoutChangingSwitches() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "SOLARA_NATIVE_PAGES_POOL")
      let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false }) }
      #expect(launch().countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 1)
      #expect(launch().countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      let third = launch()
      #expect(third.safeMode && third.safeModeAfterFailedLaunches && third.countedLaunch)
      #expect(third.isOn(.nativeShell) && third.isOn(.nativeTopStrip) && third.isOn(.nativePagesPool))
      #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
      #expect(defaults.string(forKey: "SOLARA_NATIVE_PAGES_POOL") == "1")
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      #expect((third.safeModeReport ?? "").contains("twice in a row"))
      let fourth = launch()
      #expect(fourth.safeMode && fourth.safeModeAfterFailedLaunches && fourth.countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
      #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
      let fifth = launch()
      #expect(!fifth.safeMode && fifth.countedLaunch)
    }
  }

  @Test func launchesStillCountWhenDevelopmentSwitchesAreStoredOff() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.experiments { defaults.set("0", forKey: name.rawValue) }
    let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false }) }
    #expect(launch().countedLaunch)
    #expect(launch().countedLaunch)
    #expect(launch().safeMode)
    for name in LaunchSwitch.experiments { #expect(defaults.string(forKey: name.rawValue) == "0") }
  }

  @Test func anIsolatedLaunchNeitherCountsNorAsksForOption() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    var asked = false
    for _ in 0..<3 {
      let switches = LaunchSwitches.launching(environment: ["SOLARA_DATA_DIR": "/tmp/x"], defaults: defaults, distribution: false, optionHeld: { asked = true; return true })
      #expect(!switches.isOn(.nativeShell, defaultOn: false))
    }
    #expect(!asked)
    #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
    #expect(defaults.string(forKey: "SOLARA_NATIVE_SHELL") == "1")
  }

  @Test func holdingOptionStartsSafeModeForOneLaunchWithoutWritingSwitches() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "SOLARA_NATIVE_PAGES_POOL")
      defaults.set(1, forKey: LaunchSwitches.failedLaunchesKey)
      let held = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { true })
      #expect(held.safeMode && held.countedLaunch && !held.safeModeAfterFailedLaunches)
      #expect(held.isOn(.nativeShell) && held.isOn(.nativePagesPool) && held.isOn(.nativeTopStrip))
      #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
      #expect(defaults.string(forKey: "SOLARA_NATIVE_PAGES_POOL") == "1")
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      let retry = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false })
      #expect(retry.safeMode && retry.safeModeAfterFailedLaunches && retry.countedLaunch)
      LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
      let next = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false })
      #expect(!next.safeMode && next.isOn(.nativeShell) && next.countedLaunch)
    }
  }

  @Test func holdingOptionAsksFirstAndOpeningNormallyChangesNothing() {
    let defaults = scratchDefaults()
    var asked = 0
    let declined = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmSafeMode: { asked += 1; return false })
    #expect(asked == 1 && !declined.safeMode && declined.countedLaunch)
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
    let accepted = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmSafeMode: { asked += 1; return true })
    #expect(asked == 2 && accepted.safeMode && accepted.isOn(.nativeShell))
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
    let question = LaunchSwitches.safeModeQuestion()
    #expect(question.title == "Open Solara in safe mode?")
    #expect(question.message.contains("saved session") && question.message.contains("extensions"))
  }

  @Test func aScratchSuiteLetsAnIsolatedDevelopmentInstanceStoreAndCount() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    let env = ["SOLARA_BACKGROUND": "1", "SOLARA_DATA_DIR": "/tmp/x", LaunchSwitches.defaultsVariable: "scratch"]
    let switches = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false })
    #expect(switches.isolated && switches.usesDefaults && switches.defaultsSuite == "scratch")
    #expect(switches.isOn(.nativeShell, defaultOn: false))
    #expect(switches.countedLaunch)
    #expect(StoredLaunchSwitches(switches, defaults: defaults).writable)
    _ = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false })
    #expect(LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false }).safeModeAfterFailedLaunches)
  }

  @Test func aDistributionBuildRefusesTheScratchSuite() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "SOLARA_NATIVE_SHELL")
    let env = ["SOLARA_BACKGROUND": "1", LaunchSwitches.defaultsVariable: "scratch"]
    let switches = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: true, optionHeld: { false })
    #expect(switches.defaultsSuite == nil && !switches.usesDefaults)
    #expect(!switches.isOn(.nativeShell, defaultOn: false))
    #expect(!StoredLaunchSwitches(switches, defaults: defaults).writable)
    #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
  }

  @Test func theOptionQuestionIsAskedWithoutHoldingTheSwitchLock() {
    let cell = Mutex<LaunchSwitches?>(nil)
    let defaults = scratchDefaults()
    var lockFreeWhileAsking: [Bool] = []
    var answers: [Bool?] = []
    let build: (Bool?) -> LaunchSwitches = { answer in
      answers.append(answer)
      return LaunchSwitches.launching(
        environment: [:], defaults: defaults, distribution: true, optionHeld: { answer != nil }, confirmSafeMode: { answer ?? false })
    }
    let first = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(cell.withLockIfAvailable { _ in true } ?? false)
      return true
    }, build: build)
    #expect(lockFreeWhileAsking == [true])
    #expect(answers == [true])
    #expect(first.safeMode && first.isOn(.nativeShell))
    #expect(defaults.object(forKey: "SOLARA_NATIVE_SHELL") == nil)
    let again = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(false)
      return false
    }, build: build)
    #expect(lockFreeWhileAsking == [true], "once resolved, nothing asks again")
    #expect(again.safeMode && answers.count == 1)
  }
}
