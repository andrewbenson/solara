import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeMedia {
  static let cliPill = "media.cliPill"
  static let sidebarPlayer = "media.sidebarPlayer"
  static let hoverPlayer = "media.hoverPlayer"
  static let shareBar = "media.shareBar"
  static let castPicker = "media.castPicker"
  static let sharePicker = "media.sharePicker"
  static let smallBar = "littleSolara.bar"

  private static var mounted: [(kind: String, windowId: String, view: WeakMediaView)] = []

  private static var indicatorMirror: NSObjectProtocol?
  nonisolated private static let cliShownLock = NSLock()
  nonisolated(unsafe) private static var cliShownValue: Bool?
  nonisolated static var cliShown: Bool? { cliShownLock.withLock { cliShownValue } }

  static func register() {
    mirrorCliIndicator()
    MediaImages.load = { SettingsAdapters.image($0) }
    MediaImages.favicons.loader = { request in
      return await NativeHistoryCatalog.favicon(page: request.url, source: request.favicon, profileId: request.profileId, dark: request.dark)
    }
    HostedViews.register(smallBar) { windowId in
      let view = SmallBarView()
      view.onAction = { [weak view] action in
        if let view { NativeLittleSolara.barAction(action, windowId: windowId, bar: view) }
      }
      return content(smallBar, windowId, view) { json in
        guard let state = SmallBarState.decode(json) else { return }
        view.update(state)
      }
    }
    HostedViews.register("media.tabBadge") { _ in
      let view = TabBadgesView()
      var tabId = ""
      let update: @MainActor () -> Void = {
        view.set(pip: false, capture: NowPlayingStore.shared.capture[tabId], iconSize: 16, badge: .clear, badgeGlyph: .clear)
      }
      let listener = NativeMediaStack.listen(update)
      return HostedContent(view: view, onUnmount: { NativeMediaStack.stopListening(listener) }, takesFocus: false) { json in
        tabId = (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? ""
        update()
      }
    }
    HostedViews.register(cliPill) { windowId in
      let view = CliControlPillView()
      view.onStop = { NativeCliControl.shared.stop() }
      return content(cliPill, windowId, view) { json in
        if let state = CliPillState.decode(json) { view.update(state) }
      }
    }
  }

  private static func mirrorCliIndicator() {
    guard indicatorMirror == nil else { return }
    indicatorMirror = NotificationCenter.default.addObserver(forName: CliPillIndicator.changed, object: CliPillIndicator.shared, queue: .main) { _ in
      MainActor.assumeIsolated {
        guard let status = CliPillIndicator.shared.status else { return }
        cliShownLock.withLock { cliShownValue = status.shown }
        action("", "cliIndicator", "", ["shown": status.shown])
      }
    }
    let seeded = CliPillIndicator.shared.status?.shown
    cliShownLock.withLock { cliShownValue = seeded }
  }

  private static func content(_ kind: String, _ windowId: String, _ view: NSView, takesFocus: Bool = false, onState: @escaping (String) -> Void) -> HostedContent {
    HostedContent(view: view, onUnmount: track(kind, windowId, view), takesFocus: takesFocus, onState: onState)
  }

  static func track(_ kind: String, _ windowId: String, _ view: NSView) -> () -> Void {
    mounted.removeAll { $0.view.value == nil }
    let entry = WeakMediaView(view)
    mounted.append((kind, windowId, entry))
    return { mounted.removeAll { $0.view === entry } }
  }

  static func action(_ windowId: String, _ name: String, _ tabId: String = "", _ extra: [String: Any] = [:]) {
    let payload = MediaPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js("media.action", windowId, name, tabId, payload.value)
    }
  }

  static func probe(kind: String, windowId: String) -> String {
    if kind == "media.pictureInPicture" {
      let data = try? JSONSerialization.data(withJSONObject: NowPlayingStore.shared.pictureInPicture)
      return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    if kind == "media.nowPlaying" {
      let rows: [[String: Any]] = NowPlayingStore.shared.entries.map { id, entry in
        ["tabId": id, "playbackState": entry.report.playbackState, "controllable": entry.report.controllable,
          "touchedAt": entry.touchedAt, "removed": entry.removed, "title": entry.report.title, "hasVideo": entry.report.hasVideo]
      }
      let json = try? JSONSerialization.data(withJSONObject: rows)
      return json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    var views: [NSView] = mounted.filter { $0.kind == kind && $0.windowId == windowId }.compactMap { $0.view.value }
    if kind == castPicker { views += NativeCast.views(windowID: windowId) }
    if kind == sidebarPlayer { views += NativeSidebar.players(windowId: windowId) }
    if kind == hoverPlayer { views += NativeSidebarHoverCard.players(windowId: windowId) }
    views += NativePaneOverlays.host(windowId)?.mediaViews(kind) ?? []
    if kind == sharePicker { views += NativeDisplayCapture.views(windowID: windowId) }
    if kind == shareBar { views += NativeShareBand.bars(windowId) + NativeDisplayCapture.inlineBars(windowId) }
    func frames(_ view: NSView, _ controls: [String: CGRect]) -> [String: [Double]] {
      guard let content = view.window?.contentView else { return [:] }
      return controls.mapValues { rect in
        let r = view.convert(rect, to: content)
        return [r.minX, content.bounds.height - r.maxY, r.width, r.height]
      }
    }
    let rows: [[String: Any]] = views.compactMap { view in
      @MainActor
      func readRow() -> [String: Any]? {
        if let mini = view as? MiniPlayerView {
          return [
            "marquee": mini.marqueeProgress, "titleShift": mini.titleShift, "titleOverflow": mini.titleOverflow, "artistOverflow": mini.artistOverflow,
            "hover": mini.hoverProgress ?? NSNull(), "elapsed": mini.elapsedText, "artwork": mini.showsArtwork, "t": CACurrentMediaTime(), "frames": frames(mini, mini.controlFrames),
          ]
        }
        if let bar = view as? SmallBarView {
          return ["progress": Double(bar.progressWidth), "hovered": bar.fieldHovered, "frames": frames(bar, bar.controlFrames)]
        }
        if let bar = view as? ShareBarView {
          return ["primary": bar.primaryTitle, "frames": frames(bar, bar.controlFrames)]
        }
        if let popover = view as? PopoverView {
          var row: [String: Any] = [
            "card": frames(popover, ["card": popover.cardFrame])["card"] ?? [], "progress": popover.progress, "opacity": popover.presentedOpacity,
            "t": CACurrentMediaTime(), "focused": popover.window?.firstResponder === popover,
          ]
          if let picker = popover.body as? SharePickerView {
            row["height"] = picker.contentHeight
            row["selected"] = picker.selectedId ?? NSNull()
            row["frames"] = frames(picker, picker.controlFrames)
          } else if let picker = popover.body as? CastPickerView {
            row["height"] = picker.contentHeight
            row["frames"] = frames(picker, picker.controlFrames)
          }
          return row
        }
        if let player = view as? SidebarPlayerView {
          return ["corners": player.cornersShown, "seek": player.seekProgress, "height": player.frame.height, "frames": frames(player, player.controlFrames),
            "tabId": player.tabId ?? NSNull(), "peeking": player.peeking, "leaving": player.leaving, "subtitle": player.subtitleShown, "t": CACurrentMediaTime(),
            "py": Double(player.layer?.presentation()?.frame.minY ?? player.frame.minY), "px": Double(player.layer?.presentation()?.frame.minX ?? player.frame.minX),
            "opacity": Double(player.layer?.presentation()?.opacity ?? Float(player.alphaValue))]
        }
        guard let pill = view as? CliControlPillView, let content = pill.window?.contentView else { return nil }
        let frame = pill.convert(pill.pillFrame, to: content)
        let presented = pill.subviews.first?.layer?.presentation()
        return [
          "shown": pill.shown, "progress": pill.progress, "opacity": Double(presented?.opacity ?? 0), "t": CACurrentMediaTime(), "stopClipped": pill.stopTitleClipped,
          "frame": [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height],
        ]
      }
      guard var row = readRow() else { return nil }
#if SOLARA_PROBES
      row["labels"] = MediaRead.labels(view: view)
#endif
      return row
    }
    let json = try? JSONSerialization.data(withJSONObject: rows)
    return json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }
}

struct PopoverEnvelope: Decodable {
  let popover: PopoverPlacement

  static func decode(_ json: String) -> PopoverPlacement? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONDecoder().decode(PopoverEnvelope.self, from: data))?.popover
  }
}

