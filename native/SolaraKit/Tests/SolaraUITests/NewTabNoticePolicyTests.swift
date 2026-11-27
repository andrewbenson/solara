import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

struct NewTabNoticePolicyTests {
  private let now = 800_000_000.0

  @Test func checkInBecomesDueAtSevenDaysAndCompletionSticks() {
    let trial = now - 604_800_000
    let saved: JSONValue = ["defaultBrowserTrialStartedAt": .number(trial)]
    #expect(!NewTabCheckIn(saved).isDue(at: now - 1))
    #expect(NewTabCheckIn(saved).isDue(at: now))
    #expect(!NewTabCheckIn(nil).isDue(at: now))
    var checkIn = NewTabCheckIn(saved)
    let completed = checkIn.complete(at: now)
    #expect(completed)
    let completedAgain = checkIn.complete(at: now + 1)
    #expect(!completedAgain)
    #expect(!checkIn.isDue(at: now + 1))
    #expect(checkIn.doneAt == now)
  }

  @Test func pendingVersionMustExistInCatalogAndExpiresAfterOneDay() throws {
    let record: JSONValue = ["version": "1.0", "since": .number(now)]
    let pending = try #require(NewTabNoticeReceipts.Pending(record))
    #expect(pending.isCurrent(at: now + 86_400_000))
    #expect(!pending.isCurrent(at: now + 86_400_001))
    #expect(NewTabNoticeReceipts.Pending(["version": "2.0", "since": .number(now)]) == nil)
    #expect(NewTabNoticeReceipts.Pending(["version": "1.0", "since": "invalid"]) == nil)
    #expect(NewTabNoticeCatalog.notes(version: "1.0", product: "Solara")?.title == "Hello, Solara")
  }

  @Test func replacingPendingInvalidatesBothOpenAndDismiss() throws {
    let record: JSONValue = ["version": "1.0", "since": .number(now)]
    let old = try #require(NewTabNoticeReceipts.Pending(record))
    let replacement = try #require(NewTabNoticeReceipts.Pending(record))
    var receipts = NewTabNoticeReceipts()
    receipts.queue(old)
    receipts.queue(replacement)
    let retiredOld = receipts.retire(old.id)
    #expect(!retiredOld)
    let openedOld = receipts.open(version: "1.0", windowId: "a", matching: old.id)
    #expect(!openedOld)
    #expect(receipts.pending == replacement)
    let openedReplacement = receipts.open(version: "1.0", windowId: "a", matching: replacement.id)
    #expect(openedReplacement)
    #expect(receipts.pending == nil)
    let reopened = receipts.open(version: "1.0", windowId: "a", matching: replacement.id)
    #expect(!reopened)
  }

  @Test func anExplicitPageNeedsNoPendingPostcardAndOldReceiptsCannotCloseItsReplacement() throws {
    var receipts = NewTabNoticeReceipts()
    let openedUnknown = receipts.open(version: "2.0", windowId: "a")
    #expect(!openedUnknown)
    let openedFirst = receipts.open(version: "1.0", windowId: "a")
    #expect(openedFirst)
    let old = try #require(receipts.page)
    let openedSecond = receipts.open(version: "1.0", windowId: "b")
    #expect(openedSecond)
    let replacement = try #require(receipts.page)
    let closedOld = receipts.close(old.id)
    #expect(!closedOld)
    #expect(receipts.page == replacement)
    let closedReplacement = receipts.close(replacement.id)
    #expect(closedReplacement)
    #expect(receipts.page == nil)
  }
}
