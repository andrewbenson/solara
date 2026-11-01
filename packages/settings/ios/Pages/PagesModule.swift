import AppKit
import ExpoModulesCore
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

public class PagesModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPages")

    Function("available") { () -> Bool in
      NativeSettingsHandle.active
    }

    Events("onMeetingAlertEvent")

    AsyncFunction("showMeetingAlert") { (windowId: String, json: String, left: Double, top: Double) -> Bool in
      let sink = PagesEventSink(self)
      return MainActor.assumeIsolated {
        MeetingAlertHost.show(windowId: windowId, json: json, left: left, top: top) { body in sink.module?.sendEvent("onMeetingAlertEvent", body) }
      }
    }.runOnQueue(.main)

    AsyncFunction("hideMeetingAlert") { (windowId: String) in
      MainActor.assumeIsolated { MeetingAlertHost.hide(windowId: windowId) }
    }.runOnQueue(.main)

    AsyncFunction("devPages") { () -> String in
      MainActor.assumeIsolated { NativePageView.devState() }
    }.runOnQueue(.main)

    AsyncFunction("devDropTarget") { (windowNumber: Int, x: Double, y: Double, type: String) -> String in
      MainActor.assumeIsolated { DropProbe.json(DropProbe.target(windowNumber: windowNumber, x: x, y: y, type: type)) }
    }.runOnQueue(.main)

    AsyncFunction("devViewFrame") { (windowNumber: Int, needle: String) -> String in
      MainActor.assumeIsolated { DropProbe.json(DropProbe.frame(windowNumber: windowNumber, classContains: needle)) }
    }.runOnQueue(.main)

    AsyncFunction("devPageHover") { (key: String?) in
      MainActor.assumeIsolated { NativePageView.devHover(key) }
    }.runOnQueue(.main)

    View(NativePageView.self) {
      Events("onPageEvent")

      Prop("kind") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setKind(v) } }
      Prop("state") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setState(v) } }

      AsyncFunction("focusSearch") { (view: NativePageView) in MainActor.assumeIsolated { view.focusSearch() } }.runOnQueue(.main)
    }
  }
}

@MainActor
enum PageNetwork {
  static let favicons = PageFavicons(
    load: { url, favicon, profile, dark in
      await NativeHistoryCatalog.favicon(page: url, source: favicon, profileId: profile, dark: dark)
    },
    bundled: { name in NativeSettingsWindow.bundledSiteIcon(name) })
}

final class NativePageView: ExpoView {
  let onPageEvent = EventDispatcher()
  private var kind = ""
  private var json = ""
  private var host: NSView?
  private let downloads = DownloadsPageModel()
  private let history = HistoryPageModel(catalog: NativeHistoryCatalog.catalog)
  private let bookmarks = BookmarksPageModel(catalog: NativeHistoryCatalog.catalog)
  private let bookmarkForm = BookmarkFormModel()
  private let createProfile = CreateProfileFormModel()
  private let liveCard = LiveCardModel()

  override var isFlipped: Bool { true }

