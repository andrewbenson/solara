import Testing
@testable import SolaraUI

struct PageLiveTests {
  @Test func mergesOnlyExistingFactsAndReportsWhetherTheyChanged() {
    var missing = PageLive(facts: nil)
    #expect(missing.apply(PageLivePatch(isLoading: true)) == false)
    #expect(missing.facts == nil)
    var live = PageLive()
    #expect(live.apply(PageLivePatch(isLoading: false)) == false)
    #expect(live.apply(PageLivePatch(isLoading: true)) == true)
    #expect(live.facts == PageLiveFacts(isLoading: true))
    #expect(live.apply(PageLivePatch(isLoading: true)) == false)
    #expect(live.apply(PageLivePatch(themeColor: .some("#abc"))) == true)
    #expect(live.apply(PageLivePatch(themeColor: .some(nil))) == true)
    #expect(live.facts?.themeColor == nil)
  }

  @Test func navigationWritesAllNavigationFactsButKeepsAudio() {
    var live = PageLive(facts: PageLiveFacts(playingAudio: true))
    let patch = live.navigation(url: "https://a.test/", isLoading: true, canGoBack: true, canGoForward: false, themeColor: "#abc", now: 0)
    #expect(patch == PageLivePatch(isLoading: true, canGoBack: true, canGoForward: false, themeColor: .some("#abc")))
    #expect(live.facts == PageLiveFacts(isLoading: true, canGoBack: true, playingAudio: true, themeColor: "#abc"))
    _ = live.navigation(url: "https://a.test/", isLoading: false, canGoBack: false, canGoForward: true, themeColor: nil, now: 1)
    #expect(live.facts == PageLiveFacts(canGoForward: true, playingAudio: true))
  }

  @Test func blankGuardMediaAndDownloadChangeOnlyTheirFields() {
    var live = PageLive(facts: PageLiveFacts(canGoBack: true, canGoForward: true, themeColor: "#abc"))
    #expect(live.markLoading() == PageLivePatch(isLoading: true))
    #expect(live.media(playing: true) == PageLivePatch(playingAudio: true))
    #expect(live.download() == PageLivePatch(isLoading: false))
    #expect(live.facts == PageLiveFacts(canGoBack: true, canGoForward: true, playingAudio: true, themeColor: "#abc"))
  }

  @Test func discardClearsVolatileFactsAndReadyClearsOnlyDiscarded() {
    var live = PageLive(facts: PageLiveFacts(isLoading: true, canGoBack: true, canGoForward: true, playingAudio: true, themeColor: "#abc"))
    #expect(live.discard() == PageLivePatch(isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false))
    #expect(live.discarded)
    #expect(live.facts == PageLiveFacts(themeColor: "#abc", discarded: true))
    #expect(live.facts?.discarded == live.discarded)
    live.ready()
    #expect(!live.discarded)
    #expect(live.facts?.discarded == live.discarded)
    #expect(live.facts == PageLiveFacts(themeColor: "#abc"))
  }

  @Test func restoreRequiresMatchingPageExistingFactsAndNoTruthyTheme() {
    var missing = PageLive(facts: nil)
    #expect(missing.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc") == nil)
    var live = PageLive()
    #expect(live.restore(tabURL: nil, page: "https://a.test/", color: "#abc") == nil)
    #expect(live.restore(tabURL: "https://b.test/", page: "https://a.test/", color: "#abc") == nil)
    #expect(live.restore(tabURL: "https://a.test/#x", page: "https://a.test/", color: "#abc") == PageLivePatch(themeColor: .some("#abc")))
    #expect(live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#def") == nil)
    var empty = PageLive(facts: PageLiveFacts(themeColor: ""))
    #expect(empty.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#def") != nil)
  }

  @Test func restoreUsesTheJavaScriptUTF16LengthLimit() {
    var live = PageLive()
    #expect(live.restore(tabURL: "a", page: "a", color: String(repeating: "😀", count: 33)) == nil)
    #expect(live.restore(tabURL: "a", page: "a", color: String(repeating: "😀", count: 32)) != nil)
  }

