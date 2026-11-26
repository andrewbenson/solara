import Foundation

public struct CastLifecycle {
  public struct Page: Hashable, Sendable {
    public let tabID: String
    public let windowID: String
    public let profile: String
    public let browserID: Int32
    public let generation: UInt64

    public init(tabID: String, windowID: String, profile: String, browserID: Int32, generation: UInt64) {
      self.tabID = tabID
      self.windowID = windowID
      self.profile = profile
      self.browserID = browserID
      self.generation = generation
    }
  }

  public struct Sink: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: Int
    public let state: String
    public let modes: Int
    public let routeID: String
    public let status: String
    public let issue: String

    enum CodingKeys: String, CodingKey {
      case id, name, icon, state, modes, routeID = "routeId", status, issue
    }

    public init(id: String, name: String, icon: Int, state: String, modes: Int, routeID: String, status: String, issue: String) {
      self.id = id
      self.name = name
      self.icon = icon
      self.state = state
      self.modes = modes
      self.routeID = routeID
      self.status = status
      self.issue = issue
    }
  }

  public struct Dialog: Codable, Equatable, Sendable {
    public let id: Int32
    public let browserID: Int32
    public let open: Bool
    public let header: String
    public let permissionRejected: Bool
    public let castingStarted: Bool
    public let sinks: [Sink]

    enum CodingKeys: String, CodingKey {
      case id, browserID = "browserId", open, header, permissionRejected, castingStarted, sinks
    }

    public init(id: Int32, browserID: Int32, open: Bool, header: String = "", permissionRejected: Bool = false,
      castingStarted: Bool = false, sinks: [Sink] = []) {
      self.id = id
      self.browserID = browserID
      self.open = open
      self.header = header
      self.permissionRejected = permissionRejected
      self.castingStarted = castingStarted
      self.sinks = sinks
    }
  }

  public struct Route: Codable, Equatable, Sendable {
    public let id: String
    public let sink: String
    public let description: String
    public let source: String

    public init(id: String, sink: String, description: String = "", source: String = "") {
      self.id = id
      self.sink = sink
      self.description = description
      self.source = source
    }
  }

  public struct Receipt: Equatable, Sendable {
    public let page: Page
    public let dialogID: Int32
  }

  public struct Entry: Equatable, Sendable {
    public let receipt: Receipt
    public fileprivate(set) var dialog: Dialog
    public fileprivate(set) var screen = false
  }

  public enum Effect: Equatable, Sendable {
    case show(Int32), close(Int32), start(Int32, String, Int32), stop(Int32, String)
  }

  private struct Pending {
    let page: Page
    let token = UUID()
    var wantsOpen = true
    var valid = true
  }

  public private(set) var dialogs: [String: Entry] = [:]
  public private(set) var routes: [String: [Route]] = [:]
  private var watching: Set<String> = []
  private var pending: [Int32: Pending] = [:]
  private var lastDialog: [Int32: Int32] = [:]

  public init() {}

  public mutating func toggle(_ page: Page) -> Effect? {
    if let entry = dialogs[page.tabID], entry.receipt.page == page { return dismiss(entry.receipt) }
    if let request = pending[page.browserID] {
      if request.valid, request.page == page { pending[page.browserID]?.wantsOpen.toggle() }
      return nil
    }
    pending[page.browserID] = Pending(page: page)
    return .show(page.browserID)
  }

  public func pendingToken(for page: Page) -> UUID? { pending[page.browserID]?.token }

  public mutating func finishPending(_ page: Page, token: UUID) {
    if pending[page.browserID]?.token == token { pending[page.browserID] = nil }
  }

  public mutating func receive(_ dialog: Dialog, page: Page?) -> [Int32] {
    let old = dialogs.values.first { $0.dialog.id == dialog.id && $0.dialog.browserID == dialog.browserID }
    guard dialog.open else {
      if let old { dialogs[old.receipt.page.tabID] = nil }
      if dialog.id > lastDialog[dialog.browserID] ?? Int32.min { lastDialog[dialog.browserID] = dialog.id }
      return []
    }
    if let old {
      guard old.receipt.page == page else {
        dialogs[old.receipt.page.tabID] = nil
        return [dialog.id]
      }
      dialogs[old.receipt.page.tabID]?.dialog = dialog
      return []
    }
    guard dialog.id > lastDialog[dialog.browserID] ?? Int32.min else { return [] }
    lastDialog[dialog.browserID] = dialog.id
    let request = pending.removeValue(forKey: dialog.browserID)
    guard let page, page.browserID == dialog.browserID,
      request.map({ $0.valid && $0.wantsOpen && $0.page == page }) != false else { return [dialog.id] }
    let replaced = dialogs.updateValue(Entry(receipt: Receipt(page: page, dialogID: dialog.id), dialog: dialog), forKey: page.tabID)
    return replaced.map { [$0.dialog.id] } ?? []
  }

  public mutating func prune(current: (String) -> Page?) -> [Int32] {
    for browserID in Array(pending.keys) {
      if let entry = pending[browserID], current(entry.page.tabID) != entry.page { pending[browserID]?.valid = false }
    }
    let lost = dialogs.values.filter { current($0.receipt.page.tabID) != $0.receipt.page }
    for entry in lost { dialogs[entry.receipt.page.tabID] = nil }
    return lost.map { $0.dialog.id }.sorted()
  }

  public func entry(_ receipt: Receipt) -> Entry? {
    guard let entry = dialogs[receipt.page.tabID], entry.receipt == receipt else { return nil }
    return entry
  }

  public mutating func dismiss(_ receipt: Receipt) -> Effect? {
    guard entry(receipt) != nil else { return nil }
    dialogs[receipt.page.tabID] = nil
    return .close(receipt.dialogID)
  }

  public mutating func selectScreen(_ screen: Bool, receipt: Receipt) {
    guard let entry = entry(receipt), entry.dialog.sinks.contains(where: { $0.modes & 4 != 0 }) else { return }
    dialogs[receipt.page.tabID]?.screen = screen
  }

  public func start(_ receipt: Receipt, sinkID: String) -> Effect? {
    guard let entry = entry(receipt), let sink = entry.dialog.sinks.first(where: { $0.id == sinkID }),
      sink.state == "available" || (sink.state == "connected" && sink.routeID.isEmpty) else { return nil }
    let modes: [Int32] = entry.screen ? [4, 1, 2, 8] : [1, 2, 8, 4]
    guard let mode = modes.first(where: { sink.modes & Int($0) != 0 }) else { return nil }
    return .start(receipt.dialogID, sinkID, mode)
  }

  public func stop(_ receipt: Receipt, sinkID: String) -> Effect? {
    guard let sink = entry(receipt)?.dialog.sinks.first(where: { $0.id == sinkID }),
      sink.state == "connected", !sink.routeID.isEmpty else { return nil }
    return .stop(receipt.dialogID, sink.routeID)
  }

  public mutating func profilesToWatch(_ profiles: [String]) -> [String] {
    profiles.filter { watching.insert($0).inserted }
  }

  public mutating func forgetProfile(_ profile: String) {
    watching.remove(profile)
    routes[profile] = nil
  }

  @discardableResult
  public mutating func receiveRoutes(_ next: [Route], profile: String) -> Bool {
    guard watching.contains(profile), routes[profile] != next else { return false }
    routes[profile] = next
    return true
  }

  public func hasRoute(_ id: String, profile: String) -> Bool {
    routes[profile]?.contains { $0.id == id } == true
  }
}
