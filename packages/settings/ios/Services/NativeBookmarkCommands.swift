import AppKit
import SolaraEngine
import SolaraShell
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeBookmarkCommands {
  #if DEBUG
  static var cancelConfirmation = false
  static var confirmations: [[String: String]] = []
  #endif
  private struct ToggleKey: Hashable {
    let profile: String
    let url: String
  }

  private static var toggling: Set<ToggleKey> = []

  static func toggle(_ tab: Tab, profile: String, windowId: String, store: Store) {
    let key = ToggleKey(profile: profile, url: tab.url)
    guard !tab.url.isEmpty, toggling.insert(key).inserted else { return }
    let owner = NativeBookmarkOwner.writableCurrent
    let generation = NativeStoreHandle.ownershipGeneration
    let mutation = BookmarkMutation(method: "toggleBookmark", args: [.string(profile), [
      "url": .string(tab.url), "title": .string(tab.title), "favicon": tab.favicon.map(JSONValue.string) ?? .null,
    ]])
    Task { @MainActor in
      defer { toggling.remove(key) }
      do {
        guard NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation else { return }
        guard let owner else { throw BookmarkWriterError.notOwned }
        guard NativeBookmarkOwner.writableCurrent === owner else { return }
        let binding = try owner.binding(profile: profile)
        _ = try await owner.submitAsync(profile: profile, mutations: [mutation], binding: binding, requestID: nil)
      } catch BookmarkWriterError.expired {
      } catch {
        guard NativeStoreHandle.store === store, NativeStoreHandle.ownershipGeneration == generation else { return }
        NSLog("[toolbar] bookmark toggle failed: %@", String(describing: error))
        if let host = WindowHost.contentView(windowId) {
          let title: String
          if case .savedUnconfirmed? = error as? BookmarkPendingStoreError { title = "Bookmark save unconfirmed" }
          else { title = "Bookmark not saved" }
          LinkToast.show(in: host, title: title)
        }
      }
    }
  }

  private static func plan(_ command: String, arg: String?, windowId: String?, store: Store) -> BookmarkOpenPlan? {
    let state = store.state
    let route = CommandRoute.resolve("openBookmark", windowId: windowId, state: state, closing: store.memory.closingWindows)
    let profile = state.bookmarkProfileId(route.windowId.flatMap { state.windows[$0] })
    let snapshot = try? NativeBookmarkOwner.displayCurrent?.snapshot(profile: profile)
    return BookmarkMenuCommand.plan(command: command, arg: arg, windowId: windowId, state: state,
      closing: store.memory.closingWindows, snapshot: snapshot)
  }

  static func openURL(_ url: String, mode: String, windowId: String) {
    let options: JSONValue = ["url": .string(url), "mode": .string(mode)]
    guard let data = try? JSONSerialization.data(withJSONObject: options.foundation) else { return }
    _ = perform("openBookmarkItems", arg: String(decoding: data, as: UTF8.self), windowId: windowId)
  }

  static func perform(_ command: String, arg: String?, windowId: String?) -> Bool {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else { return true }
    guard let wanted = plan(command, arg: arg, windowId: windowId, store: store) else { return true }
    let ownership = NativeStoreHandle.ownershipGeneration
    let owner = NativeBookmarkOwner.displayCurrent
    let finish: @MainActor @Sendable () -> Void = {
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == ownership,
        NativeBookmarkOwner.displayCurrent === owner,
        plan(command, arg: arg, windowId: windowId, store: store) == wanted else { return }
      let before = store.state
      do {
        var target = wanted.window?.id ?? ""
        var after: String?
        if wanted.window == nil || wanted.mode == "window" || wanted.mode == "incognito" {
          let options: JSONValue = ["url": .string(wanted.urls[0]), "profileId": .string(wanted.profile),
            "incognito": .bool(wanted.mode == "incognito" || wanted.window?.incognito == true)]
          guard let created = try store.dispatch(Command("createWindow", [options]), origin: .native).result?.string else { return }
          target = created
          after = store.state.activeTabId(target)
        }
        for (index, url) in wanted.urls.enumerated() {
          if index == 0, target != wanted.window?.id { continue }
          if wanted.mode == "current", let tab = wanted.tab {
            try store.dispatch(Command("navigate", [.string(tab.id), .string(url)]), origin: .native)
          } else if wanted.mode == "split" {
            let result = try store.dispatch(Command("openSplitPane", [.string(target), ["url": .string(url)]]), origin: .native)
            if result.result?["ok"]?.truthy == true { continue }
            try store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
          } else {
            var options: JSONObject = ["url": .string(url), "background": .bool(index > 0 || wanted.mode == "background")]
            if wanted.mode == "background", let tab = wanted.tab { options["openerId"] = .string(tab.id) }
            if let after, let position = store.state.windows[target]?.tabIds.firstIndex(of: after) {
              options["index"] = .number(Double(position + 1))
            }
            after = try store.dispatch(Command("newTab", [.string(target), .object(options)]), origin: .native).result?.string
          }
        }
        NativeWorkspaceCommands.materializeChanges(before: before, after: store.state)
        FrameUpdates.flush()
      } catch { NSLog("[commands] open bookmark failed: %@", String(describing: error)) }
    }
    if wanted.urls.count > 15 {
      #if DEBUG
      confirmations.append(["title": "Open \(wanted.urls.count) tabs?", "message": "This folder has a lot of bookmarks.", "confirmTitle": "Open All", "windowId": wanted.window?.id ?? ""])
      if cancelConfirmation { return true }
      #endif
      let alert = NSAlert()
      alert.messageText = "Open \(wanted.urls.count) tabs?"
      alert.informativeText = "This folder has a lot of bookmarks."
      alert.addButton(withTitle: "Open All")
      alert.addButton(withTitle: "Cancel")
      NativeWorkspaceCommands.askGuarded(alert, windowId: wanted.window?.id ?? "", setting: nil, store: store, then: finish)
    } else { finish() }
    return true
  }
}
