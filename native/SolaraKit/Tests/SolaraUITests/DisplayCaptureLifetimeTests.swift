import Testing
import SolaraUI

struct DisplayCaptureLifetimeTests {
  private func page(_ id: String = "caller", browser: Int32 = 1, profile: String = "regular") -> DisplayCaptureLifetime.Page {
    .init(tabID: id, browserID: browser, profile: profile)
  }

  @Test func answersOnceAndFencesReplacementAndNavigation() {
    var state = DisplayCaptureLifetime()
    let first = state.offer("one", on: page()).receipt
    let second = state.offer("two", on: page()).receipt
    let replacedAnswer = state.answer(first, source: "screen", target: nil)
    #expect(!replacedAnswer)
    let acceptedAnswer = state.answer(second, source: "screen", target: nil)
    #expect(acceptedAnswer)
    let duplicateAnswer = state.answer(second, source: "screen", target: nil)
    #expect(!duplicateAnswer)
    let third = state.offer("three", on: page()).receipt
    let closedOffer = state.close(page())
    #expect(closedOffer == third)
    let answerAfterClose = state.answer(third, source: "screen", target: nil)
    #expect(!answerAfterClose)
    let replacementClose = state.close(page(browser: 2))
    #expect(replacementClose == nil)
  }

  @Test func stopRetiresThePendingAnswerAndTheStartingShare() {
    var state = DisplayCaptureLifetime()
    let target = page("source", browser: 2)
    let first = state.offer("one", on: page()).receipt
    state.stop(page())
    let lateAnswer = state.answer(first, source: "tab", target: target)
    #expect(!lateAnswer)
    let second = state.offer("two", on: page()).receipt
    let approved = state.answer(second, source: "tab", target: target)
    #expect(approved)
    #expect(state.share(for: target)?.target == target)
    state.stop(page())
    #expect(state.share(for: target) == nil)
  }

  @Test func privateTargetsAndLateSelectionAreFenced() {
    var state = DisplayCaptureLifetime()
    let first = state.offer("one", on: page()).receipt
    let privateAnswer = state.answer(first, source: "tab", target: page("private", browser: 2, profile: "private"))
    #expect(!privateAnswer)
    #expect(state.pending["caller"] == first)
    let second = state.offer("two", on: page(browser: 3)).receipt
    let staleAnswer = state.answer(first, source: "screen", target: nil)
    #expect(!staleAnswer)
    #expect(state.pending["caller"] == second)
  }

  @Test func dismissOnlyHidesOneBarAndRetargetResetsDismissal() throws {
    var state = DisplayCaptureLifetime()
    let target = page("source", browser: 2)
    let other = page("other", browser: 3)
    let receipt = state.offer("one", on: page()).receipt
    let approved = state.answer(receipt, source: "tab", target: target)
    #expect(approved)
    let share = try #require(state.share(for: target))
    state.dismiss(share.receipt, from: target)
    #expect(state.share(for: target) == nil)
    #expect(state.share(for: other)?.target == target)
    let retargeted = state.retarget(share.receipt, to: other)
    #expect(retargeted)
    #expect(state.share(for: target)?.target == other)
    #expect(state.share(for: other)?.target == other)
    state.ended(page(browser: 8))
    #expect(state.share(for: other) != nil)
    state.ended(page())
    #expect(state.share(for: other) == nil)
  }
}
