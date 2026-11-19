import SolaraShellCore
import Testing

@Suite struct BackTabShortcutTests {
  let browser = BackTabShortcut.Context(browserKeyWindow: true, attachedSheet: false, modal: false, markedText: false)
  let previousTab = BackTabShortcut.Binding(key: "\t", modifiers: [.control, .shift], enabled: true)

  @Test func controlShiftTabInABrowserWindowTakesTheBinding() {
    #expect(BackTabShortcut.binding(for: [.control, .shift], in: browser, among: [previousTab]) == 0)
  }

  @Test func plainShiftTabAlwaysReachesFields() {
    let shiftTab = BackTabShortcut.Binding(key: "\t", modifiers: [.shift], enabled: true)
    #expect(BackTabShortcut.binding(for: [.shift], in: browser, among: [shiftTab]) == nil)
  }

  @Test func otherWindowsSheetsModalsAndCompositionPassTheKeyOn() {
    var settings = browser
    settings.browserKeyWindow = false
    var sheet = browser
    sheet.attachedSheet = true
    var modal = browser
    modal.modal = true
    var composing = browser
    composing.markedText = true
    for context in [settings, sheet, modal, composing] {
      #expect(BackTabShortcut.binding(for: [.control, .shift], in: context, among: [previousTab]) == nil)
    }
  }

  @Test func theFirstEnabledMatchWins() {
    let disabled = BackTabShortcut.Binding(key: "\t", modifiers: [.control, .shift], enabled: false)
    let other = BackTabShortcut.Binding(key: "\t", modifiers: [.option, .shift], enabled: true)
    let second = BackTabShortcut.Binding(key: "\t", modifiers: [.control, .shift], enabled: true)
    #expect(BackTabShortcut.binding(for: [.control, .shift], in: browser, among: [disabled, other, second]) == 2)
    #expect(BackTabShortcut.binding(for: [.control, .shift], in: browser, among: [disabled]) == nil)
  }

  @Test func onlyTabBindingsWithTheExactModifiersMatch() {
    let letter = BackTabShortcut.Binding(key: "a", modifiers: [.control, .shift], enabled: true)
    #expect(BackTabShortcut.binding(for: [.control, .shift], in: browser, among: [letter]) == nil)
    #expect(BackTabShortcut.binding(for: [.control, .option, .shift], in: browser, among: [previousTab]) == nil)
  }
}
