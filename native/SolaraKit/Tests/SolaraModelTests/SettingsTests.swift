import SolaraModel
import Testing

@Suite struct SettingsTests {
  @Test func profileLaunchLoadingDefaultsToLazyAndKeepsAnExplicitChoice() {
    #expect(!Settings.defaults.loadAllProfilesAtLaunch)
    #expect(!Settings.hydrated(from: [:]).loadAllProfilesAtLaunch)
    let chosen = Settings.defaults.choosing(["loadAllProfilesAtLaunch": true])
    let restored = Settings.hydrated(from: chosen.json)
    #expect(restored.loadAllProfilesAtLaunch)
    #expect(restored.chosen?.contains("loadAllProfilesAtLaunch") == true)
  }

  @Test func freshProfileGetsDefaultsWithEmptyBookkeeping() {
    let settings = Settings.hydrated(from: nil)
    #expect(settings["hideToolbarWhileScrolling"] == false)
    #expect(settings.chosen == [])
    #expect(settings.inferred == [])
    #expect(settings.migrations == ["toolbarStaysOnScroll", "selectionSearchOff"])
    #expect(settings["showSelectionSearch"] == false)
  }

  @Test func selectionSearchTurnsOffOnceUnlessSomeoneChoseIt() {
    let untouched = Settings.migrateSaved(["showSelectionSearch": true, "chosen": [], "inferred": [], "migrations": ["toolbarStaysOnScroll"]])!
    #expect(untouched["showSelectionSearch"] == false)
    #expect(untouched["migrations"] == ["toolbarStaysOnScroll", "selectionSearchOff"])
    let inferred = Settings.migrateSaved(["showSelectionSearch": true, "chosen": ["showSelectionSearch", "sidebarWidth"], "inferred": ["showSelectionSearch", "sidebarWidth"], "migrations": []])!
    #expect(inferred["showSelectionSearch"] == false)
    #expect(inferred["chosen"] == ["sidebarWidth"])
    #expect(inferred["inferred"] == ["sidebarWidth"])
    let chosen = Settings.migrateSaved(["showSelectionSearch": true, "chosen": ["showSelectionSearch"], "inferred": [], "migrations": ["toolbarStaysOnScroll"]])!
    #expect(chosen["showSelectionSearch"] == true)
    let legacy = Settings.migrateSaved(["showSelectionSearch": true])!
    #expect(legacy["showSelectionSearch"] == true)
    let turnedOn = Settings.hydrated(from: nil).updated(["showSelectionSearch": true], fromSync: false)
    let relaunched = Settings.hydrated(from: try! JSONValue.parse(turnedOn.json.text()))
    #expect(relaunched["showSelectionSearch"] == true)
  }

  @Test func oldDefaultIsTurnedOffOnceAndStaysChosen() {
    var saved = Settings.defaults.values
    saved["hideToolbarWhileScrolling"] = true
    saved["chosen"] = ["hideToolbarWhileScrolling"]
    saved["inferred"] = []
    saved["migrations"] = nil
    let settings = Settings.hydrated(from: .object(saved))
    #expect(settings["hideToolbarWhileScrolling"] == false)
    #expect(settings.migrations?.contains("toolbarStaysOnScroll") == true)
    #expect(settings.chosen?.contains("hideToolbarWhileScrolling") == true)
  }

  @Test func turningItBackOnSurvivesRelaunch() {
    var saved = Settings.defaults.values
    saved["hideToolbarWhileScrolling"] = true
    saved["migrations"] = nil
    let settings = Settings.hydrated(from: .object(saved)).updated(["hideToolbarWhileScrolling": true], fromSync: false)
    let relaunched = Settings.hydrated(from: try! JSONValue.parse(settings.json.text()))
    #expect(relaunched["hideToolbarWhileScrolling"] == true)
  }

  @Test func legacySettingsWithoutChosenTreatEverySavedKeyAsChosen() {
    let settings = Settings.hydrated(from: ["searchEngine": "duckduckgo", "sidebarWidth": 240])
    #expect(settings.chosen == ["searchEngine", "sidebarWidth", "hideToolbarWhileScrolling", "migrations"])
    #expect(settings.inferred == settings.chosen)
  }

