import SolaraShellCore
import Testing

@Suite struct FocusKeyHoldTests {
  @Test func opensOnlyForAFocusMovingShortcutPressedInAPage() {
    #expect(FocusKeyHold.opens(focusMoving: true, pageFocused: true, markedText: false, gateOpen: false, holding: false, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: false, pageFocused: true, markedText: false, gateOpen: false, holding: false, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: true, pageFocused: false, markedText: false, gateOpen: false, holding: false, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: true, pageFocused: true, markedText: true, gateOpen: false, holding: false, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: true, pageFocused: true, markedText: false, gateOpen: true, holding: false, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: true, pageFocused: true, markedText: false, gateOpen: false, holding: true, isRepeat: false))
    #expect(!FocusKeyHold.opens(focusMoving: true, pageFocused: true, markedText: false, gateOpen: false, holding: false, isRepeat: true))
  }

  @Test func lettersTypedBeforeTheCapAreHeldInOrder() {
    var hold = FocusKeyHold(command: "findInPage", pressedAt: 10)
    for step in 1...6 { #expect(hold.keyDown(command: false, at: 10 + Double(step) * 0.001) == .hold) }
    #expect(hold.held == 6)
  }

  @Test func aShortcutBeforeAnyLetterPassesAndOneAfterALetterIsHeldInOrder() {
    var hold = FocusKeyHold(command: "findInPage", pressedAt: 0)
    #expect(hold.keyDown(command: true, at: 0.01) == .pass)
    #expect(hold.held == 0)
    #expect(hold.keyDown(command: false, at: 0.02) == .hold)
    #expect(hold.keyDown(command: true, at: 0.03) == .hold)
    #expect(hold.held == 2)
  }

  @Test func aKeyAtOrPastTheCapReleasesTheHold() {
    var hold = FocusKeyHold(command: "findInPage", pressedAt: 5)
    #expect(hold.keyDown(command: false, at: 5 + FocusKeyHold.cap - 0.001) == .hold)
    #expect(!hold.expired(at: 5 + FocusKeyHold.cap - 0.001))
    #expect(hold.expired(at: 5 + FocusKeyHold.cap))
    #expect(hold.keyDown(command: false, at: 5 + FocusKeyHold.cap) == .release)
    #expect(hold.held == 1)
  }

  @Test func aFullHoldReleasesInsteadOfDroppingKeys() {
    var hold = FocusKeyHold(command: "newTab", pressedAt: 0)
    for _ in 0..<FocusKeyHold.capacity { #expect(hold.keyDown(command: false, at: 0) == .hold) }
    #expect(hold.keyDown(command: false, at: 0) == .release)
    #expect(hold.held == FocusKeyHold.capacity)
  }

  @Test func millisecondsAreMeasuredFromThePress() {
    let hold = FocusKeyHold(command: "focusCommandBar", pressedAt: 100)
    #expect(hold.milliseconds(at: 100.0424) == 42)
    #expect(hold.milliseconds(at: 99) == 0)
  }

  @Test func aBeginSoonAfterAReleaseIsLate() {
    #expect(FocusKeyHold.beganLate(pressedAt: 1, released: 3, at: 1.2))
    #expect(!FocusKeyHold.beganLate(pressedAt: 1, released: 0, at: 1.2))
    #expect(!FocusKeyHold.beganLate(pressedAt: 1, released: 3, at: 1 + FocusKeyHold.lateBeginWindow))
  }
}
