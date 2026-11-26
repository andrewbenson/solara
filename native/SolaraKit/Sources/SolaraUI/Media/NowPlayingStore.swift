import Foundation
import SolaraModel
import Synchronization

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
    public let sessionID = UUID()

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
    var ended: Bool

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
      ended = report.ended
    }
  }

  public nonisolated static let shared = NowPlayingStore()
  public static let didChange = Notification.Name("SolaraNowPlayingChanged")

  public private(set) var entries: [String: Entry] = [:]
  public private(set) var pictureInPicture: [String: String] = [:]
  private var pipReceipts: [String: UUID] = [:]
  private nonisolated let protection = Mutex<[String: MediaProtection]>([:])

  private struct MediaProtection: Sendable {
    var playing: Bool
    var pip: Bool
    var hasSession: Bool
  }

  struct Snapshot {
    let entry: Entry?
    let heldOrder: Double?
    let pictureInPicture: String?
    let capture: TabCapture?
  }

  enum Field: Hashable {
    case session
    case pictureInPicture(String)
    case capture
  }

  public private(set) var capture: [String: TabCapture] = [:]
  private var heldOrder: [String: Double] = [:]
  public static let holdOrderMs: Double = 3000
  var now: () -> Double = MediaClock.nowMs

  public nonisolated init() {}

  public func report(tabId: String, _ report: NowPlayingReport?) {
    guard let report else {
      heldOrder[tabId] = nil
      guard entries.removeValue(forKey: tabId) != nil else { return }
      updateProtection(tabId)
      return changed()
    }
    let before = entries[tabId]
    var entry = before ?? Entry(report: report, touchedAt: 0, removed: false)
    entry.report = report
    let startedPlaying = report.controllable && report.playing && !(before.map { $0.report.controllable && $0.report.playing } ?? false)
    let pausedNow = before?.report.playing == true && report.playbackState == "paused"
    let held = pausedNow && heldOrder.removeValue(forKey: tabId).map { $0 > now() } == true
    if startedPlaying { heldOrder[tabId] = nil }
    if startedPlaying || (pausedNow && !held) { entry.touchedAt = now() }
    if startedPlaying { entry.removed = false }
    guard entry != before else { return }
    entries[tabId] = entry
    if before?.report.playing != entry.report.playing { updateProtection(tabId) }
    if entry.shown != before?.shown { changed() }
  }

  public func holdOrder(_ tabId: String) {
    guard entries[tabId] != nil else { return }
    heldOrder[tabId] = now() + Self.holdOrderMs
  }

  public func touch(_ tabId: String) {
    guard var entry = entries[tabId] else { return }
    entry.touchedAt = now()
    entries[tabId] = entry
    changed()
  }

  public func seek(tabId: String, seconds: Double, relative: Bool) {
    guard seconds.isFinite, var entry = entries[tabId] else { return }
    let clock = now()
    let report = entry.report
    let elapsed = report.playing ? (clock - report.timestamp) / 1000 * (report.playbackRate == 0 ? 1 : report.playbackRate) : 0
    let limit = report.duration ?? .infinity
    let position = max(0, min(report.position + elapsed, limit))
    entry.report.position = max(0, min(relative ? position + seconds : seconds, limit))
    entry.report.timestamp = clock
    entries[tabId] = entry
    changed()
  }

  public func remove(_ tabId: String) {
    guard var entry = entries[tabId], !entry.removed else { return }
    entry.removed = true
    entries[tabId] = entry
    changed()
  }

  public func setPictureInPicture(tabId: String, kind: String, active: Bool) {
    guard kind == "video" || kind == "document" else { return }
    let before = pictureInPicture[tabId]
    if active {
      guard before != kind else { return }
      pictureInPicture[tabId] = kind
      pipReceipts[tabId] = UUID()
      touch(tabId)
    } else {
      guard before == kind else { return }
      pictureInPicture[tabId] = nil
      pipReceipts[tabId] = nil
    }
    updateProtection(tabId)
    changed()
  }

  public func setCapture(tabId: String, _ kind: TabCapture?) {
    guard capture[tabId] != kind else { return }
    capture[tabId] = kind
    changed()
  }

  func pipReceipt(tabId: String) -> UUID? { pipReceipts[tabId] }

  func snapshot(tabId: String) -> Snapshot? {
    let entry = entries[tabId], pip = pictureInPicture[tabId], capture = capture[tabId]
    guard entry != nil || pip != nil || capture != nil else { return nil }
    return Snapshot(entry: entry, heldOrder: heldOrder[tabId], pictureInPicture: pip, capture: capture)
  }

  func restore(_ state: Snapshot, tabId: String, excluding reported: Set<Field>) {
    var restored = false
    if let entry = state.entry, entries[tabId] == nil, !reported.contains(.session) {
      entries[tabId] = entry
      heldOrder[tabId] = state.heldOrder
      restored = true
    }
    if let kind = state.pictureInPicture, pictureInPicture[tabId] == nil, !reported.contains(.pictureInPicture(kind)) {
      pictureInPicture[tabId] = kind
      pipReceipts[tabId] = UUID()
      restored = true
    }
    if let kind = state.capture, capture[tabId] == nil, !reported.contains(.capture) {
      capture[tabId] = kind
      restored = true
    }
    guard restored else { return }
    updateProtection(tabId)
    changed()
  }

  public func end(tabId: String) {
    let hasState = snapshot(tabId: tabId) != nil
    entries[tabId] = nil
    heldOrder[tabId] = nil
    pictureInPicture[tabId] = nil
    pipReceipts[tabId] = nil
    capture[tabId] = nil
    guard hasState else { return }
    updateProtection(tabId)
    changed()
  }

  public func retain(tabIds: Set<String>) {
    let gone = Set(entries.keys).union(pictureInPicture.keys).union(capture.keys).subtracting(tabIds)
    for id in gone { end(tabId: id) }
  }

  private func updateProtection(_ tabId: String) {
    let report = entries[tabId]?.report
    let pip = pictureInPicture[tabId] != nil
    let state = report == nil && !pip ? nil : MediaProtection(playing: report?.playing == true, pip: pip, hasSession: report != nil)
    protection.withLock { $0[tabId] = state }
  }

  public nonisolated func protectionReason(tabId: String, pinned: Bool) -> String? {
    guard let state = protection.withLock({ $0[tabId] }) else { return nil }
    if state.pip { return "picture in picture" }
    return state.playing || (pinned && state.hasSession) ? "media" : nil
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
