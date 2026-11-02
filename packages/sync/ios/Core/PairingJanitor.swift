import Foundation

final class PairingJanitor {
  private struct Scope: Equatable {
    let cid: String
    let folder: String
    let identity: Data
  }
  private struct Path: Hashable {
    let rid: Data
    let aid: Data?
    let kind: UInt8
  }
  private static let retention: UInt64 = 24 * 60 * 60 * 1000
  private var scope: Scope?
  private var firstSeen: [Path: UInt64] = [:]
  private var lastTime: UInt64?

  @discardableResult
  func observe(entries: [PairingSession.Entry], mailbox: PairingCoordinatingMailbox, now: UInt64?) -> Int {
    guard let now else { return 0 }
    let current = Scope(cid: mailbox.pairingCID, folder: mailbox.pairingFolder.path, identity: mailbox.pairingFolderIdentity)
    if scope != current {
      scope = current
      firstSeen.removeAll()
      lastTime = nil
    }
    guard lastTime.map({ now >= $0 }) != false else { return 0 }
    lastTime = now
    var remaining = PairingMailbox.bytesPerPass
    var due: [PairingSession.Entry] = []
    var selected = Set<Path>()
    for entry in entries.prefix(PairingMailbox.entriesPerPass) {
      guard entry.wire.count <= remaining else { break }
      remaining -= entry.wire.count
      guard let kind = PairingMailbox.Kind(rawValue: entry.kind.rawValue), kind.size == entry.wire.count,
        entry.rid.count == 16, entry.rid.contains(where: { $0 != 0 }),
        kind == .request ? entry.aid == nil : entry.aid?.count == 16 else { continue }
      let path = Path(rid: entry.rid, aid: entry.aid, kind: kind.rawValue)
      if firstSeen[path] == nil, firstSeen.count < PairingMailbox.entriesPerPass { firstSeen[path] = now }
      guard let first = firstSeen[path], now >= first, now - first >= Self.retention, selected.insert(path).inserted else { continue }
      due.append(entry)
    }
    if !due.isEmpty { mailbox.remove(expected: due) }
    return due.count
  }
}
