import Foundation
import SolaraModel

public struct BugReportFacts: Equatable, Sendable {
  public var repo: String
  public var version: String
  public var build: String
  public var macOS: String
  public var model: String
  public var layout: String

  public init(repo: String, version: String, build: String, macOS: String, model: String, layout: String) {
    self.repo = repo
    self.version = version
    self.build = build
    self.macOS = macOS
    self.model = model
    self.layout = layout
  }
}

public enum BugReport {
  public static let urlLimit = 7500
  public static let template = "bug.yml"
  static let trimmedMark = "…"

  public static func layoutName(_ state: BrowserState?, windowId: String?) -> String {
    let window = windowId.flatMap { state?.windows[$0] }
    let layout = window?.tabLayout ?? state?.settings.string("tabLayout") ?? "sidebar"
    return layout == "top" ? "Top tabs" : "Sidebar"
  }

  public static func versionField(version: String, build: String) -> String {
    let build = build.trimmingCharacters(in: .whitespaces)
    return build.isEmpty || build == version ? version : "\(version) (\(build))"
  }

  public static func validRepo(_ repo: String) -> Bool {
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
    return parts.allSatisfy { part in !part.isEmpty && part.count <= 100 && part.allSatisfy(allowed.contains) && part != "." && part != ".." }
  }

  public static func url(_ facts: BugReportFacts, crash: String? = nil, limit: Int = urlLimit) -> String? {
    guard validRepo(facts.repo) else { return nil }
    let fields: [(String, String)] = [
      ("template", template),
      ("version", versionField(version: facts.version, build: facts.build)),
      ("macos", facts.macOS),
      ("mac", facts.model),
      ("layout", facts.layout),
    ]
    let base = "https://github.com/\(facts.repo)/issues/new?" + fields.filter { !$0.1.isEmpty }.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    guard let crash, !crash.isEmpty else { return base }
    let room = limit - base.utf8.count - "&crash=".utf8.count
    guard let fitted = fit(crash, encodedBudget: room) else { return base }
    return base + "&crash=" + encode(fitted)
  }

  static func fit(_ crash: String, encodedBudget: Int) -> String? {
    guard encodedBudget > 0 else { return nil }
    if encode(crash).utf8.count <= encodedBudget { return crash }
    var lines = crash.components(separatedBy: "\n")
    while !lines.isEmpty {
      lines.removeLast()
      let candidate = (lines + [trimmedMark]).joined(separator: "\n")
      if lines.isEmpty { return nil }
      if encode(candidate).utf8.count <= encodedBudget { return candidate }
    }
    return nil
  }

  private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

  public static func encode(_ text: String) -> String {
    var out = ""
    for byte in text.utf8 {
      if unreserved.contains(byte) {
        out.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }
}
