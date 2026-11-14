import AppKit
import Foundation
import SolaraUI

@MainActor
enum HostedFavicon {
  nonisolated static let kind = "favicon"
  private static let images = NSCache<NSString, NSImage>()
  #if DEBUG
    private static var entries: [UUID: Entry] = [:]
  #endif

  @MainActor
  private final class Entry {
    let windowId: String
    let view = FaviconView(frame: .zero)
    var ended = false
    var state: FaviconState?
    var image: NSImage?
    var task: Task<Void, Never>?

    init(windowId: String) { self.windowId = windowId }

    func update(_ json: String) {
      guard !ended else { return }
      let next = FaviconState.decode(json)
      let reload = next?.uri != state?.uri
      state = next
      if reload {
        task?.cancel()
        task = nil
        image = nil
      }
      view.update(next, image: image)
      guard reload, let uri = next?.uri, !uri.isEmpty else { return }
      if let cached = images.object(forKey: uri as NSString) {
        image = cached
        view.update(state, image: image)
        return
      }
      if let loaded = SettingsAdapters.image(uri) {
        images.setObject(loaded, forKey: uri as NSString)
        image = loaded
        view.update(state, image: image)
        return
      }
      task = Task { @MainActor [weak self] in
        let loaded: NSImage?
        if let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
          let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
          let data = try? await URLSession.shared.data(for: request).0
          loaded = data.flatMap(NSImage.init(data:))
        } else {
          loaded = nil
        }
        guard !Task.isCancelled, let self, !ended, state?.uri == uri else { return }
        image = loaded
        if let loaded { images.setObject(loaded, forKey: uri as NSString) }
        view.update(state, image: image)
        if loaded == nil, let state {
          HostedViews.send(kind, windowId: windowId, "error", ["token": state.token, "uri": uri])
        }
      }
    }

    func end() {
      ended = true
      task?.cancel()
      task = nil
      state = nil
      image = nil
      view.update(nil, image: nil)
    }
  }

  static func register() {
    images.countLimit = 2000
    HostedViews.register(kind) { windowId, json in
      let entry = Entry(windowId: windowId)
      #if DEBUG
        let id = UUID()
        entries[id] = entry
      #endif
      entry.update(json)
      return HostedContent(view: entry.view, onUnmount: {
        entry.end()
        #if DEBUG
          entries[id] = nil
        #endif
      }, takesFocus: false, onState: { entry.update($0) })
    }
  }

  #if DEBUG
    static func describe(_ windowId: String) -> [[String: Any]] {
      entries.values.filter { $0.windowId == windowId && !$0.ended }.map { entry in
        let view = entry.view
        let rect = view.convert(view.bounds, to: nil)
        let height = view.window?.contentView?.bounds.height ?? 0
        return ["token": entry.state?.token as Any? ?? NSNull(), "mode": entry.state?.mode as Any? ?? NSNull(),
          "url": entry.state?.url as Any? ?? NSNull(), "uri": entry.state?.uri as Any? ?? NSNull(), "hasImage": view.hasImage,
          "initial": entry.state?.initial as Any? ?? NSNull(), "dark": entry.state?.dark as Any? ?? NSNull(),
          "frame": [rect.minX, height - rect.maxY, rect.width, rect.height], "hidden": view.isHiddenOrHasHiddenAncestor]
      }
    }
  #endif
}
