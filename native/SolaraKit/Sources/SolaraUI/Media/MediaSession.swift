import AppKit
import Foundation

public struct MediaPlayerState: Decodable, Equatable, Sendable {
  public var tabId: String
  public var title: String
  public var subtitle: String
  public var muted: Bool
  public var playbackState: String
  public var position: Double
  public var timestamp: Double
  public var playbackRate: Double
  public var duration: Double?
  public var tracks: Bool
  public var artwork: String?
  public var url: String
  public var favicon: String?
  public var profileId: String
  public var theme: MediaThemeState
  public var profileName: String?
  public var profileColor: String?
  public var hasVideo: Bool?
  public var holdsPictureInPicture: Bool?

  public var playing: Bool { playbackState == "playing" }
  public var ended: Bool {
    guard !playing, let duration, duration > 0 else { return false }
    return position >= duration - 0.25
  }

  public init(tabId: String, title: String, subtitle: String, muted: Bool, playbackState: String, position: Double, timestamp: Double,
    playbackRate: Double, duration: Double?, tracks: Bool, artwork: String?, url: String, favicon: String?, profileId: String,
    theme: MediaThemeState, profileName: String? = nil, profileColor: String? = nil, hasVideo: Bool? = nil, holdsPictureInPicture: Bool? = nil) {
    self.tabId = tabId
    self.title = title
    self.subtitle = subtitle
    self.muted = muted
    self.playbackState = playbackState
    self.position = position
    self.timestamp = timestamp
    self.playbackRate = playbackRate
    self.duration = duration
    self.tracks = tracks
    self.artwork = artwork
    self.url = url
    self.favicon = favicon
    self.profileId = profileId
    self.theme = theme
    self.profileName = profileName
    self.profileColor = profileColor
    self.hasVideo = hasVideo
    self.holdsPictureInPicture = holdsPictureInPicture
  }

  public var inPictureInPicture: Bool { holdsPictureInPicture == true }
  public var offersPictureInPicture: Bool { hasVideo == true || inPictureInPicture }

  public static func decode(_ json: String) -> MediaPlayerState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(MediaPlayerState.self, from: data)
  }

  public func position(at nowMs: Double) -> Double {
    let elapsed = playing ? (nowMs - timestamp) / 1000 * (playbackRate == 0 ? 1 : playbackRate) : 0
    let value = position + elapsed
    if let duration, duration > 0 { return min(max(0, value), duration) }
    return max(0, value)
  }

  public var hasDuration: Bool { (duration ?? 0) > 0 }
}

public enum MediaClock {
  public static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

public enum MediaFormat {
  public static let skipSeconds = 15

  public static func time(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? floor(seconds) : 0))
    let h = s / 3600
    let m = (s % 3600) / 60
    let ss = String(format: "%02d", s % 60)
    return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
  }
}

public enum MediaAction: Equatable, Sendable {
  case backToTab
  case toggle
  case previous
  case next
  case skip(Int)
  case seek(Double)
  case toggleMute
  case dismiss
  case enterPictureInPicture
  case minimizePictureInPicture

  public var name: String {
    switch self {
    case .backToTab: "backToTab"
    case .toggle: "toggle"
    case .previous: "previous"
    case .next: "next"
    case .skip: "skip"
    case .seek: "seek"
    case .toggleMute: "toggleMute"
    case .dismiss: "dismiss"
    case .enterPictureInPicture: "enterPictureInPicture"
    case .minimizePictureInPicture: "minimizePictureInPicture"
    }
  }

  public var seconds: Double? {
    switch self {
    case .skip(let s): Double(s)
    case .seek(let s): s
    default: nil
    }
  }
}

@MainActor
public enum MediaImages {
  public static var load: ((String) -> NSImage?)?
  public static let favicons = SidebarFavicons()
  private static var cache: [String: NSImage] = [:]

  static func image(_ uri: String) -> NSImage? {
    if let hit = cache[uri] { return hit }
    guard let image = load?(uri) else { return nil }
    if cache.count > 24 { cache.removeAll() }
    cache[uri] = image
    return image
  }

  static func sidebarPalette(_ theme: MediaThemeState) -> SidebarPalette {
    var host = SidebarHostState(profileId: "", dark: theme.dark)
    host.theme = theme.colors
    return SidebarPalette(host)
  }
}
