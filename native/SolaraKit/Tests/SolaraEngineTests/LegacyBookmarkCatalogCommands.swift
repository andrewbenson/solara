import Foundation
@testable import SolaraEngine

@MainActor extension LibraryCatalog {
  func historicalApplyBookmarks(ops: [BookmarkOperation], engineProfile: String) async throws -> BookmarkApplyResult {
    try await bookmarkAdmission?()
    if engineProfile.hasPrefix("incognito:") { throw LibraryCommandError.privateProfile }
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

}
