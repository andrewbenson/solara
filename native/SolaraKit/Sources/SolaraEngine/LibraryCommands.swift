import Foundation

public struct HistoryVisitPage: Codable, Sendable, Equatable {
  public var url: String
  public var title: String
  public var visitTimes: [Double]

  public init(url: String, title: String, visitTimes: [Double]) {
    self.url = url
    self.title = title
    self.visitTimes = visitTimes
  }
}

public struct HistoryImportRow: Codable, Sendable, Equatable {
  public var url: String
  public var title: String
  public var visits: Int
  public var lastVisit: Double

  public init(url: String, title: String, visits: Int, lastVisit: Double) {
    self.url = url
    self.title = title
    self.visits = visits
    self.lastVisit = lastVisit
  }
}

public struct BookmarkOperation: Codable, Sendable, Equatable {
  public var op: String
  public var id: String
  public var kind: String?
  public var title: String?
  public var url: String?
  public var addedAt: Double?
  public var syncKey: String?
  public var parent: String?
  public var index: Int?
  public var ifAbsent: Bool?

  enum CodingKeys: String, CodingKey {
    case op, id, parent, index, ifAbsent
    case kind = "k"
    case title = "t"
    case url = "u"
    case addedAt = "a"
    case syncKey = "key"
  }

  public init(op: String, id: String, kind: String? = nil, title: String? = nil, url: String? = nil, addedAt: Double? = nil, syncKey: String? = nil, parent: String? = nil, index: Int? = nil, ifAbsent: Bool? = nil) {
    self.op = op
    self.id = id
    self.kind = kind
    self.title = title
    self.url = url
    self.addedAt = addedAt
    self.syncKey = syncKey
    self.parent = parent
    self.index = index
    self.ifAbsent = ifAbsent
  }
}

public struct BookmarkApplyResult: Codable, Sendable, Equatable {
  public var applied: Int
  public var skipped: Int
  public var invalid: [String]

  public init(applied: Int, skipped: Int, invalid: [String]) {
    self.applied = applied
    self.skipped = skipped
    self.invalid = invalid
  }
}

public enum LibraryCommandError: Error {
  case privateProfile
}

public extension EngineClient {
  func deleteHistory(urls: [String], engineProfile: String) async throws { throw BookmarkReadUnavailable.unsupported }
  func importHistory(rows: [HistoryImportRow], engineProfile: String) async throws { throw BookmarkReadUnavailable.unsupported }
  func addHistoryVisits(pages: [HistoryVisitPage], toleranceMs: Double, engineProfile: String) async throws -> Int { throw BookmarkReadUnavailable.unsupported }
  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult { throw BookmarkReadUnavailable.unsupported }
}

@MainActor
public extension LibraryCatalog {
  func deleteHistory(urls: [String], engineProfile: String) async throws {
    try checkWritable(engineProfile)
    guard !urls.isEmpty else { return }
    try await client.deleteHistory(urls: urls, engineProfile: engineProfile)
  }

  func importHistory(rows: [HistoryImportRow], engineProfile: String) async throws {
    try checkWritable(engineProfile)
    guard !rows.isEmpty else { return }
    try await client.importHistory(rows: rows, engineProfile: engineProfile)
  }

  func addHistoryVisits(pages: [HistoryVisitPage], toleranceMs: Double, engineProfile: String) async throws -> Int {
    try checkWritable(engineProfile)
    guard !pages.isEmpty else { return 0 }
    return try await client.addHistoryVisits(pages: pages, toleranceMs: toleranceMs, engineProfile: engineProfile)
  }

  func applyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    try await bookmarkAdmission?()
    try checkWritable(engineProfile)
    guard externalBookmarkCommandsAvailable else { throw BookmarkCoordinatorError.ownershipUnavailable }
    if let claim = bookmarkClaim {
      try claim.validate(engine: engineProfile)
      let (receipt, result) = try await claim.pump.submit(operations: ops, engine: engineProfile)
      if bookmarkClaim === claim, (try? claim.validate(engine: engineProfile)) != nil { publishDesired(receipt.view) }
      return result
    }
    guard rawBookmarksAvailable else { throw BookmarkCoordinatorError.ownershipUnavailable }
    admittedRawBookmarkCommand = true
    let result = try await client.applyBookmarks(ops: ops, engineProfile: engineProfile)
    guard rawBookmarksAvailable else { throw BookmarkCoordinatorError.ownershipUnavailable }
    if bookmarkLibraries[engineProfile] == nil { Task { await start(engineProfiles: [engineProfile]) } }
    else { await bookmarkLibraries[engineProfile]?.reload() }
    return result
  }

  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws {
    try checkWritable(engineProfile)
    try await client.storeFavicon(page: page, source: source, data: data, engineProfile: engineProfile)
    favicons?.forgetMisses(engineProfile: engineProfile, pages: [page])
  }

  private func checkWritable(_ engineProfile: String) throws {
    if engineProfile.hasPrefix("incognito:") { throw LibraryCommandError.privateProfile }
  }
}
