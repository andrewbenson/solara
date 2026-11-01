import Foundation

public enum ChromiumProfileData {
  public typealias Completion = ([String]) -> Void

  public static func isValidID(_ profile: String) -> Bool {
    !profile.contains("/") && !profile.contains("\\") && !profile.contains("\0") && profile != "." && profile != ".."
      && !profile.hasPrefix("incognito:")
  }

  public struct DirectoryIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
      self.device = device
      self.inode = inode
    }
  }

  public static func directoryIdentity(_ directory: URL) throws -> DirectoryIdentity? {
    let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
    guard let attributes = try attributes(resolved) else { return nil }
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    return DirectoryIdentity(device: device.uint64Value, inode: inode.uint64Value)
  }

  public static func deletionAllowed(
    targets: [URL], liveDirectories: [URL],
    resolve: (URL) throws -> DirectoryIdentity? = directoryIdentity
  ) -> Bool {
    do {
      let targets = try targets.compactMap(resolve)
      for directory in liveDirectories {
        if let identity = try resolve(directory), targets.contains(identity) {
          NSLog("[solaracore] REFUSING profile data deletion: target shares filesystem identity with live directory %@", directory.path)
          return false
        }
      }
      return true
    } catch {
      NSLog("[solaracore] REFUSING profile data deletion: filesystem identity resolution failed: %@", String(describing: error))
      return false
    }
  }

  private struct Location {
    let suppliedRoot: URL
    let root: URL
    let target: URL
    let device: NSNumber
    let inode: NSNumber

    func isCurrent() -> Bool {
      guard let current = ChromiumProfileData.root(suppliedRoot), current.url.path.utf16.elementsEqual(root.path.utf16),
        current.device == device, current.inode == inode else { return false }
      return ChromiumProfileData.safeTarget(target, root: root)
    }
  }

  private static func attributes(_ path: URL) throws -> [FileAttributeKey: Any]? {
    do {
      return try FileManager.default.attributesOfItem(atPath: path.path)
    } catch {
      let failure = error as NSError
      if failure.domain == NSCocoaErrorDomain && (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) { return nil }
      throw error
    }
  }

  private static func root(_ supplied: URL) -> (url: URL, device: NSNumber, inode: NSNumber)? {
    guard supplied.isFileURL, !supplied.path.isEmpty else { return nil }
    do {
      guard let initial = try attributes(supplied), initial[.type] as? FileAttributeType == .typeDirectory,
        let device = initial[.systemNumber] as? NSNumber, let inode = initial[.systemFileNumber] as? NSNumber else { return nil }
      let resolved = supplied.standardizedFileURL.resolvingSymlinksInPath()
      guard let current = try attributes(resolved), current[.type] as? FileAttributeType == .typeDirectory,
        current[.systemNumber] as? NSNumber == device, current[.systemFileNumber] as? NSNumber == inode else { return nil }
      return (resolved, device, inode)
    } catch {
      return nil
    }
  }

  private static func safeTarget(_ path: URL, root: URL) -> Bool {
    guard path.deletingLastPathComponent().path.utf16.elementsEqual(root.path.utf16), path.resolvingSymlinksInPath().standardizedFileURL.path.utf16.elementsEqual(path.path.utf16) else { return false }
    do {
      guard let attributes = try attributes(path) else { return true }
      guard attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
      return try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
        $0.utf16.elementsEqual(path.lastPathComponent.utf16)
      }
    } catch {
      return false
    }
  }

  private static func location(_ profile: String, profilesDirectory: URL) -> Location? {
    guard isValidID(profile), let root = root(profilesDirectory) else { return nil }
    let path = root.url.appendingPathComponent(profile.isEmpty ? "Default" : "Profile \(profile)", isDirectory: true)
    guard safeTarget(path, root: root.url) else { return nil }
    return Location(suppliedRoot: profilesDirectory, root: root.url, target: path, device: root.device, inode: root.inode)
  }

  public static func target(_ profile: String, profilesDirectory: URL) -> URL? {
    location(profile, profilesDirectory: profilesDirectory)?.target
  }

  public static func delete(
    _ profile: String,
    profilesDirectory: URL,
    deleteDefault: (@escaping Completion) -> Void,
    deleteNamed: (String, @escaping Completion) -> Void,
    directoryExists: @escaping (URL) -> Bool = { path in
      do {
        _ = try FileManager.default.attributesOfItem(atPath: path.path)
        return true
      } catch {
        let failure = error as NSError
        return failure.domain != NSCocoaErrorDomain || (failure.code != NSFileNoSuchFileError && failure.code != NSFileReadNoSuchFileError)
      }
    },
    completion: @escaping Completion
  ) {
    guard let location = location(profile, profilesDirectory: profilesDirectory) else {
      NSLog("[solaracore] refusing profile data deletion for invalid path: %@", profile)
      return completion(["refused profile path"])
    }
    if profile.isEmpty { return deleteDefault(completion) }
    deleteNamed(profile) { remaining in
      guard remaining.isEmpty else { return completion(remaining) }
      guard location.isCurrent() else {
        NSLog("[solaracore] refusing profile data acknowledgement for invalid path: %@", profile)
        return completion(["refused profile path"])
      }
      completion(directoryExists(location.target) ? ["Chromium profile directory"] : [])
    }
  }
}
