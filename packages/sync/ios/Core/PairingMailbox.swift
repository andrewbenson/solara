import Darwin
import Foundation

final class PairingMailbox {
  static let namespace = "Solara Pairing v2"
  static let entriesPerPass = 256
  static let bytesPerPass = 64 * 1024
  static let requestsPerPass = 8

  enum Kind: UInt8, CaseIterable {
    case request = 1, offer, select, reveal, confirm, approval, receipt, jTerminal, tTerminal, jName, tName

    var size: Int {
      switch self {
      case .request: 197
      case .offer: 233
      case .select, .reveal, .receipt: 156
      case .confirm: 124
      case .approval: 1160
      case .jTerminal, .tTerminal: 125
      case .jName, .tName: 376
      }
    }

    var filename: String {
      switch self {
      case .request: "request"
      case .offer: "offer"
      case .select: "select"
      case .reveal: "reveal"
      case .confirm: "confirm"
      case .approval: "approval"
      case .receipt: "receipt"
      case .jTerminal: "j-terminal"
      case .tTerminal: "t-terminal"
      case .jName: "j-name"
      case .tName: "t-name"
      }
    }

    static let bySuffix = Dictionary(uniqueKeysWithValues: allCases.filter { $0 != .request }.map { ($0.filename, $0) })
  }

  struct Entry: Equatable {
    let rid: Data
    let aid: Data?
    let kind: Kind
    let wire: Data
  }

  struct Listing {
    var entries: [Entry] = []
    var pending: [(aid: Data?, kind: Kind)] = []
    var skipped = 0
    var truncated = false
    var bytesRead = 0
  }

  enum WriteOutcome: Equatable {
    case written, identical
  }

  enum Failure: Error, Equatable {
    case folder, name, notRegularFile, size, conflict, pending, io(Int32)
  }

  let folder: URL
  let cid: String
  private let cidBytes: Data

