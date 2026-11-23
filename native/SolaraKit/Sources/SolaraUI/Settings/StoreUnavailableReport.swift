import Foundation
import SolaraStore

public enum StoreUnavailableReport {
  public static let dataFolderMark = "<data folder>"

  public static func summary(_ failure: StoreUnavailable, dataFolderPaths: [String], home: String) -> String {
    let clean = { (text: String) in scrub(text, dataFolderPaths: dataFolderPaths, home: home) }
    let lines = [
      "Solara couldn't open its windows and tabs at launch.",
      "Cause: \(failure.causeName)",
      failure.errorType.isEmpty ? nil : "Error: \(clean(failure.errorType))",
      failure.firstDetailLine.isEmpty ? nil : "Message: \(clean(failure.firstDetailLine))",
      "Safe mode: \(failure.launchWasSafeMode ? "yes" : "no")",
    ]
    return lines.compactMap { $0 }.joined(separator: "\n")
  }

  public static func scrub(_ text: String, dataFolderPaths: [String], home: String) -> String {
    var out = text
    let folders = Set(dataFolderPaths.map(trimmedFolder).filter { $0.count > 1 }).sorted { $0.count > $1.count }
    for folder in folders { out = out.replacingOccurrences(of: folder, with: dataFolderMark) }
    out = CrashReport.sanitize(out, home: home)
    out = out.replacingOccurrences(of: #"/private/var/folders/\S+"#, with: "<temporary folder>", options: .regularExpression)
    out = out.replacingOccurrences(of: #"/var/folders/\S+"#, with: "<temporary folder>", options: .regularExpression)
    out = out.replacingOccurrences(of: #"/Users/[^/ ]+"#, with: "/Users/<user>", options: .regularExpression)
    return out
  }

  static func trimmedFolder(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  public static func dataFolderPaths(_ folder: URL?) -> [String] {
    guard let folder else { return [] }
    let resolved = realpath(folder.path, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    }
    return [folder.path, folder.standardizedFileURL.path, resolved].compactMap { $0 }
  }
}
