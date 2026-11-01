import Darwin
import Foundation
import SolaraModel
import Synchronization

public enum ProfileDataTombstones {
  private static let synchronized = Mutex<Set<String>>([])
  static let failingSynchronization = Mutex<Set<String>>([])

  private struct History: Codable {
    var deleted: [String] = []
    var reserved: [String] = []
    var aliases: [String] = []

    enum CodingKeys: String, CodingKey { case deleted, reserved, aliases }

    init() {}

    init(deleted: [String]) { self.deleted = deleted }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      deleted = try values.decodeIfPresent([String].self, forKey: .deleted) ?? []
      reserved = try values.decodeIfPresent([String].self, forKey: .reserved) ?? []
      aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
  }

  private struct Loaded {
    var history: History
    var rebuilt: Bool
  }

  private static func missing(_ error: Error) -> Bool {
    let failure = error as NSError
    return failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError)
  }

  private static func engineName(_ name: String) -> String? {
    guard name.hasPrefix("Profile ") else { return nil }
    let engine = String(name.dropFirst(8))
    return ProfileDataCleanup.validEngine(engine) ? engine : nil
  }

  private static func loaded(_ file: URL, pending: [String], live: [String], keepRebuilt: Bool) -> Loaded {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw CommandError("Profile deletion history is not a regular file.")
      }
      let data = try Data(contentsOf: file)
      if let legacy = try? JSONDecoder().decode([String].self, from: data) { return Loaded(history: History(deleted: legacy), rebuilt: false) }
      return Loaded(history: try JSONDecoder().decode(History.self, from: data), rebuilt: false)
    } catch {
      if !missing(error) { NSLog("[store] rebuilding profile deletion history: %@", String(describing: error)) }
    }
    var reserved = pending
    let chromium = file.deletingLastPathComponent().appendingPathComponent("Chromium")
    do {
      for name in try FileManager.default.contentsOfDirectory(atPath: chromium.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: chromium.appendingPathComponent(name).path)
        if attributes[.type] as? FileAttributeType == .typeDirectory, let engine = engineName(name) { reserved.append(engine) }
      }
    } catch {
      if !missing(error) { NSLog("[store] couldn't inspect profile directories: %@", String(describing: error)) }
    }
    do {
      let local = try Data(contentsOf: chromium.appendingPathComponent("Local State"))
      let root = try JSONSerialization.jsonObject(with: local) as? [String: Any]
      let names = (root?["profiles"] as? [String: Any])?["profile_basenames_deleted"] as? [String] ?? []
      reserved += names.compactMap(engineName)
    } catch {
      if !missing(error) { NSLog("[store] couldn't inspect marked profile directories: %@", String(describing: error)) }
    }
    var history = History()
    for engine in reserved where !engine.isEmpty && ProfileDataCleanup.validEngine(engine)
      && !live.contains(where: { $0.jsEquals(engine) }) && !history.reserved.contains(where: { $0.jsEquals(engine) }) {
      history.reserved.append(engine)
    }
    guard keepRebuilt, !history.reserved.isEmpty else { return Loaded(history: history, rebuilt: true) }
    do {
      try write(history, at: file)
      return Loaded(history: history, rebuilt: false)
    } catch {
      NSLog("[store] couldn't rebuild profile deletion history: %@", String(describing: error))
      return Loaded(history: history, rebuilt: true)
    }
  }

  private static func load(_ file: URL, pending: [String], live: [String]) -> History {
    loaded(file, pending: pending, live: live, keepRebuilt: true).history
  }

  static func read(_ file: URL?, pending: [String] = [], live: [String] = []) throws -> [String] {
    guard let file else { return [] }
    let history = load(file, pending: pending, live: live)
    return history.deleted + history.reserved
  }

  static func contains(_ engine: String, at file: URL?, pending: [String] = [], live: [String] = []) throws -> Bool {
    try read(file, pending: pending, live: live).contains { $0.jsEquals(engine) }
  }

  static func aliases(at file: URL?, pending: [String] = [], live: [String] = []) -> [String] {
    guard let file else { return [] }
    return load(file, pending: pending, live: live).aliases
  }

  static func confirm(profile: String, engine: String?, at file: URL?, pending: [String], live: [String]) throws {
    guard let file else { return }
    var current = loaded(file, pending: pending, live: live, keepRebuilt: false)
    let knownAlias = current.history.aliases.contains { $0.jsEquals(profile) }
    let knownEngine = engine.map { engine in current.history.deleted.contains { $0.jsEquals(engine) } } ?? true
    if !knownAlias { current.history.aliases.append(profile) }
    if let engine, !knownEngine { current.history.deleted.append(engine) }
    if knownAlias && knownEngine && !current.rebuilt { return try synchronizeIfNeeded(file) }
    try write(current.history, at: file)
  }

  static func insert(_ engine: String, at file: URL?, pending: [String] = [], live: [String] = []) throws {
    guard let file else { return }
    var current = loaded(file, pending: pending, live: live, keepRebuilt: false)
    if !current.history.deleted.contains(where: { $0.jsEquals(engine) }) { current.history.deleted.append(engine) }
    else if !current.rebuilt { return try synchronizeIfNeeded(file) }
    try write(current.history, at: file)
  }

  static func reserve(_ engine: String, at file: URL?, pending: [String], live: [String]) throws {
    guard let file else { return }
    var current = loaded(file, pending: pending, live: live, keepRebuilt: false)
    let known = (current.history.deleted + current.history.reserved).contains { $0.jsEquals(engine) }
    if !live.contains(where: { $0.jsEquals(engine) }) && !known { current.history.reserved.append(engine) }
    else if !current.rebuilt { return try synchronizeIfNeeded(file) }
    try write(current.history, at: file)
  }

  private static func synchronizeIfNeeded(_ file: URL) throws {
    guard !synchronized.withLock({ $0.contains(file.path) }) else { return }
    try synchronize(file)
  }

  private static func write(_ history: History, at file: URL) throws {
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".profile-data-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
    let data = try JSONEncoder().encode(history)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
    guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try synchronize(file)
  }

  private static func synchronize(_ file: URL) throws {
    synchronized.withLock { _ = $0.remove(file.path) }
    if failingSynchronization.withLock({ $0.contains(file.path) }) { throw POSIXError(.EIO) }
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let directory = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    synchronized.withLock { _ = $0.insert(file.path) }
  }
}
