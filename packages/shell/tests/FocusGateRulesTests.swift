import SolaraShellCore
import Testing

@Suite struct FocusGateRulesTests {
  @Test func aGateIsLiveOnlyBeforeItsDeadline() {
    #expect(FocusGateRules.live(now: 10.399, deadline: 10.4))
    #expect(!FocusGateRules.live(now: 10.4, deadline: 10.4))
    #expect(!FocusGateRules.live(now: 11, deadline: 10.4))
  }

  @Test func anEditActionPressedBeforeTheBarCommittedIsDropped() {
    #expect(FocusGateRules.pressedBeforeBarCommitted(pressedAt: 1, barCommittedAt: 2))
    #expect(!FocusGateRules.pressedBeforeBarCommitted(pressedAt: 2, barCommittedAt: 2))
    #expect(!FocusGateRules.pressedBeforeBarCommitted(pressedAt: nil, barCommittedAt: 2))
    #expect(!FocusGateRules.pressedBeforeBarCommitted(pressedAt: 1, barCommittedAt: nil))
  }

  @Test func anEditActionDuringALiveGateIsHeldAtItsPress() {
    #expect(FocusGateRules.deferral(pressedAt: 5, gateLive: true, hasGeneration: true, heldEmpty: false) == .hold(at: 5))
  }

  @Test func anEditActionWithoutAKeyOrClickIsHeldOnlyWhenNothingElseIs() {
    #expect(FocusGateRules.deferral(pressedAt: nil, gateLive: true, hasGeneration: true, heldEmpty: true) == .holdNow)
    #expect(FocusGateRules.deferral(pressedAt: nil, gateLive: true, hasGeneration: true, heldEmpty: false) == .dropWithoutOrigin)
  }

  @Test func anExpiredOrMissingGateDefersNothing() {
    #expect(FocusGateRules.deferral(pressedAt: 5, gateLive: false, hasGeneration: true, heldEmpty: true) == .notGated)
  }

  @Test func aGateWhoseClaimsAreAllGoneSettles() {
    #expect(FocusGateRules.deferral(pressedAt: 5, gateLive: true, hasGeneration: false, heldEmpty: true) == .settle)
  }

  @Test func aCommandKeyOrAClickGivesItsPressTime() {
    #expect(FocusGateRules.origin(of: .commandKeyDown, at: 4) == 4)
    #expect(FocusGateRules.origin(of: .mouseButton, at: 4) == 4)
    #expect(FocusGateRules.origin(of: .other, at: 4) == nil)
    #expect(FocusGateRules.origin(of: .focusMarker(subtype: 1), at: 4) == nil)
  }

  @Test func aDeferredFocusShortcutGivesItsKeysPressTime() {
    #expect(FocusGateRules.origin(of: .focusMarker(subtype: FocusGateRules.deferredFocusMarkerSubtype), at: 4) == 4)
  }

  @Test func aLateAcknowledgementIsDroppedOnlyWhenLaterKeysWereReplayed() {
    #expect(FocusGateRules.dropsLateAcknowledgement(acknowledgedAt: 1, gateClosedAt: 2, typedAfterAt: 1.5))
    #expect(!FocusGateRules.dropsLateAcknowledgement(acknowledgedAt: 1, gateClosedAt: 2, typedAfterAt: 0.5))
    #expect(!FocusGateRules.dropsLateAcknowledgement(acknowledgedAt: 3, gateClosedAt: 2, typedAfterAt: 4))
    #expect(!FocusGateRules.dropsLateAcknowledgement(acknowledgedAt: 1, gateClosedAt: nil, typedAfterAt: 4))
  }

  @Test func typingIsNotedForASecondAfterTheGateCloses() {
    #expect(FocusGateRules.notesTyping(now: 10.9, gateClosedAt: 10))
    #expect(!FocusGateRules.notesTyping(now: 11, gateClosedAt: 10))
    #expect(!FocusGateRules.notesTyping(now: 10, gateClosedAt: nil))
  }

  @Test func heldInputIsOrderedByPressTime() {
    #expect(FocusGateRules.insertionIndex(of: 2, among: [1, 3]) == 1)
    #expect(FocusGateRules.insertionIndex(of: 3, among: [1, 3]) == 2)
    #expect(FocusGateRules.insertionIndex(of: 0, among: [1, 3]) == 0)
    #expect(FocusGateRules.insertionIndex(of: 5, among: []) == 0)
  }

  @Test func onlyCommandXCVAAreEditKeys() {
    #expect(FocusGateRules.isEditKey(command: true, control: false, key: "V"))
    #expect(!FocusGateRules.isEditKey(command: true, control: true, key: "v"))
    #expect(!FocusGateRules.isEditKey(command: false, control: false, key: "v"))
    #expect(!FocusGateRules.isEditKey(command: true, control: false, key: "f"))
    #expect(!FocusGateRules.isEditKey(command: true, control: false, key: nil))
  }

  @Test func anUnhandledEditKeyIsAcknowledgedOnlyInTheWindowAndKeyEpochItWasPressedIn() {
    #expect(FocusGateRules.unhandledKey(tag: nil, current: [7, 1], windowIsKey: true) == .untagged)
    #expect(FocusGateRules.unhandledKey(tag: [7], current: [7, 1], windowIsKey: true) == .untagged)
    #expect(FocusGateRules.unhandledKey(tag: [7, 1], current: [7, 1], windowIsKey: true) == .acknowledge)
    #expect(FocusGateRules.unhandledKey(tag: [7, 1], current: [7, 2], windowIsKey: true) == .refuse)
    #expect(FocusGateRules.unhandledKey(tag: [7, 1], current: [7, 1], windowIsKey: false) == .refuse)
  }

  @Test func aSecondCommandKeepsTheKeysTypedAfterItAndDropsTheOnesBefore() {
    #expect(FocusGateRules.keepsAfterBegin(heldAt: 10.02, commandPressedAt: 10.01))
    #expect(FocusGateRules.keepsAfterBegin(heldAt: 10.01, commandPressedAt: 10.01))
    #expect(!FocusGateRules.keepsAfterBegin(heldAt: 10.0, commandPressedAt: 10.01))
  }

  @Test func aCommandWithoutAKeyOrClickBehindItDropsEverythingHeld() {
    #expect(!FocusGateRules.keepsAfterBegin(heldAt: 10.02, commandPressedAt: nil))
  }
}
