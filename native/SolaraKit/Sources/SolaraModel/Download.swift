import Foundation

public enum DownloadAction: String, Sendable {
  case open, reveal, trash, pause, resume, keep, cancel, remove, retry, source, copy, whenDone
}

public struct Download: Sendable, Hashable {
  public var json: JSONObject

  public init(json: JSONObject) {
    self.json = json
  }

  public var id: String {
    get { json["id"]?.string ?? "" }
    set { json["id"] = .string(newValue) }
  }

  public var profile: String? { json["profile"]?.string }
  public var offTheRecord: Bool { json["offTheRecord"]?.truthy ?? false }
  public var state: String? { json["state"]?.string }
  public var isDownloading: Bool { state == "downloading" }
  public var isPrivate: Bool { offTheRecord || (profile.map(Ids.isIncognitoProfile) ?? false) }

  public var url: String { json["url"]?.string ?? "" }
  public var filename: String { json["filename"]?.string ?? "" }
  public var path: String { json["path"]?.string ?? "" }
  public var paused: Bool { json["paused"]?.bool == true }
  public var dangerous: Bool { isDownloading && json["dangerous"]?.bool == true }

  public func allows(_ action: DownloadAction, fileExists: Bool = false) -> Bool {
    switch action {
    case .open, .reveal, .trash: state == "finished" && fileExists
    case .pause: isDownloading && !dangerous && !paused
    case .resume: isDownloading && !dangerous && paused
    case .keep: dangerous
    case .cancel: isDownloading
    case .remove: !isDownloading
    case .retry:
      (state == "failed" || state == "cancelled") && URLComponents(string: url).map {
        ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false
      } == true
    case .source, .copy: !url.isEmpty
    case .whenDone: isDownloading && !dangerous
    }
  }

  public static let maxKept = 100
  static let stagingKeys = ["staging", "stagingId", "destination"]

  public var leftStaging: (path: String, uuid: String, folder: String)? {
    let stagingId = json["stagingId"]?.string
    let uuid = stagingId ?? (id.hasPrefix("wk-download-") ? String(id.dropFirst("wk-download-".count)) : "")
    let destination = json["destination"]?.string ?? ""
    let folder = destination.lastIndex(of: "/").map { String(destination[..<$0]) } ?? String(destination.dropLast())
    guard let staging = json["staging"]?.string, !staging.isEmpty, !uuid.isEmpty, !folder.isEmpty, !isDownloading else { return nil }
    return (staging, uuid, folder)
  }

  public func withoutStaging() -> Download {
    var next = json
    for key in Self.stagingKeys { next.removeValue(forKey: key) }
    return Download(json: next)
  }

  public func persisted() -> Download {
    guard isDownloading else { return self }
    var next = json
    next["state"] = "failed"
    return Download(json: next)
  }

  public func loaded(at index: Int) -> Download {
    let id = "saved-\(index)"
    guard let left = leftStaging else {
      var kept = withoutStaging()
      kept.id = id
      return kept
    }
    var next = self
    next.id = id
    next.json["stagingId"] = .string(left.uuid)
    return next
  }
}
