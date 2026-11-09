import CryptoKit
import Darwin
import Foundation
import SolaraModel

public struct BookmarkRecoveryNotice: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case unreadableJournal
    case newerJournalVersion
    case unavailableJournal
  }
  public let kind: Kind
  public let message: String
  public let preservedPath: String?
  public init(kind: Kind, message: String, preservedPath: String? = nil) {
    self.kind = kind
    self.message = message
    self.preservedPath = preservedPath
  }
}

public struct BookmarkPendingLoad: Sendable {
  public let payload: JSONValue?
  public let recoveryNotice: BookmarkRecoveryNotice?
  public let writable: Bool
}

public struct BookmarkPendingFileOperations {
  public var read: (URL) throws -> Data
  public var writeNew: (URL, Data) throws -> Void
  public var syncFile: (URL) throws -> Void
  public var rename: (URL, URL) throws -> Void
  public var syncDirectory: (URL) throws -> Void
  public var remove: (URL) throws -> Void
  public var exists: (URL) -> Bool

  public init(read: @escaping (URL) throws -> Data, writeNew: @escaping (URL, Data) throws -> Void, syncFile: @escaping (URL) throws -> Void, rename: @escaping (URL, URL) throws -> Void, syncDirectory: @escaping (URL) throws -> Void, remove: @escaping (URL) throws -> Void, exists: @escaping (URL) -> Bool) {
    self.read = read
    self.writeNew = writeNew
    self.syncFile = syncFile
    self.rename = rename
    self.syncDirectory = syncDirectory
    self.remove = remove
    self.exists = exists
  }

  public static var live: Self {
    Self(
      read: { try Data(contentsOf: $0) },
      writeNew: { url, data in
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BookmarkPendingStoreError.io("open temporary journal", errno) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
          var written = 0
          while written < bytes.count {
            let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw BookmarkPendingStoreError.io("write temporary journal", amount == 0 ? EIO : errno) }
            written += amount
          }
        }
      },
      syncFile: { url in
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw BookmarkPendingStoreError.io("open journal for sync", errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw BookmarkPendingStoreError.io("fsync journal", errno) }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else { throw BookmarkPendingStoreError.io("full sync journal", errno) }
      },
      rename: { source, target in
        guard Darwin.rename(source.path, target.path) == 0 else { throw BookmarkPendingStoreError.io("rename journal", errno) }
      },
      syncDirectory: { url in
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw BookmarkPendingStoreError.io("open journal directory", errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw BookmarkPendingStoreError.io("fsync journal directory", errno) }
      },
      remove: { url in
        guard Darwin.unlink(url.path) == 0 || errno == ENOENT else { throw BookmarkPendingStoreError.io("remove temporary journal", errno) }
      },
      exists: { FileManager.default.fileExists(atPath: $0.path) }
    )
  }
}

public enum BookmarkPendingStoreError: Error, Equatable {
  case unavailable
  case invalidEnvelope
  case io(String, Int32)
  case savedUnconfirmed(String, Int32)
}

public final class BookmarkPendingStore {
  public static let journalName = "bookmarks-pending-native-v1.json"
  public let journalURL: URL
  private let directory: URL
  private let clock: () -> Double
  private let logger: (String) -> Void
  private let operations: BookmarkPendingFileOperations
  private let lock = NSRecursiveLock()
  private var loaded: BookmarkPendingLoad?

