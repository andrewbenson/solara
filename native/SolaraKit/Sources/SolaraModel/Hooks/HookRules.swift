import CryptoKit
import Foundation

public enum HookEvent: String, Sendable, CaseIterable, Codable {
  case downloadFinished = "download.finished"
  case pageLoaded = "page.loaded"
  case linkOpened = "link.opened"
}

public enum HookPermission: String, Sendable, CaseIterable {
  case camera
  case microphone
}

public enum HookURLOutcome: Equatable, Sendable {
  case matched([String?])
  case missed
  case failed

  public var matched: Bool { if case .matched = self { true } else { false } }
}

public struct HookMatch: Sendable {
  public var urls: [HookURLPattern] = []
  public var hosts: [HookHostPattern] = []
  public var regex: HookRegex?
  public var apps: [String]?
  public var team: String?
  public var profiles: [String]?

  public var hasURLCondition: Bool { !urls.isEmpty || !hosts.isEmpty || regex != nil }
  public var regexOnly: Bool { regex != nil && urls.isEmpty && hosts.isEmpty }

  public func outcome(_ url: HookURL?) -> HookURLOutcome {
    if !hasURLCondition { return .matched([]) }
    guard let url else { return .failed }
    if hosts.contains(where: { $0.matches(url.host) }) { return .matched([]) }
    if url.string.utf8.count > HookRegex.matchLength {
      return urls.contains(where: { $0.matchesOrigin(url) }) || regex != nil ? .failed : .missed
    }
    if urls.contains(where: { $0.matches(url) }) { return .matched([]) }
    guard let regex else { return .missed }
    switch regex.match(url.string) {
    case .matched(let captures): return .matched(captures)
    case .missed: return .missed
    case .failed: return .failed
    }
  }

  public func matchesProfile(_ profile: String?) -> Bool {
    guard let profiles else { return true }
    guard let profile else { return false }
    return profiles.contains(profile.lowercased())
  }

  public func matchesApp(_ sender: HookSender?) -> Bool {
    guard let apps else { return true }
    guard let sender, apps.contains(sender.identifier) else { return false }
    if let team { return team == sender.team }
    return sender.vouched
  }
}

public enum HookAction: Sendable, Equatable {
  case block
  case rewrite(HookTemplate)
  case stripParams([String])
  case https
  case openIn(profile: String)
  case fileInto(folder: String)
  case deny([HookPermission])
  case run(argv: [String], events: [HookEvent], timeout: TimeInterval)
  case notify(events: [HookEvent])
  case sound(name: String, events: [HookEvent])

  public var kind: String {
    switch self {
    case .block: "block"
    case .rewrite: "rewrite"
    case .stripParams: "stripParams"
    case .https: "https"
    case .openIn: "openIn"
    case .fileInto: "fileInto"
    case .deny: "deny"
    case .run: "run"
    case .notify: "notify"
    case .sound: "sound"
    }
  }

  public var events: [HookEvent] {
    switch self {
    case .run(_, let events, _), .notify(let events), .sound(_, let events): events
    default: []
    }
  }

  public var navigates: Bool {
    switch self {
    case .block, .rewrite, .stripParams, .https: true
    default: false
    }
  }
}

public struct HookRule: Sendable {
  public let name: String
  public let index: Int
  public let match: HookMatch
  public let action: HookAction
  public let digest: String
  public let text: String
  public let needsApproval: Bool
}

public struct HookTemplate: Sendable, Equatable {
  public static let placeholders: Set<String> = ["url", "scheme", "host", "port", "path", "query", "fragment", "origin"]
  public let text: String
  public let literalHost: String?

  public init?(_ text: String, captures: Int) {
    guard Self.problem(text, captures: captures) == nil else { return nil }
    self.text = text
    literalHost = Self.literalAuthority(text).flatMap { HookURL($0 + "/")?.host }
  }

  enum Piece: Equatable {
    case literal(String)
    case field(String)
    case capture(Int)
  }

