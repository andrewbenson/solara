import Darwin
import Foundation

struct FileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t

  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}

struct StagedCopy {
  let base: URL
  let path: [String]
  let executableName: String
  let bundleId: String
  let version: String
  let channel: String?
  let modified: Date
  let bundleIdentity: FileIdentity
  let executableIdentity: FileIdentity

  var bundleURL: URL {
    path.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
  }

  var executableURL: URL {
    bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName)
  }
}

struct StagedScan {
  var copies: [StagedCopy] = []
  var channels: Set<String> = []
  var complete = true
}

enum StagedUpdates {
  static let deepestLevel = 4
  static let mostEntriesPerFolder = 256
  static let largestInfoPlist = 1 << 20

  static func scan(bundleId: String) -> StagedScan {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return StagedScan(complete: false)
    }
    return scan(bundleId: bundleId, base: caches, folders: [bundleId, "org.sparkle-project.Sparkle", "Installation"])
  }

  static func newest(version: String, bundleId: String) -> StagedCopy? {
    newest(of: scan(bundleId: bundleId).copies, version: version)
  }

  static func newest(of copies: [StagedCopy], version: String) -> StagedCopy? {
    copies.filter { $0.version == version }.max {
      $0.modified == $1.modified ? $0.bundleURL.path < $1.bundleURL.path : $0.modified < $1.modified
    }
  }

  static func copies(bundleId: String, base: URL, folders: [String]) -> [StagedCopy] {
    scan(bundleId: bundleId, base: base, folders: folders).copies
  }

  static func scan(bundleId: String, base: URL, folders: [String]) -> StagedScan {
    var result = StagedScan()
    guard let top = open(base, through: folders, missingIsEmpty: true, scan: &result) else { return result }
    defer { close(top) }
    guard let info = status(of: top) else {
      result.complete = false
      return result
    }
    walk(top, base: base, path: folders, level: 1, device: info.st_dev, bundleId: bundleId, into: &result)
    return result
  }

  static func isUnchanged(_ copy: StagedCopy) -> Bool {
    var ignored = StagedScan()
    guard let bundle = open(copy.base, through: copy.path, missingIsEmpty: false, scan: &ignored) else { return false }
    defer { close(bundle) }
    guard let info = status(of: bundle), FileIdentity(info) == copy.bundleIdentity,
      let contents = openFolder("Contents", in: bundle)
    else { return false }
    defer { close(contents) }
    guard let macOS = openFolder("MacOS", in: contents) else { return false }
    defer { close(macOS) }
    var executable = stat()
    guard isOnDevice(contents, info.st_dev), isOnDevice(macOS, info.st_dev),
      fstatat(macOS, copy.executableName, &executable, AT_SYMLINK_NOFOLLOW) == 0, isRunnableFile(executable)
    else { return false }
    return FileIdentity(executable) == copy.executableIdentity
  }

  private static func open(_ base: URL, through folders: [String], missingIsEmpty: Bool, scan: inout StagedScan) -> Int32? {
    var folder = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
    guard folder >= 0 else {
      scan.complete = false
      return nil
    }
    for name in folders {
      guard let next = openFolder(name, in: folder) else {
        if !(missingIsEmpty && errno == ENOENT) { scan.complete = false }
        close(folder)
        return nil
      }
      close(folder)
      folder = next
    }
    return folder
  }

  private static func walk(_ folder: Int32, base: URL, path: [String], level: Int, device: dev_t, bundleId: String,
                           into scan: inout StagedScan) {
    for name in entries(of: folder, scan: &scan) {
      var link = stat()
      guard fstatat(folder, name, &link, AT_SYMLINK_NOFOLLOW) == 0 else {
        scan.complete = false
        continue
      }
      guard isDirectory(link), link.st_dev == device else { continue }
      guard level <= deepestLevel else {
        scan.complete = false
        continue
      }
      guard let child = openFolder(name, in: folder) else {
        scan.complete = false
        continue
      }
      defer { close(child) }
      guard let info = status(of: child), FileIdentity(info) == FileIdentity(link) else {
        scan.complete = false
        continue
      }
      if (name as NSString).pathExtension == "app" {
        stagedCopy(child, base: base, path: path + [name], info: info, bundleId: bundleId, into: &scan)
      } else {
        walk(child, base: base, path: path + [name], level: level + 1, device: device, bundleId: bundleId, into: &scan)
      }
    }
  }

  private static func stagedCopy(_ bundle: Int32, base: URL, path: [String], info: stat, bundleId: String,
                                 into scan: inout StagedScan) {
    guard let contents = openFolder("Contents", in: bundle) else {
      scan.complete = false
      return
    }
    defer { close(contents) }
    guard let plist = infoPlist(in: contents, device: info.st_dev) else {
      scan.complete = false
      return
    }
    guard plist["CFBundleIdentifier"] as? String == bundleId else { return }
    let channel = plist["ACUpdateChannel"] as? String
    if let channel { scan.channels.insert(channel) }
    guard let version = plist["CFBundleVersion"] as? String,
      let name = plist["CFBundleExecutable"] as? String, isPlainName(name),
      isOnDevice(contents, info.st_dev),
      let macOS = openFolder("MacOS", in: contents)
    else { return }
    defer { close(macOS) }
    var executable = stat()
    guard isOnDevice(macOS, info.st_dev), fstatat(macOS, name, &executable, AT_SYMLINK_NOFOLLOW) == 0,
      isRunnableFile(executable), executable.st_dev == info.st_dev
    else { return }
    let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    scan.copies.append(StagedCopy(base: base, path: path, executableName: name, bundleId: bundleId, version: version,
                                  channel: channel, modified: modified, bundleIdentity: FileIdentity(info),
                                  executableIdentity: FileIdentity(executable)))
  }

  private static func infoPlist(in contents: Int32, device: dev_t) -> [String: Any]? {
    let file = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    guard let info = status(of: file), info.st_mode & S_IFMT == S_IFREG, info.st_dev == device,
      info.st_size <= largestInfoPlist,
      let data = try? handle.read(upToCount: largestInfoPlist + 1), data.count <= largestInfoPlist
    else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
  }

  private static func entries(of folder: Int32, scan: inout StagedScan) -> [String] {
    let copy = dup(folder)
    guard copy >= 0, let listing = fdopendir(copy) else {
      if copy >= 0 { close(copy) }
      scan.complete = false
      return []
    }
    defer { closedir(listing) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(listing) else {
        if errno != 0 { scan.complete = false }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      guard !name.hasPrefix(".") else { continue }
      guard names.count < mostEntriesPerFolder else {
        scan.complete = false
        break
      }
      names.append(name)
    }
    return names.sorted()
  }

  private static func openFolder(_ name: String, in parent: Int32) -> Int32? {
    guard isPlainName(name) else {
      errno = EINVAL
      return nil
    }
    let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    return folder >= 0 ? folder : nil
  }

  private static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  private static func status(of descriptor: Int32) -> stat? {
    var info = stat()
    return fstat(descriptor, &info) == 0 ? info : nil
  }

  private static func isOnDevice(_ descriptor: Int32, _ device: dev_t) -> Bool {
    status(of: descriptor)?.st_dev == device
  }

  private static func isDirectory(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFDIR
  }

  private static func isRunnableFile(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0
  }
}
