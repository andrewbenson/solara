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
    HostedViews.register(sidebarPlayer) { windowId in
      let view = SidebarPlayerView()
      var tabId = ""
      view.onAction = { player("sidebarPlayer", windowId, tabId, $0) }
      return content(sidebarPlayer, windowId, view) { json in
        guard let state = MediaPlayerState.decode(json) else { return }
        tabId = state.tabId
        view.update(state)
      }
    }
    HostedViews.register(shareBar) { windowId in
      let view = ShareBarView()
      var target: (capturer: String, tabId: String) = ("", "")
      view.onAction = { action(windowId, "shareBar", target.tabId, ["action": $0.rawValue, "capturer": target.capturer]) }
      return content(shareBar, windowId, view) { json in
        guard let state = ShareBarState.decode(json) else { return }
        target = (state.capturer, state.tabId)
        view.update(state)
      }
    }
    HostedViews.register(smallBar) { windowId in
      let view = SmallBarView()
      var tabId = ""
      view.onAction = { smallBarAction(windowId, tabId, $0) }
      return content(smallBar, windowId, view) { json in
        guard let state = SmallBarState.decode(json) else { return }
        tabId = state.tabId ?? ""
        view.update(state)
      }
    }
    HostedViews.register(hoverPlayer) { windowId in
      let view = MiniPlayerView()
      var tabId = ""
      view.onAction = { player("hoverPlayer", windowId, tabId, $0) }
      return content(hoverPlayer, windowId, view) { json in
        guard let state = MediaPlayerState.decode(json) else { return }
        tabId = state.tabId
        view.update(state)
      }
    }
    HostedViews.register(castPicker) { windowId in
      let view = CastPickerView()
      let popover = PopoverView(body: view)
      var tabId = ""
      popover.onDismiss = { action(windowId, "castPicker", tabId, ["action": "dismiss"]) }
      view.onAction = { [weak popover] event in
        if case .height(let h) = event { popover?.set(bodyHeight: CGFloat(h)); return }
        castPicker(windowId, tabId, event)
      }
      return content(castPicker, windowId, popover) { json in
        guard let state = CastPickerState.decode(json), let placement = PopoverEnvelope.decode(json) else { return }
        tabId = state.tabId
        popover.set(placement: placement, dark: state.theme.dark)
        view.update(state)
      }
    }
    HostedViews.register(sharePicker) { windowId in
      let view = SharePickerView()
      let popover = PopoverView(body: view)
      var tabId = ""
      popover.onDismiss = { action(windowId, "sharePicker", tabId, ["action": "cancel"]) }
      view.onAction = { [weak popover] event in
        if case .height(let h) = event { popover?.set(bodyHeight: CGFloat(h)); return }
        sharePicker(windowId, tabId, event)
      }
      return content(sharePicker, windowId, popover, takesFocus: true) { json in
        guard let state = SharePickerState.decode(json), let placement = PopoverEnvelope.decode(json) else { return }
        tabId = state.tabId
        popover.set(placement: placement, dark: state.theme.dark)
        view.update(state)
      }
    }
    HostedViews.register(cliPill) { windowId in
      let view = CliControlPillView()
      view.onStop = { action(windowId, "cliStop") }
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

  static func castPicker(_ windowId: String, _ tabId: String, _ event: CastPickerAction) {
    switch event {
    case .cast(let id): action(windowId, "castPicker", tabId, ["action": "cast", "sinkId": id])
    case .stop(let id): action(windowId, "castPicker", tabId, ["action": "stop", "sinkId": id])
    case .source: action(windowId, "castPicker", tabId, ["action": "source"])
    case .link: action(windowId, "castPicker", tabId, ["action": "link"])
    case .done: action(windowId, "castPicker", tabId, ["action": "done"])
    case .height: break
    }
  }

  static func sharePicker(_ windowId: String, _ tabId: String, _ event: SharePickerAction) {
    switch event {
    case .select(let id): action(windowId, "sharePicker", tabId, ["action": "select", "id": id])
    case .share(let id): action(windowId, "sharePicker", tabId, ["action": "share", "id": id ?? NSNull()])
    case .cancel: action(windowId, "sharePicker", tabId, ["action": "cancel"])
    case .audio(let on): action(windowId, "sharePicker", tabId, ["action": "audio", "value": on])
    case .height: break
    }
  }

  static func smallBarAction(_ windowId: String, _ tabId: String, _ event: SmallBarAction) {
    switch event {
    case .button(let id): action(windowId, "smallBar", tabId, ["action": id])
    case .fieldClick: action(windowId, "smallBar", tabId, ["action": "field"])
    case .fieldMenu: action(windowId, "smallBar", tabId, ["action": "fieldMenu"])
    case .profile: action(windowId, "smallBar", tabId, ["action": "profile"])
    }
  }

  static func player(_ source: String, _ windowId: String, _ tabId: String, _ action: MediaAction) {
    var extra: [String: Any] = ["action": action.name]
    if let seconds = action.seconds { extra["seconds"] = seconds }
    NativeMedia.action(windowId, source, tabId, extra)
  }

  static func action(_ windowId: String, _ name: String, _ tabId: String = "", _ extra: [String: Any] = [:]) {
    let payload = MediaPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js("media.action", windowId, name, tabId, payload.value)
    }
  }

  static func probe(kind: String, windowId: String) -> String {
    var views: [NSView] = mounted.filter { $0.kind == kind && $0.windowId == windowId }.compactMap { $0.view.value }
    if kind == sidebarPlayer { views += NativeSidebar.players(windowId: windowId) }
    if kind == hoverPlayer { views += NativeSidebarHoverCard.players(windowId: windowId) }
    views += NativePaneOverlays.host(windowId)?.mediaViews(kind) ?? []
    if kind == shareBar { views += NativeShareBand.bars(windowId) }
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
          return ["corners": player.cornersShown, "seek": player.seekProgress, "height": player.frame.height, "frames": frames(player, player.controlFrames)]
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
