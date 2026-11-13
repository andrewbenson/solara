import Foundation

public struct HookFileIdentity: Codable, Sendable, Equatable {
  public var dev: UInt64
  public var ino: UInt64

  public init(dev: UInt64, ino: UInt64) {
    self.dev = dev
    self.ino = ino
  }

  public static func of(_ path: String, follow: Bool = false) -> HookFileIdentity? {
    var info = stat()
    guard (follow ? stat(path, &info) : lstat(path, &info)) == 0 else { return nil }
    return HookFileIdentity(dev: UInt64(UInt32(bitPattern: info.st_dev)), ino: UInt64(info.st_ino))
  }
}

public struct HookFolderSpec: Sendable, Equatable {
  public let root: String
  public let identity: HookFileIdentity
  public let below: [String]
}

public struct HookFolder: Sendable, Equatable {
  public let text: String
  public let path: String
  public let resolved: String
  public let downloads: String

  public static var userHome: String {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
    return NSHomeDirectory()
  }

  public init?(_ text: String, home: String = HookFolder.userHome) {
    guard !text.contains("\0"), text.utf8.count <= 1024 else { return nil }
    let expanded: String
    if text == "~" { expanded = home }
    else if text.hasPrefix("~/") { expanded = (home as NSString).appendingPathComponent(String(text.dropFirst(2))) }
    else if text.hasPrefix("/") { expanded = text }
    else { return nil }
    let parts = text.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    self.text = text
    path = (expanded as NSString).standardizingPath
    resolved = Self.resolved(path)
    downloads = Self.resolved((home as NSString).appendingPathComponent("Downloads"))
  }

  public var insideDownloads: Bool { resolved == downloads || resolved.hasPrefix(downloads + "/") }

  public var belowDownloads: [String]? {
    guard insideDownloads else { return nil }
    return resolved.dropFirst(downloads.count).split(separator: "/").map(String.init)
  }

  public func spec(approved: HookFileIdentity? = nil) -> HookFolderSpec? {
    if let below = belowDownloads {
      guard let identity = Self.directoryIdentity(downloads) else { return nil }
      var current = downloads
      for part in below {
        current = (current as NSString).appendingPathComponent(part)
        var info = stat()
        if lstat(current, &info) != 0 { break }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
      }
      return HookFolderSpec(root: downloads, identity: identity, below: below)
    }
    guard let approved, let identity = Self.directoryIdentity(resolved), identity == approved else { return nil }
    return HookFolderSpec(root: resolved, identity: identity, below: [])
  }

  public static func directoryIdentity(_ path: String) -> HookFileIdentity? {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    guard String(cString: real) == path else { return nil }
    return HookFileIdentity.of(path)
  }

  static func resolved(_ path: String) -> String {
    var existing = (path as NSString).standardizingPath
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing), existing != "/" {
      missing.insert((existing as NSString).lastPathComponent, at: 0)
      existing = (existing as NSString).deletingLastPathComponent
    }
    var base = existing
    if let real = realpath(existing, nil) {
      base = String(cString: real)
      free(real)
    }
    return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
  }
}
