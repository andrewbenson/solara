import Foundation
import SolaraModel

public struct NewTabCheckIn: Equatable, Sendable {
  public let trialStartedAt: Double?
  public private(set) var doneAt: Double?

  public init(_ saved: JSONValue?) {
    trialStartedAt = saved?["defaultBrowserTrialStartedAt"]?.number
    doneAt = saved?["defaultBrowserCheckInDoneAt"]?.number
  }

  public var eligibleAt: Double? {
    guard doneAt == nil else { return nil }
    return trialStartedAt.map { $0 + 604_800_000 }
  }

  public func isDue(at now: Double) -> Bool {
    eligibleAt.map { now >= $0 } ?? false
  }

  public mutating func complete(at now: Double) -> Bool {
    guard isDue(at: now) else { return false }
    doneAt = now
    return true
  }
}

public enum NewTabNoticeCatalog {
  public static let versions: Set<String> = ["1.0"]

  public static func notes(version: String, product: String) -> PostcardNotes? {
    guard versions.contains(version) else { return nil }
    return PostcardNotes(
      version: version, date: "September 2026", title: "Hello, \(product)",
      summary: "The first release: a calm, fast browser that keeps your tabs, your pages and your focus in one place.",
      items: [
        .init(title: "A command bar for everything", body: "Search, type an address or jump to an open tab from the New Tab page, or from any page with ⌘L."),
        .init(title: "Split view", body: "Drag a tab onto the page to see two or three side by side, stacked or in columns."),
        .init(title: "Tab groups and pinned tabs", body: "Group related tabs, pin the ones you live in, and let Clean Up Tabs tidy the rest."),
        .init(title: "Picture in Picture that stays out of the way", body: "Stash a video at the edge of the screen; click its site name to jump back to the tab."),
        .init(title: "Bring everything with you", body: "Import bookmarks, history, passwords and open tabs from Chrome, Safari, Arc and more."),
        .init(title: "Profiles with their own colour", body: "Keep work and personal apart, each with its own theme on the New Tab page."),
      ])
  }
}

public struct NewTabNoticeReceipts {
  public struct Pending: Equatable, Sendable {
    public let id = UUID()
    public let version: String
    public let since: Double

    public init?(_ value: JSONValue) {
      guard let version = value["version"]?.string, NewTabNoticeCatalog.versions.contains(version),
        let since = value["since"]?.number, since.isFinite else { return nil }
      self.version = version
      self.since = since
    }

    public var expiry: Double { since + 86_400_000 }
    public func isCurrent(at now: Double) -> Bool { now <= expiry }
    public var document: JSONValue { ["version": .string(version), "since": .number(since)] }
  }

  public struct Page: Equatable, Sendable {
    public let id = UUID()
    public let windowId: String
    public let version: String
  }

  public private(set) var pending: Pending?
  public private(set) var page: Page?

  public init() {}

  public mutating func queue(_ pending: Pending?) { self.pending = pending }

  public mutating func open(version: String, windowId: String, matching receipt: UUID? = nil) -> Bool {
    guard NewTabNoticeCatalog.versions.contains(version),
      receipt == nil || (pending?.id == receipt && pending?.version == version) else { return false }
    pending = nil
    page = Page(windowId: windowId, version: version)
    return true
  }

  public mutating func retire(_ receipt: UUID) -> Bool {
    guard pending?.id == receipt else { return false }
    pending = nil
    return true
  }

  public mutating func close(_ receipt: UUID) -> Bool {
    guard page?.id == receipt else { return false }
    page = nil
    return true
  }

  public static func document(lastVersion: String, pending: Pending?) -> JSONObject {
    ["version": 1, "lastVersion": .string(lastVersion), "pending": pending?.document ?? .null]
  }
}
