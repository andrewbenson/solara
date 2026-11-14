import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedFrozenPage {
  static let kind = "frozenPage"
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  private struct State: Decodable {
    var token: Int
    var tabId: String?
    var copyId: String
    var uri: String?
    var dark: Bool
  }

  @MainActor
  private final class Entry {
    let windowId: String
    let view = FrozenPageView(frame: .zero)
    var state: State?
    var ended = false
    private var pictureCopyId: String?
    private var pictureURI: String?
    private var paintedToken: Int?

    init(windowId: String) {
      self.windowId = windowId
      view.onPress = { [weak self] in self?.send("press") }
      view.onPainted = { [weak self] in self?.painted() }
    }

    func update(_ json: String) {
      guard !ended else { return }
      guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(State.self, from: data), !next.copyId.isEmpty else {
        clear()
        return
      }
      state = next
      view.dark = next.dark
      view.isHidden = false
      if pictureCopyId != next.copyId || pictureURI != next.uri {
        pictureCopyId = next.copyId
        pictureURI = next.uri
        view.show(next.uri.flatMap(Self.image))
      }
      if view.image != nil { painted() }
    }

    func end() {
      ended = true
      clear()
      view.onPress = nil
      view.onPainted = nil
    }

    private func clear() {
      state = nil
      pictureCopyId = nil
      pictureURI = nil
      paintedToken = nil
      view.show(nil)
      view.isHidden = true
    }

    private func send(_ name: String) {
      guard !ended, let state else { return }
      HostedViews.send(kind, windowId: windowId, name, ["token": state.token, "copyId": state.copyId])
    }

    private func painted() {
      guard let state, view.image != nil, paintedToken != state.token else { return }
      paintedToken = state.token
      send("painted")
    }

    private static func image(_ uri: String) -> NSImage? {
      guard uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
        let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
      return NSImage(data: data)
    }
  }

  static func register() {
    HostedViews.register(kind) { windowId in
      #if DEBUG
        let id = UUID()
      #endif
      let entry = Entry(windowId: windowId)
      #if DEBUG
        entries[id] = entry
      #endif
      return HostedContent(
        view: entry.view,
        onUnmount: {
          entry.end()
          #if DEBUG
            entries[id] = nil
          #endif
        },
        takesFocus: false,
        onState: { json in entry.update(json) })
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [String: Any]? {
      let matches = entries.values.filter { $0.windowId == windowId }
      guard !matches.isEmpty else { return nil }
      var tabs: [String: [String: Any]] = [:]
      for entry in matches {
        guard let state = entry.state else { continue }
        let view = entry.view
        let frame = view.convert(view.bounds, to: nil)
        let height = view.window?.contentView?.bounds.height ?? 0
        tabs[state.tabId ?? state.copyId] = ["frozenPage": [
          "token": state.token, "copyId": state.copyId, "hasImage": view.image != nil, "dark": view.dark,
          "frame": [frame.minX, height - frame.maxY, frame.width, frame.height],
        ]]
      }
      return ["tabs": tabs]
    }
  #endif
}
