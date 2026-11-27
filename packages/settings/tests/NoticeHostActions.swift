import Foundation
import SolaraModel
import SolaraUI

@MainActor
enum NativeOnboarding {
  static func isActive(in windowId: String) -> Bool { false }
}

@MainActor
enum NewTabNoticeCatalog {
  static func notes(version: String, product: String) -> PostcardNotes? {
    guard let notes = NativeNewTabNotices.shared.notes, notes.version == version else { return nil }
    return notes
  }
}

@MainActor
final class NativeNewTabNotices {
  static let shared = NativeNewTabNotices()
  static let productName = "Solara"

  private var receipts = NewTabNoticeReceipts()
  private var sourceReceipt: String?
  private var sourceCheckInToken: String?
  private var pageReceipt: String?
  private(set) var checkInReceipt = UUID()
  private(set) var checkInDue = false
  private(set) var notes: PostcardNotes?
  var pending: NewTabNoticeReceipts.Pending? { receipts.pending }
  var page: NewTabNoticeReceipts.Page? { receipts.page }

  func present(_ kind: String, windowId: String, payload: JSONObject) {
    if let note = payload["notes"] {
      notes = try? JSONDecoder().decode(PostcardNotes.self, from: Data(note.text().utf8))
    }
    switch kind {
    case "checkInBanner":
      let visible = payload["visible"]?.bool == true
      let token = payload["token"]?.string
      if visible != checkInDue || token != sourceCheckInToken { checkInReceipt = UUID() }
      checkInDue = visible
      sourceCheckInToken = token
    case "releaseNotesPage":
      let receipt = payload["presentationId"]?.string
      if page?.windowId != windowId || pageReceipt != receipt {
        _ = receipts.open(version: "1.0", windowId: windowId)
      }
      pageReceipt = receipt
    case "releaseNotesPostcard":
      if page?.windowId == windowId, let id = page?.id { _ = receipts.close(id) }
      let receipt = payload["presentationId"]?.string
      if pending == nil || sourceReceipt != receipt {
        receipts.queue(NewTabNoticeReceipts.Pending(["version": "1.0", "since": 0]))
      }
      sourceReceipt = receipt
    default: break
    }
  }

  func subscribe(_ change: @escaping () -> Void) -> UUID { UUID() }

  func unsubscribe(_ id: UUID) {}

  func finishCheckIn(_ receipt: UUID, action: String, windowId: String, beforeUpdate: () -> Void) {
    guard checkInDue, receipt == checkInReceipt else { return }
    beforeUpdate()
    HostedViews.send("checkInBanner", windowId: windowId, "action", ["action": action, "token": sourceCheckInToken ?? ""])
  }

  func open(_ version: String, windowId: String, matching receipt: UUID? = nil, beforeUpdate: () -> Void = {}) {
    guard pending?.id == receipt else { return }
    beforeUpdate()
    HostedViews.send("releaseNotesPostcard", windowId: windowId, "open", ["presentationId": sourceReceipt ?? ""])
  }

  func retire(_ receipt: UUID, beforeUpdate: () -> Void) {
    guard pending?.id == receipt else { return }
    beforeUpdate()
    HostedViews.send("releaseNotesPostcard", windowId: "", "dismiss", [:])
  }

  func closePage(_ receipt: UUID?) {
    if let receipt { _ = receipts.close(receipt) }
  }

  func closePage(_ receipt: UUID?, beforeUpdate: () -> Void) {
    guard let page, page.id == receipt else { return }
    beforeUpdate()
    HostedViews.send("releaseNotesPage", windowId: page.windowId, "close", [:])
  }
}
