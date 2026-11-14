import AppKit

@MainActor
protocol PromptInputProtectionOwner: AnyObject {
  var inputProtection: PromptInputProtection { get }
}

@MainActor
final class PromptInputProtection: NSObject {
  static let delay: TimeInterval = 0.5
  var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  var enabled = false {
    didSet {
      guard enabled != oldValue else { return }
      if enabled { shown() }
    }
  }
  private weak var view: NSView?
  private var protectedUntil = Double.infinity

  isolated deinit { NotificationCenter.default.removeObserver(self) }

  func shown() { protectedUntil = now() + Self.delay }

  func attach(to view: NSView) {
    NotificationCenter.default.removeObserver(self)
    self.view = view
    guard let window = view.window else { return }
    shown()
    NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func windowBecameKey() { shown() }

  @objc private func applicationBecameActive() {
    if view?.window?.isKeyWindow == true { shown() }
  }

  func allows(_ event: NSEvent? = nil) -> Bool {
    guard enabled else { return true }
    guard now() >= protectedUntil else { return false }
    guard let event else { return true }
    let repeatedKey = (event.type == .keyDown || event.type == .keyUp) && event.isARepeat
    return event.timestamp >= protectedUntil && !repeatedKey
  }

  static func allows(_ view: NSView, event: NSEvent? = nil) -> Bool {
    var current: NSView? = view
    while let candidate = current {
      if let owner = candidate as? PromptInputProtectionOwner, !owner.inputProtection.allows(event) { return false }
      current = candidate.superview
    }
    return true
  }
}
