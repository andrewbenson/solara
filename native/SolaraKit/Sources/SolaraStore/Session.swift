import Foundation
import SolaraModel

public struct ParsedURL: Sendable, Equatable {
  public var `protocol`: String
  public var host: String
  public var hostname: String

  public init(protocol: String, host: String, hostname: String) {
    self.protocol = `protocol`
    self.host = host
    self.hostname = hostname
  }
}

public protocol WebAddressing: Sendable {
  func resolveInput(_ input: String, searchUrlPrefix: String) -> String
  func searchUrlPrefix(_ settings: Settings) -> String
  func parseURL(_ url: String) -> ParsedURL?
}

public struct PlainWebAddressing: WebAddressing {
  public init() {}

  public func resolveInput(_ input: String, searchUrlPrefix: String) -> String { input }
  public func searchUrlPrefix(_ settings: Settings) -> String { "https://www.google.com/search?q=" }

  public func parseURL(_ url: String) -> ParsedURL? {
    guard let colon = url.firstIndex(of: ":") else { return nil }
    let scheme = url[..<colon].lowercased()
    guard let first = scheme.first, first.isLetter, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
    let rest = url[url.index(after: colon)...]
    guard rest.hasPrefix("//") else { return ParsedURL(protocol: scheme + ":", host: "", hostname: "") }
    let authority = rest.dropFirst(2).prefix { !"/?#\\".contains($0) }
    let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    let hostname = hostPort.hasPrefix("[") ? String(hostPort.prefix { $0 != "]" }) + "]" : String(hostPort.prefix { $0 != ":" })
    let lowered = hostname.lowercased()
    let port = hostPort.dropFirst(hostname.count).dropFirst()
    let host = port.isEmpty || (scheme == "https" && port == "443") || (scheme == "http" && port == "80") ? lowered : "\(lowered):\(port)"
    return ParsedURL(protocol: scheme + ":", host: host, hostname: lowered)
  }
}

public struct StoreConfig: Sendable, Equatable {
  public var safeMode = false
  public var persistenceRefusal: String?
  public var handOffPinsImmediately = true
  public var earlyLaunchTab = true
  public var listeners: [SettleListener] = SettleListener.app
  public var syncOrigins = false
  public var replicaProfilesFromDisk = false
  public var profileDataTombstones: URL?

  public init() {}
}

public enum SettleListener: String, Sendable, Equatable, CaseIterable {
  case forgetClosedPrivateWindows
  case settleNesting
  case livePinTable
  case settlePeeks
  case mirror
  case noteOrderChoices
  case forgetClosedIncognito

  public static let app: [SettleListener] = [
    .forgetClosedPrivateWindows, .settleNesting, .livePinTable, .settlePeeks, .mirror, .noteOrderChoices, .forgetClosedIncognito,
  ]
}

public final class Session {
  public internal(set) var state: BrowserState
  public var memory: StoreMemory
  public let env: WebAddressing
  public let config: StoreConfig
  public var now: Double
  public var effects: [Effect] = []
  public var result: JSONValue? = nil
  var fromSyncOrigin = false
  var depth = 0
  var heard: BrowserState? = nil
  var mirroring = 0
  var itemSerial = 0
  var liveEffectsAppliedThrough = 0
  var liveEffectSources: [Int: PageLiveFacts] = [:]

  public init(state: BrowserState, memory: StoreMemory, env: WebAddressing, config: StoreConfig, now: Double) {
    self.state = state
    self.memory = memory
    self.env = env
    self.config = config
    self.now = now
  }

  func resume(state: BrowserState, memory: StoreMemory, now: Double) {
    self.state = state
    self.memory = memory
    self.now = now
    effects = []
    liveEffectsAppliedThrough = 0
    liveEffectSources = [:]
    result = nil
  }

  public func beginTransaction() {
    depth += 1
  }

  public func closeTransactions() {
    guard depth > 0 else { return }
    depth = 0
    hear()
  }

  public func endTransaction() {
    guard depth > 0 else { return }
    depth -= 1
    if depth == 0 { hear() }
  }

  public func newId(_ prefix: String) -> String { memory.ids.next(prefix) }

  public func navigationTo(_ url: String, userInitiated: Bool = false) -> Navigation {
    memory.navSeq += 1
    return Navigation(url: url, seq: Double(memory.navSeq), userInitiated: userInitiated ? true : nil)
  }

  public func nextPinChoice() -> Double {
    memory.lastPinChoice = max(now, memory.lastPinChoice + 1)
    return memory.lastPinChoice
  }

  public func emit(_ effect: Effect) {
    if case .swapTabs(let a, _) = effect { liveEffectSources[effects.count] = state.live[a] }
    effects.append(effect)
  }

  func emitLiveSwap(a: String, b: String, from source: BrowserState) {
    liveEffectSources[effects.count] = source.live[a]
    effects.append(.swapTabs(a: a, b: b))
  }

  public func set(_ next: BrowserState) {
    let prev = state
    var next = next
    next.pruneWindowLocalState(tabsChanged: next.tabs.changed(from: prev.tabs), windowsChanged: next.windows.changed(from: prev.windows))
    captureClosingWindows(before: prev, after: next)
    state = next
    settleLive()
    captureClosingWindowLiveChanges()
    if depth == 0 {
      notify(prev)
    } else {
      if heard == nil { heard = prev }
      if pageMoved(state, prev) { hear() }
    }
  }

  public func update(_ change: (inout BrowserState) -> Void) {
    var next = state
    change(&next)
    set(next)
  }

  public func transaction(_ run: () throws -> Void) rethrows {
    depth += 1
    defer {
      depth -= 1
      if depth == 0 { hear() }
    }
    try run()
  }

  func hear() {
    guard let prev = heard else { return }
    heard = nil
    if state == prev { return }
    let held = depth
    depth = 0
    notify(prev)
    depth = held
  }

  func pageMoved(_ s: BrowserState, _ prev: BrowserState) -> Bool {
    if s.tabs.changed(from: prev.tabs) {
      for id in s.tabs.changedIds(from: prev.tabs) where s.tabs[id]?.url != prev.tabs[id]?.url { return true }
    }
    for id in Set(s.live.keys).union(prev.live.keys) where s.live[id]?.isLoading != prev.live[id]?.isLoading { return true }
    return false
  }

  func notify(_ prev: BrowserState) {
    settleLive()
    for listener in config.listeners { run(listener, prev: prev) }
  }
}
