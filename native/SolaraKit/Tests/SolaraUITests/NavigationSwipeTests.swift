import Testing
@testable import SolaraUI

@MainActor
struct NavigationSwipeTests {
  @Test func trackedConfirmationReversalAndCancellation() {
    var swipe = NavigationSwipeInteraction()
    let token = swipe.begin(.back)
    swipe.move(distance: 75, dy: 0, at: 1)
    #expect(swipe.confirmed && swipe.width == 82)
    swipe.move(distance: 20, dy: 0, at: 1.1)
    #expect(!swipe.confirmed && swipe.width == 72)
    #expect(swipe.end(cancelled: true) == nil)
    swipe.receive([.init(title: "Old", url: "old", offset: -1)], token: token)
    #expect(swipe.items.isEmpty && !swipe.active)
  }

  @Test func discreteAndRepeatedEndNavigateOnlyOnce() {
    var swipe = NavigationSwipeInteraction()
    _ = swipe.begin(.forward)
    swipe.move(distance: 75, dy: 0, at: 0)
    #expect(swipe.end(cancelled: false) == .step(.forward))
    #expect(swipe.end(cancelled: false) == nil)
  }

  @Test func historyWaitsForIdleAndSelectsTheDestination() {
    var swipe = NavigationSwipeInteraction()
    let token = swipe.begin(.back)
    swipe.move(distance: 75, dy: 10, at: 0)
    swipe.receive([.init(title: "Two", url: "two", offset: -1), .init(title: "One", url: "one", offset: -2)], token: token)
    swipe.expand(at: 0.29, height: 600)
    #expect(!swipe.listShown)
    swipe.expand(at: 0.31, height: 600)
    #expect(swipe.listShown && swipe.width == 200)
    swipe.move(distance: 75, dy: 85, at: 0.4)
    #expect(swipe.selected == 1)
    #expect(swipe.end(cancelled: false) == .item(.init(title: "One", url: "one", offset: -2)))
  }

  @Test func anObsoleteResponseCannotPopulateANewGesture() {
    var swipe = NavigationSwipeInteraction()
    let old = swipe.begin(.back)
    _ = swipe.end(cancelled: true)
    _ = swipe.begin(.forward)
    swipe.receive([.init(title: "Old", url: "old", offset: -1)], token: old)
    #expect(swipe.items.isEmpty)
  }

  @Test func invalidationForPageCloseReplacementOrPaneRetirementCancelsNavigation() {
    var swipe = NavigationSwipeInteraction()
    let token = swipe.begin(.back)
    swipe.move(distance: 100, dy: 0, at: 0)
    swipe.invalidate()
    swipe.receive([.init(title: "Old", url: "old", offset: -1)], token: token)
    #expect(swipe.end(cancelled: false) == nil)
    #expect(!swipe.listShown)
  }

  @Test func syntheticNewTabDestinationKeepsItsCompatibilityIdentity() {
    var swipe = NavigationSwipeInteraction()
    let token = swipe.begin(.back)
    let newTab = NavigationSwipeItem(title: "New Tab", url: "", offset: -1, newTab: true)
    swipe.receive([.init(title: "First", url: "first", offset: -1), newTab], token: token)
    swipe.move(distance: 75, dy: 0, at: 0)
    swipe.expand(at: 0.31, height: 600)
    swipe.move(distance: 75, dy: 75, at: 0.4)
    #expect(swipe.end(cancelled: false) == .item(newTab))
  }

  @Test func aDiscreteSwipeAndItsTrailingEndCannotNavigateTwice() {
    let controller = NavigationSwipeController()
    var actions: [NavigationSwipeAction] = []
    controller.isCurrent = { true }
    controller.navigate = { actions.append($0) }
    controller.input(phase: "swipe", direction: .back, distance: 0, dy: 0)
    controller.input(phase: "ended", direction: .back, distance: 75, dy: 0)
    #expect(actions == [.step(.back)])
    controller.stop()
  }

  @Test func replacementRejectsAHistoryReplyAndThePendingEnd() {
    let controller = NavigationSwipeController()
    var current = true
    var reply: (([NavigationSwipeItem]) -> Void)?
    var actions: [NavigationSwipeAction] = []
    controller.isCurrent = { current }
    controller.loadHistory = { _, callback in reply = callback }
    controller.navigate = { actions.append($0) }
    controller.input(phase: "began", direction: .back, distance: 75, dy: 0)
    current = false
    reply?([.init(title: "Old", url: "old", offset: -1), .init(title: "Older", url: "older", offset: -2)])
    controller.input(phase: "ended", direction: .back, distance: 75, dy: 0)
    #expect(actions.isEmpty && !controller.capsule.active)
  }

  @Test func unfocusedSplitAndPeekControllersNavigateTheirOwnPage() {
    let split = NavigationSwipeController()
    let peek = NavigationSwipeController()
    var actions: [String] = []
    split.isCurrent = { true }
    peek.isCurrent = { true }
    split.navigate = { _ in actions.append("split") }
    peek.navigate = { _ in actions.append("peek") }
    split.input(phase: "swipe", direction: .back, distance: 0, dy: 0)
    peek.input(phase: "swipe", direction: .forward, distance: 0, dy: 0)
    #expect(actions == ["split", "peek"])
    split.stop()
    peek.stop()
  }

}