  static func pieces(_ text: String, captures: Int) -> [Piece]? {
    var pieces: [Piece] = []
    var literal = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "}" { return nil }
      if character != "{" {
        literal.append(character)
        index = text.index(after: index)
        continue
      }
      guard let close = text[index...].firstIndex(of: "}") else { return nil }
      let name = String(text[text.index(after: index)..<close])
      if !literal.isEmpty { pieces.append(.literal(literal)) }
      literal = ""
      if placeholders.contains(name) {
        pieces.append(.field(name))
      } else if name.count == 1, let digit = Int(name), digit >= 1, digit <= 9, digit <= captures {
        pieces.append(.capture(digit))
      } else {
        return nil
      }
      index = text.index(after: close)
    }
    if !literal.isEmpty { pieces.append(.literal(literal)) }
    return pieces
  }

  static func literalAuthority(_ text: String) -> String? {
    let lowered = text.lowercased()
    guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
    let start = text.index(text.startIndex, offsetBy: lowered.hasPrefix("https://") ? 8 : 7)
    let end = text[start...].firstIndex { "/?#{".contains($0) } ?? text.endIndex
    guard end > start, end == text.endIndex || text[end] != "{" || text[end...].hasPrefix("{path}") || text[end...].hasPrefix("{query}") || text[end...].hasPrefix("{fragment}") else { return nil }
    return String(text[..<end])
  }

  public static func problem(_ text: String, captures: Int) -> String? {
    guard !text.isEmpty, text.utf8.count <= 8192 else { return "must be a URL template of at most 8 KB" }
    guard let pieces = pieces(text, captures: captures) else {
      return "must use only {url} {scheme} {host} {port} {path} {query} {fragment} {origin}" + (captures > 0 ? " or {1}…{\(min(captures, 9))}" : "") + ", with every { closed"
    }
    var next = 0
    func field(_ at: Int, _ name: String) -> Bool { at < pieces.count && pieces[at] == .field(name) }
    var rest: [Piece]
    if field(0, "origin") {
      next = 1
    } else if field(0, "scheme"), pieces.count > 2, pieces[1] == .literal("://"), field(2, "host") {
      next = field(3, "port") ? 4 : 3
    } else if case .literal(let first)? = pieces.first {
      let lowered = first.lowercased()
      guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else {
        return "must start with http://, https://, {origin} or {scheme}://{host}"
      }
      let start = lowered.hasPrefix("https://") ? 8 : 7
      let body = first.dropFirst(start)
      if body.isEmpty && field(1, "host") {
        next = field(2, "port") ? 3 : 2
      } else if let end = body.firstIndex(where: { "/?#".contains($0) }) {
        guard let authority = literalAuthority(first), !authority.contains("@"), HookURL(authority + "/") != nil, end > body.startIndex else {
          return "must start with a valid http(s) address"
        }
        rest = [.literal(String(body[end...]))] + pieces.dropFirst()
        return tailProblem(rest)
      } else {
        if pieces.count > 1 && !field(1, "path") && !field(1, "query") && !field(1, "fragment") {
          return "must spell out the host or use the page's own ({host}, {origin}); a placeholder can't be part of the host"
        }
        guard !first.contains("@"), HookURL(first + "/") != nil else { return "must start with a valid http(s) address" }
        next = 1
      }
    } else {
      return "must start with http://, https://, {origin} or {scheme}://{host}"
    }
    rest = Array(pieces.dropFirst(next))
    return tailProblem(rest)
  }

  static func tailProblem(_ rest: [Piece]) -> String? {
    guard let first = rest.first else { return nil }
    switch first {
    case .field(let name) where ["path", "query", "fragment"].contains(name): return nil
    case .literal(let text) where text.hasPrefix("/") || text.hasPrefix("?") || text.hasPrefix("#"): return nil
    default: return "must end the host with /, ?, # or {path}, {query}, {fragment}"
    }
  }
}

public struct HooksFileError: Error, Sendable, Equatable, CustomStringConvertible {
  public let location: String
  public let message: String
  public var description: String { location.isEmpty ? message : "\(location): \(message)" }

  init(_ location: String, _ message: String) {
    self.location = location
    self.message = message
  }
}

public enum HooksFile {
  public static let maxBytes = 1_048_576
  public static let maxRules = 200
  public static let maxListEntries = 100
  public static let digestPrefix = "solara-hooks-v2\n"

