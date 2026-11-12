import AppKit
import CoreGraphics

@MainActor
public final class TabNumberHintMonitor: NSObject {
  public static let shared = TabNumberHintMonitor()
  public static var isEligible: ((String) -> Bool)?
  private static let changed = Notification.Name("SolaraTabNumberHintsChanged")
  private static let cancellingEvents: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
  private static let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
  private var owner: ObjectIdentifier?
  private var monitor: Any?
  private var timer: Timer?
  private var hold = TabNumberHintHold()
  private weak var target: NSWindow?
  private var targetId: String?
  #if DEBUG
  private struct InputProbe {
    var windowId: String
    var modifiers: NSEvent.ModifierFlags = []
    var active = true
    var key = true
    var alone = true
    var queuedCancellation = false
  }
  private var inputProbe: InputProbe?
  #endif

  func start(owner: ObjectIdentifier) {
    stop()
    self.owner = owner
    monitor = NSEvent.addLocalMonitorForEvents(matching: Self.cancellingEvents) { [weak self] event in
      self?.receive(event)
      return event
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(activated), name: NSWindow.didBecomeKeyNotification, object: nil)
    center.addObserver(self, selector: #selector(deactivated), name: NSApplication.didResignActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(resignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    center.addObserver(self, selector: #selector(cancelled(_:)), name: .init("SolaraTabNumberHintsCancelled"), object: nil)
    center.addObserver(self, selector: #selector(shortcutsChanged), name: .init("SolaraMenuShortcutsChanged"), object: nil)
  }

  func stop(owner: ObjectIdentifier? = nil) {
    if let owner, self.owner != owner { return }
    cancel()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    NotificationCenter.default.removeObserver(self)
    self.owner = nil
    hold = TabNumberHintHold()
    #if DEBUG
    inputProbe = nil
    #endif
  }

  private func receive(_ event: NSEvent) {
    guard event.type == .flagsChanged else { return cancel() }
    receiveModifiers(event.modifierFlags, keyCode: event.keyCode)
  }

  private func receiveModifiers(_ modifiers: NSEvent.ModifierFlags, keyCode: UInt16? = nil) {
    let flags = Self.normalizedModifiers(modifiers)
    let alone = flags == .command && inputIsAlone && keyCode != 57
    let generation = hold.generation
    hold.modifiers(command: flags.contains(.command), alone: alone, now: ProcessInfo.processInfo.systemUptime)
    if !flags.contains(.command) || !alone {
      finishCancellation()
      return
    }
    guard hold.generation != generation, hold.deadline != nil else { return }
    guard applicationIsActive, let window = currentWindow, windowIsKey(window),
      let id = WindowManager.shared.id(of: window), Self.isEligible?(id) == true
    else { return cancel() }
    target = window
    targetId = id
    schedule()
  }

  private static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
  }

  private var inputIsAlone: Bool {
    #if DEBUG
    if let inputProbe { return inputProbe.alone }
    #endif
    return NSEvent.pressedMouseButtons == 0 && !(0..<128).contains { value in
      let code = CGKeyCode(value)
      return !Self.modifierKeyCodes.contains(code) && CGEventSource.keyState(.combinedSessionState, key: code)
    }
  }

  private var hasQueuedCancellation: Bool {
    #if DEBUG
    if let inputProbe { return inputProbe.queuedCancellation }
    #endif
    return NSApp.nextEvent(matching: Self.cancellingEvents, until: .distantPast, inMode: .default, dequeue: false) != nil
  }

  private var currentWindow: NSWindow? {
    #if DEBUG
    if let inputProbe { return WindowManager.shared.windows[inputProbe.windowId] }
    #endif
    return NSApp.keyWindow
  }

  private var applicationIsActive: Bool {
    #if DEBUG
    if let inputProbe { return inputProbe.active }
    #endif
    return NSApp.isActive
  }

  private var currentModifiers: NSEvent.ModifierFlags {
    #if DEBUG
    if let inputProbe { return inputProbe.modifiers }
    #endif
    return NSEvent.modifierFlags
  }

  private func windowIsKey(_ window: NSWindow) -> Bool {
    #if DEBUG
    if let inputProbe { return inputProbe.key && WindowManager.shared.windows[inputProbe.windowId] === window }
    #endif
    return window.isKeyWindow
  }

  #if DEBUG
  func devInput(windowId: String, action: String, modifiers: UInt) -> [String: Any] {
    guard ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" else { return ["error": "hidden instances only"] }
    switch action {
    case "begin":
      cancel()
      hold = TabNumberHintHold()
      guard WindowManager.shared.windows[windowId] != nil else { return ["error": "window unavailable"] }
      inputProbe = InputProbe(windowId: windowId)
    case "end":
      cancel()
      hold = TabNumberHintHold()
      inputProbe = nil
    case "state": break
    default:
      guard inputProbe?.windowId == windowId else { return ["error": "begin input probe first"] }
      switch action {
      case "flags":
        inputProbe?.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        receiveModifiers(currentModifiers)
      case "capsLock":
        inputProbe?.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        receiveModifiers(currentModifiers, keyCode: 57)
      case "key", "click": cancel()
      case "deactivate":
        inputProbe?.active = false
        deactivated()
      case "activate":
        inputProbe?.active = true
        activated()
      case "resignKey":
        inputProbe?.key = false
        if let target { resignedKey(Notification(name: NSWindow.didResignKeyNotification, object: target)) }
      case "queuedCancellation": inputProbe?.queuedCancellation = true
      default: return ["error": "unknown action"]
      }
    }
    return [
      "visible": hold.visible,
      "pending": hold.deadline != nil,
      "generation": String(hold.generation),
      "windowId": targetId ?? "",
      "eligible": Self.isEligible?(windowId) == true,
      "bindings": hold.visible ? MainMenu.tabNumberHintBindings() : [:],
    ]
  }
  #endif

  private func schedule() {
    timer?.invalidate()
    guard let deadline = hold.deadline else { return }
    let generation = hold.generation
    let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.expired(generation) }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func expired(_ generation: UInt64) {
    guard generation == hold.generation else { return }
    timer = nil
    guard let window = target, window === currentWindow, windowIsKey(window), applicationIsActive,
      let id = targetId, WindowManager.shared.id(of: window) == id, Self.isEligible?(id) == true,
      Self.normalizedModifiers(currentModifiers) == .command, inputIsAlone
    else { return cancel() }
    guard !hasQueuedCancellation else { return cancel() }
    if hold.expire(generation: generation, now: ProcessInfo.processInfo.systemUptime) {
      publish(visible: true)
    } else if hold.deadline != nil {
      schedule()
    }
  }

  private func cancel() {
    hold.interrupt()
    finishCancellation()
  }

  private func finishCancellation() {
    timer?.invalidate()
    timer = nil
    publish(visible: false)
    target = nil
    targetId = nil
  }

  private func publish(visible: Bool) {
    guard let target else { return }
    var info: [String: Any] = ["visible": visible, "bindings": visible ? MainMenu.tabNumberHintBindings() : [:]]
    #if DEBUG
    info["debugInput"] = inputProbe != nil
    #endif
    NotificationCenter.default.post(name: Self.changed, object: target, userInfo: info)
  }

  @objc private func activated() {
    hold.modifiers(
      command: currentModifiers.contains(.command), alone: false,
      now: ProcessInfo.processInfo.systemUptime)
    finishCancellation()
  }

  @objc private func deactivated() { cancel() }

  @objc private func resignedKey(_ note: Notification) {
    if let window = note.object as? NSWindow, window === target { cancel() }
  }

  @objc private func cancelled(_ note: Notification) {
    if let window = note.object as? NSWindow, window === target { cancel() }
  }

  @objc private func shortcutsChanged() {
    guard hold.visible else { return }
    guard let target, target === currentWindow, windowIsKey(target), applicationIsActive,
      let targetId, Self.isEligible?(targetId) == true,
      Self.normalizedModifiers(currentModifiers) == .command, inputIsAlone
    else { return cancel() }
    guard !hasQueuedCancellation else { return cancel() }
    publish(visible: true)
  }
}