  @Test func theClassicPinnedTabLookIsOnlyEverAChoice() {
    #expect(Settings.defaults.values["classicPinnedTabs"] == nil)
    #expect(Settings.hydrated(from: nil).values["classicPinnedTabs"] == nil)
    let chose = Settings.hydrated(from: nil).updated(["classicPinnedTabs": true], fromSync: false)
    let relaunched = Settings.hydrated(from: try! JSONValue.parse(chose.json.text()))
    #expect(relaunched["classicPinnedTabs"] == true)
    #expect(relaunched.chosen?.contains("classicPinnedTabs") == true)
  }

  @Test func batterySaverMigration() {
    let migrated = Settings.migrateSaved(["batterySaver": false, "hideToolbarWhileScrolling": true, "chosen": ["batterySaver"]])!
    #expect(migrated["batterySaverWhen"] == "never")
    #expect(migrated["batterySaver"] == nil)
    #expect(migrated["hideToolbarWhileScrolling"] == false)
    #expect(migrated["migrations"] == ["toolbarStaysOnScroll", "selectionSearchOff"])
    #expect(migrated["chosen"] == ["batterySaverWhen"])
    #expect(Settings.migrateSaved(nil) == nil)
    let on = Settings.migrateSaved(["batterySaver": true, "chosen": ["batterySaver"], "inferred": []])!
    #expect(on["batterySaverWhen"] == "unplugged")
    let inferredOn = Settings.migrateSaved(["batterySaver": true, "chosen": ["batterySaver"], "inferred": ["batterySaver"]])!
    #expect(inferredOn["batterySaverWhen"] == nil)
    #expect(inferredOn["chosen"] == [])
  }

  @Test func newTabButtonFollowsATopNewTabPosition() {
    let migrated = Settings.migrateSaved(["newTabPosition": "top", "chosen": ["newTabPosition", "newTabButtonPosition"], "inferred": ["x"]])!
    #expect(migrated["newTabButtonPosition"] == "top")
    #expect(migrated["chosen"] == ["newTabPosition", "newTabButtonPosition"])
    #expect(migrated["inferred"] == ["x"])
  }

  @Test func choosingRecordsKeysAndClearsInferred() {
    var settings = Settings.hydrated(from: nil)
    settings.values["inferred"] = ["appearance", "tabLayout"]
    let next = settings.updated(["appearance": "dark"], fromSync: false)
    #expect(next.chosen == ["appearance"])
    #expect(next.inferred == ["tabLayout"])
    let synced = settings.updated(["tabLayout": "top"], fromSync: true)
    #expect(synced.chosen == [])
    #expect(synced.inferred == ["appearance", "tabLayout"])
  }

  @Test func linkModifiersStayApart() {
    var settings = Settings.hydrated(from: nil)
    settings.values["splitLinkModifier"] = "alt"
    let next = settings.updated(["peekModifier": "alt"], fromSync: false)
    #expect(next["splitLinkModifier"] == "altShift")
    #expect(next.chosen == ["peekModifier", "splitLinkModifier"])
    var peekAlt = Settings.hydrated(from: nil)
    peekAlt.values["peekModifier"] = "alt"
    #expect(peekAlt.updated(["splitLinkModifier": "alt"], fromSync: false)["peekModifier"] == "shift")
  }

  @Test func downloadsLoadUnderSavedIdsAndKeepLeftStaging() {
    let plain = Download(json: ["id": "d1", "state": "complete", "staging": "/tmp/s", "destination": "/Users/x/Downloads/a.zip"])
    let loaded = plain.loaded(at: 3)
    #expect(loaded.id == "saved-3")
    #expect(loaded.json["stagingId"] == nil)
    #expect(loaded.json["staging"] == nil)
    let webkit = Download(json: ["id": "wk-download-ABC", "state": "complete", "staging": "/tmp/s", "destination": "/Users/x/Downloads/a.zip"])
    #expect(webkit.loaded(at: 0).json["stagingId"] == "ABC")
    let downloading = Download(json: ["id": "d2", "state": "downloading", "staging": "/tmp/s"])
    #expect(downloading.persisted().state == "failed")
    #expect(downloading.loaded(at: 1).json.keys == ["id", "state"])
    #expect(Download(json: ["id": "p", "profile": "incognito:w@default"]).isPrivate)
    #expect(Download(json: ["id": "p", "offTheRecord": true]).isPrivate)
  }
}
