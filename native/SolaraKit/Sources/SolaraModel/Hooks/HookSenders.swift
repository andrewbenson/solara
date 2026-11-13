import Foundation

public struct HookSender: Sendable, Equatable {
  public static let appleTeam = "apple"

  public let identifier: String
  public let team: String
  public var vouched = false

  public init?(identifier: String, team: String, vouched: Bool = false) {
    guard !identifier.isEmpty, identifier.utf8.count <= 255, !identifier.unicodeScalars.contains(where: HookText.unsafe) else { return nil }
    guard Self.validTeam(team) else { return nil }
    self.identifier = identifier.lowercased()
    self.team = team
    self.vouched = vouched
  }

  public init?(signed text: String?) {
    guard let text, let at = text.lastIndex(of: "@") else { return nil }
    self.init(identifier: String(text[..<at]), team: String(text[text.index(after: at)...]))
  }

  public static func validTeam(_ team: String) -> Bool {
    team == appleTeam || (team.utf8.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) })
  }

  public var claimsApple: Bool { identifier.hasPrefix("com.apple.") }
}

public struct HookAppTeam: Sendable, Equatable, Identifiable {
  public var id: String { identifier }
  public let identifier: String
  public let team: String

  public init(identifier: String, team: String) {
    self.identifier = identifier
    self.team = team
  }
}

public final class HookSenderTeams: @unchecked Sendable {
  public let file: URL?
  private let lock = NSLock()
  private var teams: [String: String] = [:]
  private var mismatches: [String: String] = [:]

  public init(file: URL?) {
    self.file = file
    guard let file, let data = try? Data(contentsOf: file),
      let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1
    else { return }
    teams = stored.teams
  }

  struct Stored: Codable {
    var version: Int
    var teams: [String: String]
  }

  public func team(of identifier: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return teams[identifier.lowercased()]
  }

  public var problems: [String] {
    lock.lock()
    defer { lock.unlock() }
    return mismatches.keys.sorted().map { mismatches[$0]! }
  }

  public var recorded: [HookAppTeam] {
    lock.lock()
    defer { lock.unlock() }
    return teams.keys.sorted().map { HookAppTeam(identifier: $0, team: teams[$0]!) }
  }

  public func check(_ raw: String?, registered: (String) -> String?, wanted: (String) -> Bool) -> HookSender? {
    guard var sender = HookSender(signed: raw) else { return nil }
    if sender.team == HookSender.appleTeam {
      sender.vouched = true
      return sender
    }
    if sender.claimsApple { return nil }
    guard wanted(sender.identifier) else { return sender }
    lock.lock()
    let known = teams[sender.identifier]
    lock.unlock()
    var expected = known
    if expected == nil, let installed = registered(sender.identifier), HookSender.validTeam(installed) {
      expected = installed
      lock.lock()
      if teams[sender.identifier] == nil { teams[sender.identifier] = installed }
      let snapshot = teams
      lock.unlock()
      save(snapshot)
    }
    guard let expected else {
      note(sender.identifier, "A link came from \(sender.identifier), but no installed copy of it was found to check who signs it; hooks for that app ignored it")
      return sender
    }
    guard expected == sender.team else {
      note(sender.identifier, "A link came from an app calling itself \(sender.identifier), signed by team \(sender.team); the installed \(sender.identifier) is signed by \(expected). Hooks for that app ignored it")
      return sender
    }
    lock.lock()
    mismatches[sender.identifier] = nil
    lock.unlock()
    sender.vouched = true
    return sender
  }

  public func forget(_ identifier: String) {
    lock.lock()
    teams[identifier.lowercased()] = nil
    mismatches[identifier.lowercased()] = nil
    let snapshot = teams
    lock.unlock()
    save(snapshot)
  }

  private func note(_ identifier: String, _ problem: String) {
    lock.lock()
    mismatches[identifier] = problem
    lock.unlock()
  }

  private func save(_ snapshot: [String: String]) {
    guard let file else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(Stored(version: 1, teams: snapshot)) else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
    unlink(temporary.path)
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
    if rename(temporary.path, file.path) != 0 { unlink(temporary.path) }
  }
}