  @Test func restoredThemeSurvivesBlankAndLoadingThenExpiresExactly1500MillisecondsAfterFirstCompletion() {
    var live = PageLive()
    _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
    _ = live.navigation(url: "about:blank", isLoading: false, now: 10)
    #expect(live.settleAt == nil)
    _ = live.navigation(url: "https://a.test/#x", isLoading: true, now: 20)
    #expect(live.settleAt == nil)
    _ = live.navigation(url: "https://a.test/", isLoading: false, now: 100)
    #expect(live.settleAt == 1600)
    _ = live.navigation(url: "https://a.test/", isLoading: false, now: 900)
    #expect(live.settleAt == 1600)
    #expect(live.advance(to: 1599) == nil)
    #expect(live.facts?.themeColor == "#abc")
    #expect(live.advance(to: 1600) == PageLivePatch(themeColor: .some(nil)))
    #expect(live.facts?.themeColor == nil)
    #expect(live.advance(to: 1601) == nil)
  }

  @Test func subsequentLoadingDoesNotCancelTheOriginalGraceTimer() {
    var live = PageLive()
    _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
    _ = live.navigation(url: "https://a.test/", isLoading: false, now: 0)
    _ = live.navigation(url: "https://a.test/", isLoading: true, now: 500)
    #expect(live.advance(to: 1500) != nil)
    #expect(live.facts?.isLoading == true)
    #expect(live.facts?.themeColor == nil)
  }

  @Test func reportedColorOrDifferentPageReleasesRestoredThemeAndCancelsTimer() {
    for reported in [String?.some("#def"), nil] {
      var live = PageLive()
      _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
      _ = live.navigation(url: "https://a.test/", isLoading: false, now: 0)
      _ = live.navigation(url: reported == nil ? "https://b.test/" : "https://a.test/", isLoading: true, themeColor: reported, now: 500)
      #expect(live.facts?.themeColor == reported)
      #expect(live.settleAt == nil)
      #expect(live.advance(to: 1500) == nil)
    }
  }

  @Test func emptyReportedColorKeepsRestoreAndDiscardDoesNotReleaseIt() {
    var live = PageLive()
    _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
    _ = live.navigation(url: "https://a.test/", isLoading: false, themeColor: "", now: 0)
    _ = live.discard()
    live.ready()
    #expect(live.facts?.themeColor == "#abc")
    #expect(live.advance(to: 1500) != nil)
  }
}

extension PageLiveTests {
  @Test func duplicateSavedThemesUseTheLastValidMatchAgainstTheInitialLiveSnapshot() {
    var live = PageLive()
    let patch = live.restore(tabURL: "https://a.test/", themes: [
      PageLiveRestoredTheme(page: "https://a.test/", color: "#abc"),
      PageLiveRestoredTheme(page: "https://a.test/", color: "#def"),
      PageLiveRestoredTheme(page: "https://b.test/", color: "#123"),
    ])
    #expect(patch == PageLivePatch(themeColor: .some("#def")))
    #expect(live.facts?.themeColor == "#def")
  }
}

extension PageLiveTests {
  @Test func missingTabNavigationComputesRestoredThemeAndGraceWithoutMergingFacts() {
    var live = PageLive(facts: PageLiveFacts(canGoBack: true, playingAudio: true))
    _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
    let before = live.facts
    let patch = live.navigation(url: "https://a.test/", isLoading: false, now: 100, tabExists: false)
    #expect(patch == PageLivePatch(isLoading: false, canGoBack: false, canGoForward: false, themeColor: .some("#abc")))
    #expect(live.facts == before)
    #expect(live.settleAt == 1600)
    #expect(live.advance(to: 1600) == PageLivePatch(themeColor: .some(nil)))
    #expect(live.facts == PageLiveFacts(canGoBack: true, playingAudio: true))
  }

  @Test func missingTabNavigationCanReleaseRestoredThemeWithoutWritingReportedColor() {
    var live = PageLive()
    _ = live.restore(tabURL: "https://a.test/", page: "https://a.test/", color: "#abc")
    _ = live.navigation(url: "https://a.test/", isLoading: false, now: 0)
    let before = live.facts
    let patch = live.navigation(url: "https://a.test/", isLoading: true, themeColor: "#def", now: 100, tabExists: false)
    #expect(patch.themeColor == .some("#def"))
    #expect(live.facts == before)
    #expect(live.settleAt == nil)
    #expect(live.advance(to: 1500) == nil)
  }
}