  public init(directory: URL, clock: @escaping () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) }, logger: @escaping (String) -> Void = { _ in }, fileOperations: BookmarkPendingFileOperations = .live) {
    self.directory = directory
    self.clock = clock
    self.logger = logger
    operations = fileOperations
    journalURL = directory.appendingPathComponent(Self.journalName)
  }

  public func load() -> BookmarkPendingLoad {
    lock.lock()
    defer { lock.unlock() }
    if let loaded { return loaded }
    guard operations.exists(journalURL) else {
      let result = BookmarkPendingLoad(payload: nil, recoveryNotice: nil, writable: true)
      loaded = result
      return result
    }
    do {
      let envelope = try JSONValue.parse(operations.read(journalURL))
      if let version = envelope.object?["version"], version != 1 && version != 2 {
        let notice = BookmarkRecoveryNotice(kind: .newerJournalVersion, message: "Bookmark changes were saved in a format this version of Solara can't read, so they were left untouched.", preservedPath: journalURL.path)
        logger("Bookmark journal has format \(version.text()), not 1 or 2, left untouched: \(journalURL.path)")
        let result = BookmarkPendingLoad(payload: nil, recoveryNotice: notice, writable: false)
        loaded = result
        return result
      }
      guard envelope["version"]?.number == 1 || envelope["version"]?.number == 2, let payload = envelope["payload"], let checksum = envelope["checksum"]?.string, Self.checksum(payload) == checksum else { throw BookmarkPendingStoreError.invalidEnvelope }
      let result = BookmarkPendingLoad(payload: payload, recoveryNotice: nil, writable: true)
      loaded = result
      return result
    } catch {
      return preserveUnreadable(reason: String(describing: error))
    }
  }

  public func recoverUnreadable(reason: String) -> BookmarkPendingLoad {
    lock.lock()
    defer { lock.unlock() }
    let current = load()
    guard current.writable, current.payload != nil else { return current }
    return preserveUnreadable(reason: reason)
  }

  private func preserveUnreadable(reason: String) -> BookmarkPendingLoad {
    let timestamp = String(format: "%.0f", clock())
    let target = directory.appendingPathComponent("\(Self.journalName).unreadable-\(timestamp)-\(UUID().uuidString.lowercased())")
    var preservedPath: String?
    var writable = false
    do {
      try operations.rename(journalURL, target)
      preservedPath = target.path
      try operations.syncDirectory(directory)
      writable = true
    } catch {
      logger("Could not durably preserve unreadable bookmark journal: \(error)")
    }
    logger("Unreadable bookmark journal preserved at \(preservedPath ?? journalURL.path): \(reason)")
    let notice = BookmarkRecoveryNotice(kind: .unreadableJournal, message: "Some pending bookmark changes could not be read. The journal was preserved for recovery.", preservedPath: preservedPath ?? journalURL.path)
    let result = BookmarkPendingLoad(payload: nil, recoveryNotice: notice, writable: writable)
    loaded = result
    return result
  }

  public func write(_ payload: JSONValue) throws {
    lock.lock()
    defer { lock.unlock() }
    guard load().writable else { throw BookmarkPendingStoreError.unavailable }
    let envelope: JSONValue = ["version": 2, "payload": payload, "checksum": .string(Self.checksum(payload))]
    let bytes = Data(envelope.text().utf8)
    let temporary = directory.appendingPathComponent("\(Self.journalName).tmp-\(UUID().uuidString.lowercased())")
    var renamed = false
    do {
      try operations.writeNew(temporary, bytes)
      try operations.syncFile(temporary)
      try operations.rename(temporary, journalURL)
      renamed = true
      try operations.syncDirectory(directory)
      loaded = BookmarkPendingLoad(payload: payload, recoveryNotice: loaded?.recoveryNotice, writable: true)
    } catch {
      logger("Bookmark journal write failed: \(error)")
      if renamed {
        loaded = BookmarkPendingLoad(payload: loaded?.payload, recoveryNotice: loaded?.recoveryNotice, writable: false)
        if case let BookmarkPendingStoreError.io(step, code) = error { throw BookmarkPendingStoreError.savedUnconfirmed(step, code) }
        throw BookmarkPendingStoreError.savedUnconfirmed(String(describing: error), EIO)
      }
      try? operations.remove(temporary)
      throw error
    }
  }

  private static func checksum(_ payload: JSONValue) -> String {
    SHA256.hash(data: Data(payload.canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