  static let live = NSHashTable<NativePageView>.weakObjects()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    downloads.onEvent = { [weak self] event in self?.send(event) }
    history.onEvent = { [weak self] event in self?.send(event) }
    bookmarks.onEvent = { [weak self] event in self?.send(event) }
    bookmarkForm.onEvent = { [weak self] event in self?.send(event) }
    createProfile.onEvent = { [weak self] event in self?.send(event) }
    liveCard.onEvent = { [weak self] event in self?.send(event) }
    Self.live.add(self)
    PageProbe.enabled = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
  }

  static func devState() -> String {
    let pages: [[String: Any]] = live.allObjects.filter { $0.window != nil }.map { view in
      var page: [String: Any] = ["kind": view.kind]
      switch view.kind {
      case "downloads":
        page["query"] = view.downloads.query
        page["shown"] = view.downloads.shown.map(\.id)
      case "history":
        page["query"] = view.history.query
        page["shown"] = view.history.shown
        page["selected"] = view.history.selected.sorted()
        page["clearOpen"] = view.history.clearOpen
      case "bookmarks":
        page["query"] = view.bookmarks.query
        page["shown"] = view.bookmarks.ids
        page["selected"] = view.bookmarks.selected
        page["folder"] = view.bookmarks.folderId ?? NSNull()
        page["undo"] = view.bookmarks.undoCount ?? NSNull()
      case "bookmarkForm":
        page["name"] = view.bookmarkForm.name
        page["url"] = view.bookmarkForm.url
        page["folder"] = view.bookmarkForm.folderId ?? NSNull()
        page["valid"] = view.bookmarkForm.valid
      default: break
      }
      page["ax"] = axLines(view.host, depth: 0)
      page["frames"] = view.probeFrames()
      return page
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["pages": pages]), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

  static func devHover(_ key: String?) {
    for view in live.allObjects where view.window != nil {
      view.history.devHover = key
      view.bookmarks.devHover = key
    }
  }

  private func probeFrames() -> [[String: Any]] {
    PageProbe.items.values.map { item in
      ["label": item.label, "x": item.frame.minX, "y": item.frame.minY, "width": item.frame.width, "height": item.frame.height]
    }
  }

  private static func axLines(_ element: Any?, depth: Int) -> [String] {
    guard let element = element as? NSAccessibilityElementProtocol & NSObject, depth < 30 else { return [] }
    let role = (element as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "?"
    let label = (element as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
    var lines = ["\(String(repeating: " ", count: depth))\(role)\(label.isEmpty ? "" : ": \(label)")"]
    for child in (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? [] { lines += axLines(child, depth: depth + 1) }
    return lines
  }

  func setKind(_ next: String) {
    guard next != kind else { return }
    kind = next
    host?.removeFromSuperview()
    let made: NSView? =
      switch next {
      case "downloads": NSHostingView(rootView: DownloadsPageView(model: downloads))
      case "history": NSHostingView(rootView: HistoryPageView(model: history, favicons: PageNetwork.favicons))
      case "bookmarks": NSHostingView(rootView: BookmarksPageView(model: bookmarks, favicons: PageNetwork.favicons))
      case "bookmarkForm": NSHostingView(rootView: BookmarkFormView(model: bookmarkForm))
      case "createProfile": NSHostingView(rootView: CreateProfileFormView(model: createProfile))
      case "calendarPreview", "meetingAlert": NSHostingView(rootView: LiveCardView(model: liveCard))
      default: nil
      }
    guard let made else { return }
    if next == "bookmarkForm" { (made as? NSHostingView<BookmarkFormView>)?.safeAreaRegions = [] }
    made.frame = bounds
    made.autoresizingMask = [.width, .height]
    addSubview(made)
    host = made
    if !json.isEmpty { apply() }
  }

  func setState(_ next: String) {
    guard next != json else { return }
    json = next
    apply()
  }

  func focusSearch() {
    switch kind {
    case "downloads": downloads.focusRequest += 1
    case "history": history.focusRequest += 1
    case "bookmarks": bookmarks.focusRequest += 1
    default: break
    }
  }

  private func apply() {
    switch kind {
    case "downloads": downloads.apply(json: json)
    case "history": history.apply(json: json)
    case "bookmarks": bookmarks.apply(json: json)
    case "bookmarkForm": bookmarkForm.apply(json: json)
    case "createProfile": createProfile.apply(json: json)
    case "calendarPreview", "meetingAlert": liveCard.apply(json: json)
    default: break
    }
  }

  private func send(_ event: DownloadsPageEvent) {
    let (name, id): (String, String?) =
      switch event {
      case .open(let id): ("open", id)
      case .reveal(let id): ("reveal", id)
      case .pause(let id): ("pause", id)
      case .resume(let id): ("resume", id)
      case .keep(let id): ("keep", id)
      case .cancel(let id): ("cancel", id)
      case .menu(let id): ("menu", id)
      case .remove(let id): ("remove", id)
      case .source(let id): ("source", id)
      case .clearAll: ("clearAll", nil)
      }
    onPageEvent(["kind": name, "id": id ?? NSNull()])
  }

  private func send(_ event: HistoryPageEvent) {
    switch event {
    case .open(let url, let mode): onPageEvent(["kind": "open", "url": url, "mode": mode.rawValue])
    case .remove(let urls): onPageEvent(["kind": "remove", "urls": urls])
    case .deleteSelected(let urls): onPageEvent(["kind": "deleteSelected", "urls": urls])
    case .clearData(let request): onPageEvent(["kind": "clearData", "range": request.range, "history": request.history, "siteData": request.siteData])
    }
  }

  private func send(_ event: BookmarksPageEvent) {
    switch event {
    case .open(let url, let mode): onPageEvent(["kind": "open", "url": url, "mode": mode.rawValue])
    case .openAll(let id, let newWindow): onPageEvent(["kind": "openAll", "id": id, "newWindow": newWindow])
    case .edit(let id): onPageEvent(["kind": "edit", "id": id])
    case .addGroup(let id): onPageEvent(["kind": "addGroup", "id": id])
    case .restoreArc(let id): onPageEvent(["kind": "restoreArc", "id": id])
    case .delete(let ids): onPageEvent(["kind": "delete", "ids": ids])
    case .undo: onPageEvent(["kind": "undo"])
    case .move(let ids, let drop, let listed):
      switch drop {
      case .into(let folder): onPageEvent(["kind": "move", "ids": ids, "into": folder, "listed": listed])
      case .at(let parentId, let index): onPageEvent(["kind": "move", "ids": ids, "parentId": parentId, "index": index, "listed": listed])
      }
    case .addBookmark(let parent): onPageEvent(["kind": "addBookmark", "parentId": parent ?? NSNull()])
    case .addFolder(let parent): onPageEvent(["kind": "addFolder", "parentId": parent ?? NSNull()])
    case .importBookmarks: onPageEvent(["kind": "import"])
    }
  }

  private func send(_ event: BookmarkFormEvent) {
    switch event {
    case .done(let name, let folderId): onPageEvent(["kind": "done", "name": name, "folderId": folderId ?? NSNull()])
    case .remove: onPageEvent(["kind": "remove"])
    case .cancel: onPageEvent(["kind": "cancel"])
    case .save(let name, let url, let parentId): onPageEvent(["kind": "save", "name": name, "url": url, "parentId": parentId ?? NSNull()])
    case .newFolder(let parentId): onPageEvent(["kind": "newFolder", "parentId": parentId ?? NSNull()])
    }
  }

  private func send(_ event: CreateProfileEvent) {
    switch event {
    case .create(let name, let color, let shareWith): onPageEvent(["kind": "create", "name": name, "color": color, "shareWith": shareWith ?? NSNull()])
    case .cancel: onPageEvent(["kind": "cancel"])
    }
  }

  private func send(_ event: LiveCardEvent) {
    switch event {
    case .height(let height): onPageEvent(["kind": "height", "height": height])
    case .activate: onPageEvent(["kind": "activate"])
    case .join(let id, let all): onPageEvent(["kind": "join", "id": id, "all": all])
    case .refresh: onPageEvent(["kind": "refresh"])
    case .connect: onPageEvent(["kind": "connect"])
    case .dismiss: onPageEvent(["kind": "dismiss"])
    case .view: onPageEvent(["kind": "view"])
    }
  }
}

private final class PagesEventSink: @unchecked Sendable {
  weak var module: PagesModule?
  init(_ module: PagesModule) { self.module = module }
}

#if SOLARA_PROBES
@MainActor
public extension PagesRead {
  static func snapshot() -> [[String: Any]] {
    guard let data = NativePageView.devState().data(using: .utf8),
      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pages = state["pages"] as? [[String: Any]] else { return [] }
    var result: [[String: Any]] = []
    for page in pages.prefix(16) {
      var row: [String: Any] = [:]
      for key in ["kind", "query", "shown", "selected", "clearOpen", "folder", "undo", "name", "url", "valid", "frames"] {
        if let value = page[key] { row[key] = value }
      }
      result.append(row)
    }
    return result
  }
}
#endif