  init(folder: URL, cid: String) throws {
    guard let bytes = try? PairingFormat.cid(cid) else { throw Failure.name }
    let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.folder }
    close(fd)
    self.folder = folder
    self.cid = cid
    cidBytes = bytes
  }

  static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  static func id(_ name: Substring) -> Data? {
    guard name.utf8.count == 32 else { return nil }
    var bytes = Data(capacity: 16)
    var index = name.startIndex
    while index < name.endIndex {
      let next = name.index(index, offsetBy: 2)
      guard name[index..<next].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }), let byte = UInt8(name[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  static func filename(aid: Data?, kind: Kind) -> String {
    kind == .request ? "request.spj" : "\(hex(aid ?? Data())).\(kind.filename).spj"
  }

  static func parse(_ name: String) -> (aid: Data?, kind: Kind)? {
    if name == "request.spj" { return (nil, .request) }
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2] == "spj", let kind = Kind.bySuffix[String(parts[1])], let aid = id(parts[0]) else { return nil }
    return (aid, kind)
  }

  func requests(excluding known: Set<Data>, limit: Int = PairingMailbox.requestsPerPass) -> [Data] {
    guard let chain = try? openChain(create: false) else { return [] }
    defer { close(chain) }
    var found: [Data] = []
    for name in list(chain).names {
      guard found.count < limit, let rid = Self.id(Substring(name)), rid.contains(where: { $0 != 0 }), !known.contains(rid) else { continue }
      let fd = openat(chain, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { continue }
      close(fd)
      found.append(rid)
    }
    return found
  }

  func read(rid: Data) -> Listing {
    var listing = Listing()
    guard let directory = try? openRequest(rid, create: false) else { return listing }
    defer { close(directory) }
    let names = list(directory)
    listing.truncated = names.truncated
    var budget = Self.bytesPerPass
    for name in names.names {
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        if let parsed = Self.parse(String(name.dropFirst().dropLast(".icloud".count))) {
          listing.pending.append(parsed)
          try? FileManager.default.startDownloadingUbiquitousItem(at: requestURL(rid).appendingPathComponent(Self.filename(aid: parsed.aid, kind: parsed.kind)))
        }
        continue
      }
      guard let (aid, kind) = Self.parse(name) else { continue }
      guard budget >= kind.size else {
        listing.truncated = true
        continue
      }
      let wire: Data
      do {
        wire = try readFile(directory, name: name, size: kind.size) { budget -= $0; listing.bytesRead += $0 }
      } catch Failure.pending {
        listing.pending.append((aid, kind))
        continue
      } catch {
        listing.skipped += 1
        continue
      }
      guard headerMatches(wire, rid: rid, aid: aid, kind: kind) else {
        listing.skipped += 1
        continue
      }
      listing.entries.append(Entry(rid: rid, aid: aid, kind: kind, wire: wire))
    }
    return listing
  }

  @discardableResult
  func write(_ wire: Data, rid: Data, aid: Data?, kind: Kind) throws -> WriteOutcome {
    guard (kind == .request) == (aid == nil), wire.count == kind.size, headerMatches(wire, rid: rid, aid: aid, kind: kind) else { throw Failure.size }
    let name = Self.filename(aid: aid, kind: kind)
    let directory = try openRequest(rid, create: true)
    defer { close(directory) }
    var placeholder = stat()
    guard fstatat(directory, ".\(name).icloud", &placeholder, AT_SYMLINK_NOFOLLOW) != 0 else { throw Failure.pending }
    let destination = requestURL(rid).appendingPathComponent(name)
    let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: requestURL(rid), create: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let stagingFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard stagingFD >= 0 else { throw Failure.io(errno) }
    defer { close(stagingFD) }
    try writeNew(stagingFD, name: name, data: wire)
    var moved: Int32 = 0
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [], error: &coordinationError) { _ in
      moved = renameatx_np(stagingFD, name, directory, name, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
    if coordinationError != nil { throw Failure.io(EIO) }
    if moved == 0 { return .written }
    guard moved == EEXIST else { throw Failure.io(moved) }
    guard let existing = try? readFile(directory, name: name, size: kind.size, charge: { _ in }), existing == wire else { throw Failure.conflict }
    return .identical
  }

  func remove(rid: Data, files: [(aid: Data?, kind: Kind)]) {
    guard let directory = try? openRequest(rid, create: false) else { return }
    defer { close(directory) }
    for file in files {
      let name = Self.filename(aid: file.aid, kind: file.kind)
      guard let wire = try? readFile(directory, name: name, size: file.kind.size, charge: { _ in }), headerMatches(wire, rid: rid, aid: file.aid, kind: file.kind) else { continue }
      var coordinationError: NSError?
      NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: requestURL(rid).appendingPathComponent(name), options: .forDeleting, error: &coordinationError) { _ in
        _ = unlinkat(directory, name, 0)
      }
    }
    guard let chain = try? openChain(create: false) else { return }
    defer { close(chain) }
    _ = unlinkat(chain, Self.hex(rid), AT_REMOVEDIR)
  }

  private var namespaceURL: URL { folder.appendingPathComponent(Self.namespace, isDirectory: true) }
  private func requestURL(_ rid: Data) -> URL { namespaceURL.appendingPathComponent(cid, isDirectory: true).appendingPathComponent(Self.hex(rid), isDirectory: true) }

  private func openDirectory(_ parent: Int32, _ name: String, create: Bool) throws -> Int32 {
    if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw Failure.io(errno) }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.folder }
    guard Self.opened(fd, isNamed: name) else {
      close(fd)
      throw Failure.name
    }
    return fd
  }

  private func openChain(create: Bool) throws -> Int32 {
    let root = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw Failure.folder }
    defer { close(root) }
    let namespace = try openDirectory(root, Self.namespace, create: create)
    defer { close(namespace) }
    return try openDirectory(namespace, cid, create: create)
  }

  private func openRequest(_ rid: Data, create: Bool) throws -> Int32 {
    guard rid.count == 16, rid.contains(where: { $0 != 0 }) else { throw Failure.name }
    let chain = try openChain(create: create)
    defer { close(chain) }
    return try openDirectory(chain, Self.hex(rid), create: create)
  }

  static func opened(_ fd: Int32, isNamed name: String) -> Bool {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
    return (String(cString: buffer) as NSString).lastPathComponent == name
  }

  private func namesIn(_ fd: Int32, limit: Int) throws -> (names: [String], truncated: Bool) {
    let copy = dup(fd)
    guard copy >= 0, let stream = fdopendir(copy) else {
      if copy >= 0 { close(copy) }
      throw Failure.io(errno)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard names.count < limit else { return (names, true) }
      names.append(name)
    }
    return (names, false)
  }

  private func list(_ fd: Int32) -> (names: [String], truncated: Bool) {
    (try? namesIn(fd, limit: Self.entriesPerPass)) ?? ([], false)
  }

  private func readFile(_ directory: Int32, name: String, size: Int, charge: (Int) -> Void) throws -> Data {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.notRegularFile }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.notRegularFile }
    guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure.pending }
    guard info.st_size == off_t(size) else { throw Failure.size }
    guard Self.opened(fd, isNamed: name) else { throw Failure.name }
    charge(size)
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, size, 0) }
    guard count == size else { throw Failure.size }
    var after = stat()
    guard fstat(fd, &after) == 0, after.st_size == off_t(size) else { throw Failure.size }
    return data
  }

  private func writeNew(_ directory: Int32, name: String, data: Data) throws {
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.io(errno) }
    defer { close(fd) }
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    guard written == data.count, fsync(fd) == 0 else { throw Failure.io(errno) }
  }

  private func headerMatches(_ wire: Data, rid: Data, aid: Data?, kind: Kind) -> Bool {
    guard wire.count == kind.size else { return false }
    let bytes = [UInt8](wire.prefix(60))
    let length = bytes[8..<12].reduce(0) { $0 << 8 | Int($1) }
    return bytes[0..<4].elementsEqual("SPJ2".utf8) && bytes[4] == 2 && bytes[5] == kind.rawValue && bytes[6] == 0 && bytes[7] == 0
      && length + 60 == wire.count
      && Data(bytes[12..<28]) == cidBytes && Data(bytes[28..<44]) == rid && Data(bytes[44..<60]) == (aid ?? Data(count: 16))
  }
}
