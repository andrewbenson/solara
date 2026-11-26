import Foundation
import SolaraModel
import SolaraStore

public enum PinnedPageCommand {
  public static let commands: Set<String> = ["reload", "forceReload", "returnToPinnedUrl", "handOffPin", "back", "forward"]

  public struct Plan: Equatable, Sendable {
    public let copy: Tab
    public let holder: Tab
    public let page: PageCommand?
    public let home: Bool
    public var moving: Bool { copy.id != holder.id }
    public func current(_ state: BrowserState) -> Bool {
      guard let next = PinnedPageCommand.plan("handOffPin", tabId: copy.id, state: state) else { return false }
      return next.copy.windowId == copy.windowId && next.copy.profileId == copy.profileId
        && next.copy.pinKeyOrId == copy.pinKeyOrId && next.copy.pinnedUrl == copy.pinnedUrl
        && next.copy.navigation == copy.navigation && next.copy.adoptId == copy.adoptId
        && next.holder.id == holder.id && next.holder.windowId == holder.windowId
        && next.holder.navigation == holder.navigation && next.holder.engine == holder.engine
        && next.holder.adoptId == holder.adoptId
    }
  }

  public struct Interactions {
    private var previous: BrowserState?
    private var revisions: [String: Int] = [:]

    public init(state: BrowserState? = nil) { previous = state }
    public subscript(_ windowId: String) -> Int { revisions[windowId, default: 0] }

    public mutating func receive(_ state: BrowserState, committing: Bool = false) {
      defer { previous = state }
      guard let previous, !committing else { return }
      for id in state.windows.keys where state.windows[id]?.activeTabIds != previous.windows[id]?.activeTabIds
        || state.windows[id]?.profileId != previous.windows[id]?.profileId || state.windowUi[id] != previous.windowUi[id] {
        revisions[id, default: 0] += 1
      }
    }
  }

  public static func pictureAfterCaptureTimeout(holder: String?, previous: String?) -> String? {
    holder ?? previous
  }

  public static func token(in presentation: [String: Any]) -> Int? {
    (presentation["token"] as? NSNumber)?.intValue
  }

  public struct Gate: Sendable {
    public let request: Int
    public let interaction: Int
    public let ownership: Int
    public let deadline: Double
    public init(request: Int, interaction: Int, ownership: Int, deadline: Double) {
      self.request = request
      self.interaction = interaction
      self.ownership = ownership
      self.deadline = deadline
    }
    public func allows(request: Int, interaction: Int, ownership: Int, now: Double) -> Bool {
      self.request == request && self.interaction == interaction && self.ownership == ownership && now < deadline
    }

    @discardableResult
    public func perform(request: Int, interaction: Int, ownership: Int, now: Double, _ action: () throws -> Void) rethrows -> Bool {
      guard allows(request: request, interaction: interaction, ownership: ownership, now: now) else { return false }
      try action()
      return true
    }
  }

  public static func plan(_ command: String, tabId: String, state: BrowserState) -> Plan? {
    guard commands.contains(command), let copy = state.tabs[tabId] else { return nil }
    let holder = state.sharedPageHolder(tabId) ?? copy
    if copy.pageIn?.isEmpty == false, holder.id == copy.id { return nil }
    if command == "returnToPinnedUrl", copy.pinnedUrl?.isEmpty != false { return nil }
    let page: PageCommand? = switch command {
    case "reload": .reload
    case "forceReload": .forceReload
    case "back": .goBack
    case "forward": .goForward
    default: nil
    }
    return Plan(copy: copy, holder: holder, page: page,
      home: command == "returnToPinnedUrl")
  }

  public static func presentation(tabId: String, state: BrowserState, token: Int, picture: String?,
    bridge: (copy: String, uri: String)?, dark: Bool) -> JSONObject? {
    guard state.tabs[tabId] != nil else { return nil }
    let copyId: String
    let uri: String?
    if state.sharedPageHolder(tabId) != nil {
      copyId = tabId
      uri = picture
    } else if let bridge, state.sharedPageHolder(bridge.copy)?.id == tabId {
      copyId = bridge.copy
      uri = bridge.uri
    } else { return nil }
    return ["token": .number(Double(token)), "tabId": .string(tabId), "copyId": .string(copyId),
      "uri": uri.map(JSONValue.string) ?? .null, "dark": .bool(dark)]
  }
}