final class WeakMediaView {
  weak var value: NSView?

  init(_ value: NSView) { self.value = value }
}

struct MediaPayload: @unchecked Sendable {
  let value: [String: Any]

  init(_ value: [String: Any]) { self.value = value }
}

#if SOLARA_PROBES
@MainActor
public enum MediaRead {
  public static var kinds: [String] { HostedViews.kinds }

  public static func labels(view: NSView) -> [String: String] {
    let labels: [String: String]
    if let player = view as? SidebarPlayerView { labels = player.controlLabels }
    else if let mini = view as? MiniPlayerView { labels = mini.controlLabels }
    else if let pill = view as? CliControlPillView { labels = pill.controlLabels }
    else if let bar = view as? ShareBarView { labels = bar.controlLabels }
    else if let popover = view as? PopoverView, let picker = popover.body as? CastPickerView { labels = picker.controlLabels }
    else if let popover = view as? PopoverView, let picker = popover.body as? SharePickerView { labels = picker.controlLabels }
    else { labels = [:] }
    return labels.mapValues { String($0.prefix(128)) }
  }

  public static func rows(kind: String, windowId: String) -> [[String: Any]] {
    guard let data = NativeMedia.probe(kind: kind, windowId: windowId).data(using: .utf8) else { return [] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
  }
}
#endif
