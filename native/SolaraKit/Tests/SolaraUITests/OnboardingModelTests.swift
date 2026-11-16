import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingModelTests {
  @Test func stepOrderAndQuestionOrder() {
    #expect(OnboardingStep.order.map(\.rawValue) == ["intro", "source", "layout", "tabs", "look", "searchPrivacy", "pins", "home", "outro"])
    #expect(OnboardingQuestion.order.map(\.rawValue) == [
      "source", "tabs", "address", "cmdl", "newTab", "newTabPosition", "tidy", "quit", "windows", "tabsMore",
      "color", "appearance", "siteColor", "lookMore", "engine", "typed", "pins", "default", "links", "outro",
    ])
  }

  @Test func startWritesTheDocumentAndEndsTheTour() {
    let (model, services, _) = OnboardingFixture.make()
    model.start()
    #expect(model.windowId == "w1")
    #expect(model.step == .intro)
    #expect(model.session == 1)
    #expect(services.tourEnded == 1)
    let saved = OnboardingFixture.saved(services)
    #expect(saved["version"] == 1)
    #expect(saved["completedAt"] == .null)
    #expect(saved["step"] == "intro")
    #expect(saved["preset"] == "dia")
    #expect(saved["source"] == .null)
  }

  @Test func nextWalksQuestionsThenSteps() {
    let (model, _, _) = OnboardingFixture.make()
    model.start()
    model.go(.source)
    #expect(model.isFirstPage)
    model.next()
    #expect(model.step == .layout && model.sub == 0)
    model.next()
    #expect(model.step == .layout && model.sub == 1)
    model.next()
    model.next()
    #expect(model.step == .tabs && model.sub == 0)
  }

  @Test func backGoesToTheLastQuestionOfThePreviousStepButNeverToIntro() {
    let (model, _, _) = OnboardingFixture.make()
    model.start()
    model.go(.tabs)
    model.back()
    #expect(model.step == .layout && model.sub == 2)
    model.go(.source)
    model.back()
    #expect(model.step == .source && model.sub == 0)
  }

  @Test func topTabsHideTheAddressQuestion() {
    let (model, _, _) = OnboardingFixture.make()
    model.start(step: .layout)
    #expect(model.questions(for: .layout) == [.tabs, .address, .cmdl])
    model.choose(.tabs, "top")
    #expect(model.questions(for: .layout) == [.tabs, .cmdl])
  }

  @Test func sourcePicksThePreset() {
    let (model, services, _) = OnboardingFixture.make()
    model.start()
    model.chooseSource(.zen)
    #expect(model.preset == .arc)
    #expect(OnboardingFixture.saved(services)["preset"] == "arc")
    model.chooseSource(.chrome)
    #expect(model.preset == .dia)
    #expect(model.string("commandBarPlacement") == "field")
    model.chooseSource(.arc)
    #expect(model.string("commandBarPlacement") == "centred")
    #expect(model.value("cleanUpInactiveTabsAfterHours") == 12)
  }

  @Test func diaPresetPlacesNewTabsAndTheButtonAtTop() {
    #expect(OnboardingPreset.dia.settings["newTabPosition"] == "top")
    #expect(OnboardingPreset.dia.settings["newTabButtonPosition"] == "top")
  }

  @Test func chosenSettingsBeatThePreset() {
    let (model, _, store) = OnboardingFixture.make()
    store.updateSettings(["addressBar": "toolbar"])
    model.start()
    model.chooseSource(.arc)
    #expect(model.string("addressBar") == "toolbar")
    #expect(model.string("commandBarPlacement") == "centred")
  }

  @Test func livePreviewsNeverMarkChosenAndRevertOnSkip() {
    let (model, services, store) = OnboardingFixture.make()
    model.start(step: .layout)
    model.chooseSource(.arc)
    model.choose(.tabs, "top")
    #expect(services.windowLayout["w1"] == "top")
    #expect(store.patches.isEmpty)
    model.skip()
    #expect(services.windowLayout["w1"] == "sidebar")
    #expect(model.step == .tabs)
    #expect(model.draft["tabLayout"] == nil)
    #expect(store.patches.isEmpty)
  }

  @Test func confirmWritesThroughTheStoreAndKeepsTheChoice() {
    let (model, services, store) = OnboardingFixture.make()
    model.start(step: .layout)
    model.chooseSource(.arc)
    model.choose(.address, "sidebar")
    #expect(services.previews.last == ["addressBar": "sidebar"])
    model.go(.layout, sub: 1)
    model.confirmCurrent()
    #expect(store.patches == [["addressBar": "sidebar"]])
    #expect(store.settings.chosen == ["addressBar"])
    #expect(model.picked[.address] == ["Address in the sidebar"])
    #expect(model.baseline["addressBar"] == nil)
    model.finish()
    #expect(store.settings.string("addressBar") == "sidebar")
  }

  @Test func layoutStepPreviewsAllItsKeysOnEntry() async {
    let (model, services, _) = OnboardingFixture.make()
    model.start(step: .layout)
    model.chooseSource(.arc)
    await model.enter(.layout)
    #expect(services.windowLayout["w1"] == "sidebar")
    #expect(services.previews.last == ["addressBar": "sidebar", "commandBarPlacement": "centred"])
    #expect(model.styleTag == "Arc-style")
    model.finish()
    #expect(services.previews.last == ["addressBar": "toolbar", "commandBarPlacement": "field"])
  }

  @Test func styleTag() {
    let (model, _, _) = OnboardingFixture.make()
    model.start(step: .layout)
    #expect(model.styleTag == "Dia-style")
    model.choose(.cmdl, "centred")
    #expect(model.styleTag == "Your mix")
    model.choose(.tabs, "top")
    model.choose(.cmdl, "field")
    #expect(model.styleTag == "Dia-style")
  }

  @Test func eachLayoutAndTabChoiceWritesWhatTheJSWrites() {
    let (model, _, store) = OnboardingFixture.make()
    model.start(step: .tabs)
    model.choose(.newTab, "commandBar")
    model.confirmCurrent()
    model.choose(.newTabPosition, "top")
    model.confirmCurrent()
    model.choose(.tidy, "tidy")
    model.confirmCurrent()
    model.choose(.quit, false)
    model.confirmCurrent()
    model.choose(.windows, true)
    model.confirmCurrent()
    model.setDraft(["peekModifier": "alt"])
    model.confirmCurrent()
    #expect(store.patches[0] == ["newTabOpens": "commandBar"])
    #expect(store.patches[1] == ["newTabPosition": "top", "newTabButtonPosition": "top"])
    #expect(store.patches[2] == ["cleanUpInactiveTabsAfterHours": 12])
    #expect(store.patches[3] == ["restoreSession": false])
    #expect(store.patches[4] == ["shareTabsAcrossWindows": true])
    #expect(store.patches[5] == ["balancedTopApps": false, "peekModifier": "alt", "undoReopensClosedTab": false, "cmdClickCreatesTabGroup": true])
    #expect(model.picked[.newTab] == ["⌘T opens the command bar"])
    #expect(model.picked[.newTabPosition] == [])
    #expect(model.picked[.tidy] == ["Old tabs tidy up after 12 hours"])
    #expect(model.picked[.quit] == ["Solara starts fresh each launch"])
    #expect(model.picked[.windows] == ["Windows share their tabs"])
    #expect(model.step == .look)
  }

  @Test func tidyLabelsAndCustomHours() {
    #expect(OnboardingModel.hoursLabel(12) == "12 hours")
    #expect(OnboardingModel.hoursLabel(24) == "1 day")
    #expect(OnboardingModel.hoursLabel(168) == "1 week")
    #expect(OnboardingModel.hoursLabel(48) == "48 hours")
    let (model, _, _) = OnboardingFixture.make()
    #expect(model.tidyOptions(48).map(\.title) == ["12 h", "1 day", "1 week", "48 hours"])
    model.start(step: .tabs)
    model.go(.tabs, sub: 2)
    model.choose(.tidy, "keep")
    #expect(model.picked(for: .tidy) == ["Old tabs stay until you close them"])
    #expect(model.patch(for: .tidy) == ["cleanUpInactiveTabsAfterHours": nil])
  }

  @Test func newTabPositionTitlesFollowTheLayout() {
    let (model, _, _) = OnboardingFixture.make()
    model.start(step: .tabs)
    #expect(model.choices(.newTabPosition).map(\.title) == ["At the bottom", "At the top"])
    model.previewLive(["tabLayout": "top"])
    #expect(model.choices(.newTabPosition).map(\.title) == ["On the right", "On the left"])
  }

  @Test func lookStep() async {
    let (model, services, store) = OnboardingFixture.make()
    model.start(step: .look)
    await model.enter(.look)
    #expect(services.previews.last == ["appearance": "auto", "extendWebsiteColor": true])
    model.previewColor(.green)
    #expect(services.colors["w1"] == .green)
    #expect(model.accent == ProfileColorValue.green.swatch)
    model.confirmCurrent()
    #expect(model.picked[.color] == ["Green theme"])
    #expect(model.baseline["color"] == nil)
    model.choose(.appearance, "dark")
    model.confirmCurrent()
    #expect(model.picked[.appearance] == ["Appearance always dark"])
    model.choose(.siteColor, false)
    model.confirmCurrent()
    #expect(model.picked[.siteColor] == [])
    model.setExtras { $0.appIcon = "night" }
    model.change(["bookmarksBar": "always"])
    model.confirmCurrent()
    #expect(store.patches.last == ["hideToolbarWhileScrolling": false, "bookmarksBar": "always"])
    await Task.yield()
    await Task.yield()
    #expect(services.iconSet == ["night"])
    #expect(model.step == .searchPrivacy)
    model.finish()
    #expect(services.colors["w1"] == .green)
  }

  @Test func unconfirmedColorRevertsOnFinish() {
    let (model, services, _) = OnboardingFixture.make()
    model.start(step: .look)
    model.previewColor(.red)
    model.finish()
    #expect(services.colors["w1"] == .plum)
  }

  @Test func searchPreferences() {
    let (model, _, store) = OnboardingFixture.make()
    model.start(step: .searchPrivacy)
    #expect(model.shownEngines.map(\.id).contains("duckduckgo"))
    model.setDraft(["searchEngine": "duckduckgo"])
    model.confirmCurrent()
    #expect(store.patches.last == ["searchEngine": "duckduckgo"])
    #expect(model.picked[.engine] == ["Search with DuckDuckGo"])
    model.choose(.typed, "search")
    model.confirmCurrent()
    #expect(store.patches.last == ["commandBarPreference": "search"])
    #expect(model.step == .pins)
  }

  @Test func pinsPreselectFromHistoryAndPinOnlyNewOnes() {
    let (model, services, _) = OnboardingFixture.make()
    services.visits = [
      OnboardingHistoryVisit(url: "https://github.com/a", visits: 5),
      OnboardingHistoryVisit(url: "https://www.figma.com/file", visits: 9),
      OnboardingHistoryVisit(url: "https://linear.app/x", visits: 2),
      OnboardingHistoryVisit(url: "https://mail.google.com/", visits: 4),
    ]
    services.pinned = ["mail.google.com"]
    model.start(step: .pins)
    #expect(model.selectedPins == ["figma", "github"])
    #expect(model.pinsContinueTitle == "Pin 2 Tabs")
    model.togglePin("figma")
    model.togglePin("gmail")
    #expect(model.selectedPins == ["github", "gmail"])
    model.confirmCurrent()
    #expect(services.opened == [["github"]])
    #expect(model.picked[.pins] == ["2 apps pinned"])
  }

  @Test func defaultBrowserApply() async {
    let (model, services, _) = OnboardingFixture.make()
    model.start(step: .home)
    await model.loadSystem()
    #expect(model.setDefaultChoice && model.dockChoice && !model.loginChoice)
    model.setExtras { $0.login = true }
    await model.applySystem()
    #expect(services.setDefaultCalls == 1)
    #expect(services.loginCalls == [true])
    #expect(services.dockCalls == 1)
    #expect(model.picked[.defaultBrowser] == ["Solara is your default browser"])
    #expect(model.sub == 1)
  }

  @Test func defaultBrowserTrialIsRecorded() async {
    let (model, services, _) = OnboardingFixture.make()
    services.inDock = true
    model.start(step: .home)
    await model.loadSystem()
    model.setExtras {
      $0.setDefault = false
      $0.trial = true
    }
    await model.applySystem()
    #expect(model.picked[.defaultBrowser] == ["A week as your default browser"])
    #expect(model.defaultBrowserTrialStartedAt == services.clock)
    #expect(services.dockCalls == 0)
    #expect(services.loginCalls.isEmpty)
  }

  @Test func backgroundInstanceDoesNotOfferDefaultByDefault() async {
    let (model, services, _) = OnboardingFixture.make()
    services.backgroundInstance = true
    model.start(step: .home)
    await model.loadSystem()
    await model.applySystem()
    #expect(services.setDefaultCalls == 0)
    #expect(model.picked[.defaultBrowser] == [])
  }

  @Test func linksAndOutroThenTourHandOff() {
    let (model, services, store) = OnboardingFixture.make()
    model.start(step: .home)
    model.go(.home, sub: 1)
    model.choose(.links, false)
    model.confirmCurrent()
    #expect(store.patches.last == ["openLinksInLittleSolara": false])
    #expect(model.picked[.links] == ["Links from other apps open in a tab"])
    #expect(model.step == .outro)
    model.finish(tour: true)
    #expect(model.leaving)
    #expect(services.music.last == "stop 0.6")
    #expect(OnboardingFixture.saved(services)["completedAt"] == .number(services.clock))
    model.dismiss(session: model.session - 1)
    #expect(model.windowId == "w1")
    model.dismiss(session: model.session)
    #expect(model.windowId == nil)
    #expect(services.toursStarted == ["w1"])
  }

  @Test func sourceStep() async {
    let (model, services, _) = OnboardingFixture.make()
    model.start(step: .source)
    await model.loadSources()
    #expect(model.sourceTiles.map(\.name) == ["Arc", "Dia", "Chrome", "Safari", "Firefox", "Zen or Zen Twilight", "Brave Beta"])
    #expect(model.sourceTiles.filter { $0.app != nil }.map(\.id) == [.arc, .safari, .brave])
    model.chooseSource(.brave)
    #expect(model.canImport)
    model.startImport()
    #expect(services.imports == ["braveBeta"])
    #expect(model.importing == .brave)
    model.confirmCurrent()
    #expect(model.picked[.source] == ["Coming from Brave Beta"])
    model.go(.source)
    model.chooseSource(.firefox)
    #expect(!model.canImport)
    #expect(model.picked(for: .source) == ["Coming from Firefox"])
    model.chooseSource(.fresh)
    #expect(model.picked(for: .source) == ["Starting fresh"])
    let missing = BrowserSourceTile.detect { _ in false }
    #expect(missing.map(\.name) == ["Arc", "Dia", "Chrome", "Safari", "Firefox", "Zen or Zen Twilight", "Brave or Edge"])
  }

  @Test func skipFromTheLastStepFinishes() {
    let (model, _, _) = OnboardingFixture.make()
    model.start(step: .outro)
    model.skip()
    #expect(model.leaving)
  }

  @Test func maybeStartGates() {
    let (fresh, services, _) = OnboardingFixture.make()
    fresh.maybeStart()
    #expect(fresh.windowId == "w1")
    #expect(OnboardingFixture.saved(services)["startedAt"] == .number(services.clock))

    let (existing, existingServices, _) = OnboardingFixture.make()
    existingServices.session = true
    existing.maybeStart()
    #expect(existing.windowId == nil)
    #expect(existing.completedAt == existingServices.clock)

    let (gated, gatedServices, _) = OnboardingFixture.make()
    gatedServices.startsOnFirstLaunch = false
    gated.maybeStart()
    #expect(gated.windowId == nil)
    #expect(gatedServices.document == nil)
  }

  @Test func resumeRestoresStepSubSourceAndPicks() {
    let (model, services, _) = OnboardingFixture.make()
    services.document = #"{"version":1,"startedAt":1,"completedAt":null,"step":"layout","sub":7,"source":"arc","picked":{"source":["Coming from Arc"]}}"#
    model.maybeStart()
    #expect(model.step == .layout)
    #expect(model.sub == 2)
    #expect(model.preset == .arc)
    #expect(model.source == .arc)
    #expect(model.picked[.source] == ["Coming from Arc"])
    #expect(model.pickedLines == ["Coming from Arc"])

    let (intro, introServices, _) = OnboardingFixture.make()
    introServices.document = #"{"version":1,"startedAt":1,"completedAt":null,"step":"intro"}"#
    intro.maybeStart()
    #expect(intro.step == .source)
  }

  @Test func documentRoundTripKeepsJSKeysAndOrder() {
    let (model, services, _) = OnboardingFixture.make()
    services.document = #"{"version":1,"startedAt":1700000000000,"completedAt":null,"defaultBrowserCheckInDoneAt":5,"introMusicMuted":true}"#
    #expect(model.introMusicMuted)
    model.introMuted = model.introMusicMuted
    model.toggleIntroMute()
    #expect(services.document == #"{"version":1,"completedAt":null,"startedAt":1700000000000,"defaultBrowserCheckInDoneAt":5,"introMusicMuted":false}"#)
    #expect(services.music == ["mute false"])
    #expect(model.defaultBrowserCheckInDoneAt == 5)
    #expect(OnboardingDocument.stringify(["a": "q\"\n", "b": 1.5, "c": [true, nil]]) == #"{"a":"q\"\n","b":1.5,"c":[true,null]}"#)
  }

  @Test func introCuesMatchTheJS() {
    let cues = IntroMusicCues(letterCount: 6)
    #expect(abs(cues.tagline - 2.095) < 1e-9)
    #expect(abs(cues.exit - 3.795) < 1e-9)
    #expect(abs(cues.end - 4.445) < 1e-9)
  }

  @Test func rnSpringMatchesOrigami() {
    let card = SpringParams.origami(friction: 9, tension: 60)
    #expect(abs(card.stiffness - 302.6) < 1e-9 && card.damping == 28)
    let icon = SpringParams.origami(friction: 7, tension: 50)
    #expect(abs(icon.stiffness - 266.4) < 1e-9 && icon.damping == 22)
  }
}
