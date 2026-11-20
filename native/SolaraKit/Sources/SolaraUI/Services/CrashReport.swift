import Foundation

public struct CrashSummary: Equatable, Sendable {
  public var exceptionType: String
  public var signal: String
  public var queue: String
  public var frames: [String]
  public var binary: String
  public var uuid: String
  public var version: String

  public var text: String {
    var lines: [String] = []
    let exception = [exceptionType, signal.isEmpty ? "" : "(\(signal))"].filter { !$0.isEmpty }.joined(separator: " ")
    if !exception.isEmpty { lines.append("Exception: \(exception)") }
    if !queue.isEmpty { lines.append("Queue: \(queue)") }
    let identity = [binary, version, uuid.isEmpty ? "" : "UUID \(uuid)"].filter { !$0.isEmpty }.joined(separator: " ")
    if !identity.isEmpty { lines.append("Binary: \(identity)") }
    if !frames.isEmpty {
      lines.append("Crashed thread:")
      lines += frames
    }
    return lines.joined(separator: "\n")
  }
}

public struct CrashReportScan: Equatable, Sendable {
  public var report: URL?
  public var mark: Double
}

public enum CrashReport {
  public static let frameLimit = 15
  static let fieldLimit = 160

  public static func header(_ data: Data) -> [String: Any]? {
    let line = data.prefix { $0 != UInt8(ascii: "\n") }
    return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
  }

  public static let crashBugType = "309"

  public static func isOurs(_ data: Data, bundleId: String) -> Bool {
    guard !bundleId.isEmpty, let header = header(data) else { return false }
    return header["bundleID"] as? String == bundleId
  }

  public static func isOurCrash(_ data: Data, bundleId: String) -> Bool {
    guard isOurs(data, bundleId: bundleId), let header = header(data) else { return false }
    return (header["bug_type"] as? String ?? (header["bug_type"] as? NSNumber)?.stringValue) == crashBugType
  }

  public static func summary(_ data: Data, bundleId: String, home: String) -> CrashSummary? {
    guard isOurCrash(data, bundleId: bundleId), let header = header(data) else { return nil }
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
      let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any]
    else { return nil }
    let clean = { (text: String) in sanitize(text, home: home) }
    let exception = body["exception"] as? [String: Any] ?? [:]
    let images = body["usedImages"] as? [[String: Any]] ?? []
    let threads = body["threads"] as? [[String: Any]] ?? []
    let faulting = (body["faultingThread"] as? NSNumber)?.intValue
    let crashed = faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil } ?? threads.first { $0["triggered"] as? Bool == true }
    let frames = (crashed?["frames"] as? [[String: Any]] ?? []).prefix(frameLimit).enumerated().map { index, frame in
      let imageIndex = (frame["imageIndex"] as? NSNumber)?.intValue
      let image = imageIndex.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
      let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0
      let symbol = (frame["symbol"] as? String).map { name in
        let location = (frame["symbolLocation"] as? NSNumber)?.uint64Value ?? 0
        return "\(name) + \(location)"
      } ?? "0x\(String(offset, radix: 16))"
      return "\(index)  \(clean(image))  \(clean(symbol))"
    }
    let path = body["procPath"] as? String
    let main = images.first { path != nil && $0["path"] as? String == path } ?? images.first
    let bundle = body["bundleInfo"] as? [String: Any] ?? [:]
    let version = versionLine(
      (header["app_version"] as? String) ?? (bundle["CFBundleShortVersionString"] as? String) ?? "",
      (header["build_version"] as? String) ?? (bundle["CFBundleVersion"] as? String) ?? "")
    let exceptionType = token(exception["type"] as? String ?? "")
    guard !exceptionType.isEmpty, !frames.isEmpty else { return nil }
    return CrashSummary(
      exceptionType: exceptionType,
      signal: token(exception["signal"] as? String ?? ""),
      queue: clean(crashed?["queue"] as? String ?? ""),
      frames: Array(frames),
      binary: clean(main?["name"] as? String ?? ""),
      uuid: token(main?["uuid"] as? String ?? ""),
      version: clean(version))
  }

  static func versionLine(_ version: String, _ build: String) -> String {
    guard !version.isEmpty else { return build.isEmpty ? "" : "(\(build))" }
    return build.isEmpty || build == version ? version : "\(version) (\(build))"
  }

  static func token(_ text: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    return String(text.filter(allowed.contains).prefix(fieldLimit))
  }

  public static func sanitize(_ text: String, home: String) -> String {
    var out = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    if !home.isEmpty, home != "/" { out = out.replacingOccurrences(of: home, with: "~") }
    out = out.replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.\-]*://\S*"#, with: "<url>", options: .regularExpression)
    out = String(out.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
    return String(out.prefix(fieldLimit))
  }

  public static func scan(
    directory: URL, executable: String, bundleId: String, after mark: Double, fileManager: FileManager = .default
  ) -> CrashReportScan {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    var candidates: [(url: URL, modified: Double)] = []
    for url in entries {
      let name = url.lastPathComponent
      guard !executable.isEmpty, name.hasPrefix(executable), name.hasSuffix(".ips") else { continue }
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
        let modified = values.contentModificationDate?.timeIntervalSince1970, modified > mark else { continue }
      candidates.append((url, modified))
    }
    let newest = candidates.map(\.modified).max() ?? mark
    for candidate in candidates.sorted(by: { $0.modified > $1.modified }) {
      guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { continue }
      let head = (try? handle.read(upToCount: 8192)) ?? Data()
      try? handle.close()
      if isOurCrash(head, bundleId: bundleId) { return CrashReportScan(report: candidate.url, mark: newest) }
    }
    return CrashReportScan(report: nil, mark: newest)
  }
}
