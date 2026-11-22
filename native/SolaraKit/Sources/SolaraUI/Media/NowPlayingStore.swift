import Foundation
import SolaraModel

public struct NowPlayingReport: Equatable, Sendable {
  public var title: String
  public var artist: String
  public var artwork: String?
  public var playbackState: String
  public var position: Double
  public var duration: Double?
  public var playbackRate: Double
  public var timestamp: Double
  public var hasVideo: Bool
  public var controllable: Bool
  public var actions: [String]

  public init(title: String = "", artist: String = "", artwork: String? = nil, playbackState: String, position: Double = 0,
    duration: Double? = nil, playbackRate: Double = 1, timestamp: Double = 0, hasVideo: Bool = false,
    controllable: Bool = true, actions: [String] = []) {
    self.title = title
    self.artist = artist
    self.artwork = artwork
    self.playbackState = playbackState
    self.position = position
    self.duration = duration
    self.playbackRate = playbackRate
    self.timestamp = timestamp
    self.hasVideo = hasVideo
    self.controllable = controllable
    self.actions = actions
  }

  public init?(payload: [String: Any]) {
    guard let state = payload["state"] as? [String: Any] else { return nil }
    let number = { (key: String) -> Double? in (state[key] as? NSNumber)?.doubleValue }
    let playback = state["playbackState"] as? String ?? "none"
    self.init(
      title: state["title"] as? String ?? "", artist: state["artist"] as? String ?? "", artwork: state["artwork"] as? String,
      playbackState: ["playing", "paused"].contains(playback) ? playback : "none", position: max(0, number("position") ?? 0),
      duration: number("duration"), playbackRate: number("playbackRate") ?? 1, timestamp: number("timestamp") ?? 0,
      hasVideo: (state["hasVideo"] as? NSNumber)?.boolValue ?? false, controllable: (state["controllable"] as? NSNumber)?.boolValue ?? false,
      actions: state["actions"] as? [String] ?? [])
  }

  public init?(json: JSONValue) {
    guard let state = json.object?["state"]?.object else { return nil }
    let playback = state["playbackState"]?.string ?? "none"
    self.init(
      title: state["title"]?.string ?? "", artist: state["artist"]?.string ?? "", artwork: state["artwork"]?.string,
      playbackState: ["playing", "paused"].contains(playback) ? playback : "none", position: max(0, state["position"]?.number ?? 0),
      duration: state["duration"]?.number, playbackRate: state["playbackRate"]?.number ?? 1, timestamp: state["timestamp"]?.number ?? 0,
      hasVideo: state["hasVideo"]?.bool ?? false, controllable: state["controllable"]?.bool ?? false,
      actions: state["actions"]?.array?.compactMap(\.string) ?? [])
  }

  public var playing: Bool { playbackState == "playing" }

  public var ended: Bool {
    guard !playing, let duration, duration > 0 else { return false }
    return position >= duration - 0.25
  }
}

@MainActor
public final class NowPlayingStore {
  public struct Entry: Equatable, Sendable {
    public var report: NowPlayingReport
    public var touchedAt: Double
    public var removed: Bool

    var shown: Shown { Shown(report: report, touchedAt: touchedAt, removed: removed) }
  }

  struct Shown: Equatable {
    var title: String
    var artist: String
    var artwork: String?
    var playbackState: String
    var duration: Double?
    var hasVideo: Bool
    var controllable: Bool
    var touchedAt: Double
    var removed: Bool

    init(report: NowPlayingReport, touchedAt: Double, removed: Bool) {
      title = report.title
      artist = report.artist
      artwork = report.artwork
      playbackState = report.playbackState
      duration = report.duration
      hasVideo = report.hasVideo
      controllable = report.controllable
      self.touchedAt = touchedAt
      self.removed = removed
    }
  }

  public static let shared = NowPlayingStore()
  public static let didChange = Notification.Name("SolaraNowPlayingChanged")

  public private(set) var entries: [String: Entry] = [:]
  var now: () -> Double = MediaClock.nowMs

  public init() {}

  public func report(tabId: String, _ report: NowPlayingReport?) {
    guard let report else {
      guard entries.removeValue(forKey: tabId) != nil else { return }
      return changed()
    }
    let before = entries[tabId]
    var entry = before ?? Entry(report: report, touchedAt: 0, removed: false)
    entry.report = report
    let startedPlaying = report.controllable && report.playing && !(before.map { $0.report.controllable && $0.report.playing } ?? false)
    let pausedNow = before?.report.playing == true && report.playbackState == "paused"
    if startedPlaying || pausedNow { entry.touchedAt = now() }
    if startedPlaying { entry.removed = false }
    guard entry != before else { return }
    entries[tabId] = entry
    if entry.shown != before?.shown { changed() }
  }

  public func touch(_ tabId: String) {
    guard var entry = entries[tabId] else { return }
    entry.touchedAt = now()
    entries[tabId] = entry
    changed()
  }

  public func remove(_ tabId: String) {
    guard var entry = entries[tabId], !entry.removed else { return }
    entry.removed = true
    entries[tabId] = entry
    changed()
  }

  public func retain(tabIds: Set<String>) {
    let gone = entries.keys.filter { !tabIds.contains($0) }
    guard !gone.isEmpty else { return }
    for id in gone { entries[id] = nil }
    changed()
  }

  private var posting = false

  private func changed() {
    guard !posting else { return }
    posting = true
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.posting = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
      }
    }
  }
}
