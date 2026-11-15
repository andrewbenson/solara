import Foundation

@MainActor
public final class ToolbarAutoHideController {
  public let windowId: String
  public let windowGeneration: UInt64
  public private(set) var facts: [String: WindowLayoutPageFacts] = [:]
  private var registrations: [String: PageRegistration] = [:]
  private var stopped = false

  public init(windowId: String, windowGeneration: UInt64) {
    self.windowId = windowId
    self.windowGeneration = windowGeneration
  }

  public func register(_ registration: PageRegistration) {
    guard !stopped, registrations[registration.tabID] != registration,
      registrations[registration.tabID].map({ $0.registrationGeneration < registration.registrationGeneration }) ?? true else { return }
    registrations[registration.tabID] = registration
    facts[registration.tabID] = WindowLayoutPageFacts(registration: String(registration.registrationGeneration))
  }

  public func retire(_ registration: PageRegistration) {
    guard current(registration) else { return }
    registrations[registration.tabID] = nil
    facts[registration.tabID] = nil
  }

  @discardableResult
  public func noteScroll(_ registration: PageRegistration, state: String) -> Bool {
    guard current(registration), ["down", "up", "top"].contains(state), let value = facts[registration.tabID] else { return false }
    facts[registration.tabID] = WindowLayoutPageFacts(registration: value.registration, fullscreen: value.fullscreen,
      scrolledDown: state == "down", peek: false)
    return true
  }

  @discardableResult
  public func setPeek(_ registration: PageRegistration, on: Bool) -> Bool {
    guard current(registration), let value = facts[registration.tabID] else { return false }
    facts[registration.tabID] = WindowLayoutPageFacts(registration: value.registration, fullscreen: value.fullscreen,
      scrolledDown: value.scrolledDown, peek: on)
    return true
  }

  @discardableResult
  public func setFullscreen(_ registration: PageRegistration, on: Bool) -> Bool {
    guard current(registration), let value = facts[registration.tabID] else { return false }
    facts[registration.tabID] = WindowLayoutPageFacts(registration: value.registration, fullscreen: on,
      scrolledDown: value.scrolledDown, peek: value.peek)
    return true
  }

  public func reveal(tabId: String) {
    guard !stopped, let value = facts[tabId] else { return }
    facts[tabId] = WindowLayoutPageFacts(registration: value.registration, fullscreen: value.fullscreen)
  }

  public func retain(tabIds: Set<String>) {
    guard !stopped else { return }
    registrations = registrations.filter { tabIds.contains($0.key) }
    facts = facts.filter { tabIds.contains($0.key) }
  }

  public func stop() {
    stopped = true
    registrations = [:]
    facts = [:]
  }

  private func current(_ registration: PageRegistration) -> Bool {
    !stopped && registrations[registration.tabID] == registration
  }
}