  public static func parse(_ data: Data) throws(HooksFileError) -> [HookRule] {
    guard data.count <= maxBytes else { throw HooksFileError("", "hooks.json is larger than 1 MB") }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw HooksFileError("", "hooks.json isn't valid JSON: \(Self.jsonProblem(error))")
    }
    guard let root = object as? [String: Any] else { throw HooksFileError("", "hooks.json must be an object with a \"hooks\" list") }
    for key in root.keys where key != "hooks" && key != "version" {
      throw HooksFileError(key, "unknown key (hooks.json takes \"version\" and \"hooks\")")
    }
    if let version = root["version"] {
      guard let number = version as? NSNumber, !Self.isBool(number), number == 1 else { throw HooksFileError("version", "must be 1") }
    }
    guard let list = root["hooks"] as? [Any] else { throw HooksFileError("hooks", "must be a list of hooks") }
    guard list.count <= maxRules else { throw HooksFileError("hooks", "at most \(maxRules) hooks") }
    var names = Set<String>()
    var rules: [HookRule] = []
    for (index, item) in list.enumerated() {
      let rule = try parseRule(item, index: index)
      guard names.insert(rule.name.lowercased()).inserted else { throw HooksFileError("hooks[\(index)].name", "\"\(rule.name)\" is used by another hook") }
      rules.append(rule)
    }
    return rules
  }

  static func jsonProblem(_ error: Error) -> String {
    let info = (error as NSError).userInfo
    return (info[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
  }

  static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

  static let actionKeys = ["block", "rewrite", "stripParams", "https", "openIn", "fileInto", "deny", "run", "notify", "sound"]
  static let eventActions: Set<String> = ["run", "notify", "sound"]
  static let ruleKeys: Set<String> = Set(actionKeys + ["name", "match", "on", "timeout"])
  static let matchKeys: Set<String> = ["urls", "hosts", "regex", "apps", "team", "profiles"]

  static func parseRule(_ item: Any, index: Int) throws(HooksFileError) -> HookRule {
    let at = "hooks[\(index)]"
    guard let object = item as? [String: Any] else { throw HooksFileError(at, "each hook must be an object") }
    for key in object.keys.sorted() where !ruleKeys.contains(key) { throw HooksFileError("\(at).\(key)", "unknown key") }
    guard let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 100,
      !name.unicodeScalars.contains(where: { HookText.unsafe($0) })
    else { throw HooksFileError("\(at).name", "every hook needs a name (1 to 100 characters, no control or direction characters)") }
    let at2 = "hooks[\(index)] (\(name))"
    let actions = actionKeys.filter { object[$0] != nil }
    guard actions.count == 1, let actionKey = actions.first else {
      throw HooksFileError(at2, "needs exactly one of " + actionKeys.joined(separator: ", "))
    }
    let match = try parseMatch(object["match"], at: "\(at2).match")
    if !eventActions.contains(actionKey) {
      if object["on"] != nil { throw HooksFileError("\(at2).on", "only run, notify and sound take \"on\"") }
    }
    if actionKey != "run" && object["timeout"] != nil { throw HooksFileError("\(at2).timeout", "only a run hook takes \"timeout\"") }
    if match.apps != nil && !(["block", "openIn"] + Array(eventActions)).contains(actionKey) {
      throw HooksFileError("\(at2).match.apps", "apps only applies to links from other apps (block, openIn, or run, notify and sound on link.opened)")
    }
    func needsURLCondition(_ what: String) throws(HooksFileError) {
      guard match.hasURLCondition else { throw HooksFileError("\(at2).match", "\(what) needs urls, hosts or regex") }
    }
    let action: HookAction
    var needsApproval = false
    switch actionKey {
    case "block":
      guard let flag = object["block"] as? NSNumber, Self.isBool(flag), flag.boolValue else { throw HooksFileError("\(at2).block", "must be true") }
      if match.apps == nil { try needsURLCondition("block") }
      action = .block
    case "rewrite":
      guard let text = object["rewrite"] as? String else { throw HooksFileError("\(at2).rewrite", "must be a URL template") }
      try needsURLCondition("a rewrite")
      let captures = match.regexOnly ? min(9, match.regex?.captureGroups ?? 0) : 0
      if let problem = HookTemplate.problem(text, captures: captures) { throw HooksFileError("\(at2).rewrite", problem) }
      guard let template = HookTemplate(text, captures: captures) else { throw HooksFileError("\(at2).rewrite", "isn't a valid template") }
      needsApproval = true
      action = .rewrite(template)
    case "stripParams":
      guard let list = object["stripParams"] as? [Any], !list.isEmpty, list.count <= maxListEntries else {
        throw HooksFileError("\(at2).stripParams", "must list 1 to \(maxListEntries) query parameter names (a trailing * matches a prefix)")
      }
      var names: [String] = []
      for entry in list {
        guard let text = entry as? String, Self.paramName(text) else {
          throw HooksFileError("\(at2).stripParams", "parameter names are letters, digits, - _ . and an optional trailing *")
        }
        names.append(text)
      }
      try needsURLCondition("stripParams")
      action = .stripParams(names)
    case "https":
      guard let flag = object["https"] as? NSNumber, Self.isBool(flag), flag.boolValue else { throw HooksFileError("\(at2).https", "must be true") }
      try needsURLCondition("https")
      action = .https
    case "openIn":
      guard let target = object["openIn"] as? [String: Any], target.keys.allSatisfy({ $0 == "profile" }),
        let profile = target["profile"] as? String, !profile.isEmpty, profile.count <= 100
      else { throw HooksFileError("\(at2).openIn", "must be {\"profile\": \"<profile name>\"}") }
      action = .openIn(profile: profile)
    case "fileInto":
      guard let folder = object["fileInto"] as? String, let policy = HookFolder(folder) else {
        throw HooksFileError("\(at2).fileInto", "must be a folder starting with ~/ or /, without . or .. parts")
      }
      needsApproval = !policy.insideDownloads
      action = .fileInto(folder: folder)
    case "deny":
      guard let kinds = object["deny"] as? [Any], !kinds.isEmpty else { throw HooksFileError("\(at2).deny", "must list camera and/or microphone") }
      var permissions: [HookPermission] = []
      for kind in kinds {
        guard let text = kind as? String, let permission = HookPermission(rawValue: text) else {
          throw HooksFileError("\(at2).deny", "only camera and microphone can be denied")
        }
        if !permissions.contains(permission) { permissions.append(permission) }
      }
      try needsURLCondition("deny")
      action = .deny(permissions)
    case "notify":
      guard let flag = object["notify"] as? NSNumber, Self.isBool(flag), flag.boolValue else { throw HooksFileError("\(at2).notify", "must be true") }
      action = .notify(events: try parseEvents(object, at: at2))
    case "sound":
      guard let sound = object["sound"] as? String, !sound.isEmpty, sound.count <= 64,
        sound.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_") })
      else { throw HooksFileError("\(at2).sound", "must be the name of a system sound, such as \"Glass\"") }
      action = .sound(name: sound, events: try parseEvents(object, at: at2))
    default:
      action = try parseRun(object, at: at2)
      needsApproval = true
    }
    if match.apps != nil && eventActions.contains(actionKey) && action.events != [.linkOpened] {
      throw HooksFileError("\(at2).match.apps", "apps only applies to link.opened")
    }
    let text = canonical(object)
    return HookRule(name: name, index: index, match: match, action: action, digest: digest(text), text: text, needsApproval: needsApproval)
  }

  static func paramName(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= 100 else { return false }
    let body = text.hasSuffix("*") ? text.dropLast() : Substring(text)
    return !body.isEmpty && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
  }

  static func parseEvents(_ object: [String: Any], at: String) throws(HooksFileError) -> [HookEvent] {
    let rawEvents: [Any]
    if let one = object["on"] as? String { rawEvents = [one] } else if let many = object["on"] as? [Any], !many.isEmpty { rawEvents = many } else {
      throw HooksFileError("\(at).on", "needs \"on\": download.finished, page.loaded and/or link.opened")
    }
    var events: [HookEvent] = []
    for raw in rawEvents {
      guard let text = raw as? String, let event = HookEvent(rawValue: text) else {
        throw HooksFileError("\(at).on", "events are download.finished, page.loaded and link.opened")
      }
      if !events.contains(event) { events.append(event) }
    }
    return events
  }

  static func parseRun(_ object: [String: Any], at: String) throws(HooksFileError) -> HookAction {
    guard let list = object["run"] as? [Any], !list.isEmpty, list.count <= 64 else {
      throw HooksFileError("\(at).run", "must be a list: the program and its arguments (use [\"/bin/sh\", \"-c\", \"…\"] for a shell)")
    }
    var argv: [String] = []
    for part in list {
      guard let text = part as? String, !text.contains("\0"), text.utf8.count <= 4096 else {
        throw HooksFileError("\(at).run", "every part must be a string of at most 4 KB")
      }
      argv.append(text)
    }
    guard argv[0].hasPrefix("/") || argv[0].hasPrefix("~/") else {
      throw HooksFileError("\(at).run", "the program must be a full path (/… or ~/…); Solara doesn't search PATH")
    }
    let events = try parseEvents(object, at: at)
    var timeout: TimeInterval = 30
    if let value = object["timeout"] {
      guard let number = value as? NSNumber, !isBool(number), number.doubleValue >= 1, number.doubleValue <= 600 else {
        throw HooksFileError("\(at).timeout", "must be a number of seconds from 1 to 600")
      }
      timeout = number.doubleValue
    }
    return .run(argv: argv, events: events, timeout: timeout)
  }

  static func parseMatch(_ value: Any?, at: String) throws(HooksFileError) -> HookMatch {
    var match = HookMatch()
    guard let value else { return match }
    guard let object = value as? [String: Any] else { throw HooksFileError(at, "must be an object") }
    for key in object.keys.sorted() where !matchKeys.contains(key) { throw HooksFileError("\(at).\(key)", "unknown key (match takes urls, hosts, regex, apps, team, profiles)") }
    func strings(_ key: String) throws(HooksFileError) -> [String]? {
      guard let raw = object[key] else { return nil }
      let list: [Any] = (raw as? String).map { [$0] } ?? (raw as? [Any] ?? [])
      guard !list.isEmpty, list.count <= maxListEntries else { throw HooksFileError("\(at).\(key)", "must be a string or a list of 1 to \(maxListEntries) strings") }
      var result: [String] = []
      for entry in list {
        guard let text = entry as? String, !text.isEmpty else { throw HooksFileError("\(at).\(key)", "every entry must be a non-empty string") }
        result.append(text)
      }
      return result
    }
    for text in try strings("urls") ?? [] {
      guard let pattern = HookURLPattern(text) else {
        throw HooksFileError("\(at).urls", "\"\(text)\" isn't a URL pattern (scheme://host/path, where scheme is http, https or *, host is example.com, *.example.com or *, and * in the path matches anything)")
      }
      match.urls.append(pattern)
    }
    for text in try strings("hosts") ?? [] {
      guard let host = HookHostPattern(text) else { throw HooksFileError("\(at).hosts", "\"\(text)\" isn't a host (example.com or *.example.com; IDN hosts in punycode)") }
      match.hosts.append(host)
    }
    if let raw = object["regex"] {
      guard let text = raw as? String, let regex = HookRegex(text) else {
        throw HooksFileError("\(at).regex", "isn't an allowed regular expression (at most 1,024 characters, matched against the whole URL; no lookaround, backreferences, nested quantifiers, possessive or atomic groups, inline flags or \\A \\Z \\z \\G)")
      }
      match.regex = regex
    }
    match.apps = try strings("apps")?.map { $0.lowercased() }
    if let raw = object["team"] {
      guard match.apps != nil, let text = raw as? String, HookSender(identifier: "x", team: text) != nil, text != HookSender.appleTeam else {
        throw HooksFileError("\(at).team", "must be the 10-character Apple team ID that signs the apps in \"apps\" (codesign -dv shows it as TeamIdentifier)")
      }
      match.team = text
    }
    match.profiles = try strings("profiles")?.map { $0.lowercased() }
    return match
  }

  public static func canonical(_ rule: [String: Any]) -> String {
    let body = (try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: body, as: UTF8.self)
  }

  public static func digest(_ text: String) -> String {
    let hash = SHA256.hash(data: Data((digestPrefix + text).utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
  }
}

public enum HookText {
  public static func unsafe(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if value < 0x20 || (value >= 0x7F && value <= 0x9F) { return true }
    switch scalar.properties.generalCategory {
    case .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate: return true
    default: break
    }
    if (0xFE00...0xFE0F).contains(value) || (0xE0000...0xE01EF).contains(value) || (0x180B...0x180F).contains(value) { return true }
    return [0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x17B4, 0x17B5].contains(value)
  }

  public static func lineDiff(_ old: String, _ new: String) -> [String] {
    let before = old.components(separatedBy: "\n")
    let after = new.components(separatedBy: "\n")
    guard before.count * after.count <= 250_000 else { return before.map { "- " + $0 } + after.map { "+ " + $0 } }
    var common = Array(repeating: Array(repeating: 0, count: after.count + 1), count: before.count + 1)
    for i in stride(from: before.count - 1, through: 0, by: -1) {
      for j in stride(from: after.count - 1, through: 0, by: -1) {
        common[i][j] = before[i] == after[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
      }
    }
    var result: [String] = []
    var i = 0
    var j = 0
    while i < before.count || j < after.count {
      if i < before.count && j < after.count && before[i] == after[j] {
        result.append("  " + before[i])
        i += 1
        j += 1
      } else if j < after.count && (i == before.count || common[i][j + 1] >= common[i + 1][j]) {
        result.append("+ " + after[j])
        j += 1
      } else {
        result.append("- " + before[i])
        i += 1
      }
    }
    return result
  }

  public static func pretty(_ canonical: String) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: Data(canonical.utf8)),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return canonical }
    return String(decoding: data, as: UTF8.self)
  }

  public static func clean(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { !unsafe($0) }))
  }

  public static func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      if unsafe(scalar) || scalar == "\\" {
        result += scalar == "\\" ? "\\\\" : String(format: "\\u{%04X}", scalar.value)
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
