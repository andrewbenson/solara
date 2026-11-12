import Foundation
import SolaraModel

public struct BookmarkReceiptRead: Sendable {
  let id: UUID
  let engine: String
  let epoch: UInt64
  let watermark: UInt64
}

struct BookmarkReceiptRetention {
  var requests: JSMap<BookmarkStoredRequest>
  var expired: JSMap<String>
  var sequence: UInt64
  var changed: Bool
}

extension BookmarkDurability {
  func retention(_ input: BookmarkCheckpointInput) throws -> BookmarkReceiptRetention {
    var result = BookmarkReceiptRetention(requests: input.retainedRequests ?? requests, expired: expiredRequests, sequence: requestSequence, changed: requiresRetentionMigration)
    let terminals = input.terminalEngines ?? terminalEngines
    for (id, engine) in result.expired where terminals[engine] != nil {
      result.expired.removeValue(forKey: id)
      result.changed = true
    }
    if let id = input.requestID, let receipt = input.receipt {
      guard result.sequence < UInt64.max else { throw BookmarkCoordinatorError.invalidOperation("Bookmark request sequence exhausted") }
      guard result.requests[id] == nil, result.expired[id] == nil else { throw BookmarkCoordinatorError.conflictingRequest }
      result.sequence += 1
      result.requests[id] = BookmarkStoredRequest(payload: input.payload, receipt: receipt, order: result.sequence)
      result.changed = true
    }
    for id in input.acknowledgedRequestIDs {
      guard var request = result.requests[id.text], !request.delivered else { continue }
      request.delivered = true
      result.requests[id.text] = request
      result.changed = true
    }
    let protected = protectedReceiptIDs(result.requests)
    var safe: JSMap<Bool> = [:]
    let confirmingRead = input.receiptRead.flatMap { read in
      receiptsCanSettle(engine: read.engine, input: input, requireFacts: false) ? read : nil
    }
    let time = now()
    for (id, stored) in result.requests {
      let engine = stored.receipt.view.engine
      if safe[engine] == nil { safe[engine] = receiptsCanSettle(engine: engine, input: input) }
      var request = stored
      if !request.confirmed, let read = confirmingRead, JSKey(read.engine) == JSKey(engine), request.order <= read.watermark {
        request.confirmed = true
        result.changed = true
      }
      if safe[engine] == true && request.delivered && request.confirmed {
        if request.settledAtMs == nil, time.isFinite, time >= 0 {
          request.settledAtMs = time
          result.changed = true
        }
        if let settled = request.settledAtMs, time.isFinite, time >= settled, time - settled >= 300_000, !protected.contains(JSKey(id)) {
          result.requests.removeValue(forKey: id)
          result.expired[id] = engine
          result.changed = true
          continue
        }
      }
      result.requests[id] = request
    }
    return result
  }

  func receiptMaintenanceDelay() -> Double? {
    let protected = protectedReceiptIDs(requests)
    let deadline = requests.filter { id, _ in !protected.contains(JSKey(id)) }.values.compactMap { $0.settledAtMs.map { $0 + 300_000 } }.min()
    guard let deadline, now().isFinite else { return nil }
    let remaining = deadline - now()
    return remaining > 0 ? min(remaining, 300_000) : 30_000
  }

  private func protectedReceiptIDs(_ requests: JSMap<BookmarkStoredRequest>) -> Set<JSKey> {
    var protected = Set<JSKey>()
    let engines = Set(requests.values.map { JSKey($0.receipt.view.engine) })
    for engine in engines {
      let selected = requests.filter { JSKey($1.receipt.view.engine) == engine }
      let ordered = selected.filter { !$1.legacy }.sorted { $0.value.order > $1.value.order }
      protected.formUnion(ordered.prefix(32).map { JSKey($0.key) })
      let legacy = selected.filter { $1.legacy }.sorted { $0.value.receipt.view.revision > $1.value.receipt.view.revision }
      if !legacy.isEmpty {
        let threshold = legacy[min(31, legacy.count - 1)].value.receipt.view.revision
        protected.formUnion(legacy.filter { $0.value.receipt.view.revision >= threshold }.map { JSKey($0.key) })
      }
    }
    return protected
  }

  private func receiptsCanSettle(engine: String, input: BookmarkCheckpointInput, requireFacts: Bool = true) -> Bool {
    guard let view = input.views[engine], view.hasView, view.readyForSync,
      view.structuralBreak == nil, !view.requiresRead, view.inFlightTarget == nil,
      view.failedPushes == 0, view.retryNotBeforeMs == nil, (!requireFacts || view.facts.isEmpty),
      !input.activeReceiptReads.contains(JSKey(engine)), !(input.legacyPendingEngines ?? legacyPendingEngines).contains(JSKey(engine)),
      !(input.conflicts ?? conflicts).contains(where: { $0["engine"]?.string.map { JSKey($0) == JSKey(engine) } ?? true }),
      let base = input.bases[engine] else { return false }
    return BookmarkReconcile.operations(from: base, to: BookmarkFlat(document: view.document, engine: engine), engine: engine).isEmpty
  }
}
