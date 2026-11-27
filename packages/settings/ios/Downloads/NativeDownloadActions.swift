import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeDownloadActions {
  @MainActor
  private struct Target {
    let id: String
    let windowId: String
    let window: NSWindow
    let profileId: String
    let store: Store
    let generation: Int

    init?(id: String, windowId: String, window: NSWindow) {
      guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
        ShellDrag.window(windowId) === window, let profileId = store.state.windows[windowId]?.profileId,
        store.state.download(id, in: windowId) != nil else { return nil }
      self.id = id
      self.windowId = windowId
      self.window = window
      self.profileId = profileId
      self.store = store
      generation = NativeStoreHandle.ownershipGeneration
    }

    var download: Download? {
      guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
        NativeStoreHandle.ownershipGeneration == generation, ShellDrag.window(windowId) === window,
        !store.memory.closingWindows.contains(windowId), store.state.windows[windowId]?.profileId == profileId else { return nil }
      return store.state.download(id, in: windowId)
    }
  }

  private static var openWhenDone: Set<String> = []

  static func reset() { openWhenDone.removeAll() }

  static func downloadsChanged(_ state: BrowserState) {
    guard !openWhenDone.isEmpty else { return }
    var active: Set<String> = []
    for download in state.downloads where openWhenDone.contains(download.id) {
      if download.isDownloading { active.insert(download.id) }
      else if (!download.isPrivate || state.windows.values.contains { state.downloadVisible(download, in: $0) }),
        download.allows(.open, fileExists: fileExists(download)) { open(download.path) }
    }
    openWhenDone = active
  }

  static func perform(_ event: DownloadsEvent, windowId: String, profileId: String, in window: NSWindow, panel: Bool = false) {
    guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      ShellDrag.window(windowId) === window, store.state.windows[windowId]?.profileId == profileId,
      !store.memory.closingWindows.contains(windowId) else { return }
    switch event {
    case .clear:
      var commands = [Command("clearDownloads", [.string(windowId)])]
      if panel { commands.insert(Command("setDownloadsOpen", [.string(windowId), false]), at: 0) }
      store.sequence {
        guard store.state.windows[windowId]?.profileId == profileId else { return }
        _ = try? store.dispatch(commands, origin: .native)
      }
    case .viewAll:
      if panel { NativeDownloadsPanel.setOpen(windowId, false) }
      showPage(windowId)
    case .menu(let id):
      if let target = Target(id: id, windowId: windowId, window: window) { showMenu(target) }
    case .open(let id): perform(.open, id: id, windowId: windowId, window: window)
    case .reveal(let id): perform(.reveal, id: id, windowId: windowId, window: window)
    case .pause(let id): perform(.pause, id: id, windowId: windowId, window: window)
    case .resume(let id): perform(.resume, id: id, windowId: windowId, window: window)
    case .keep(let id): perform(.keep, id: id, windowId: windowId, window: window)
    case .cancel(let id): perform(.cancel, id: id, windowId: windowId, window: window)
    case .remove(let id): perform(.remove, id: id, windowId: windowId, window: window)
    case .source(let id): perform(.source, id: id, windowId: windowId, window: window)
    }
  }

  private static func perform(_ action: DownloadAction, id: String, windowId: String, window: NSWindow) {
    if let target = Target(id: id, windowId: windowId, window: window) { perform(action, target: target) }
  }

  private static func perform(_ action: DownloadAction, target: Target) {
    guard let download = target.download, download.allows(action, fileExists: fileExists(download)) else { return }
    switch action {
    case .open: open(download.path)
    case .reveal:
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1" {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.path)])
      }
    case .trash:
      do { try FileManager.default.trashItem(at: URL(fileURLWithPath: download.path), resultingItemURL: nil) }
      catch { return }
      remove(target)
    case .remove: remove(target)
    case .pause, .resume, .cancel, .keep:
      NativeDownloadEngine.command(action.rawValue, id: download.id)
    case .source, .retry:
      NativeBookmarkCommands.openURL(download.url, mode: "foreground", windowId: target.windowId)
    case .copy:
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(download.url, forType: .string)
    case .whenDone:
      if openWhenDone.remove(download.id) == nil { openWhenDone.insert(download.id) }
    }
  }

  private static func remove(_ target: Target) {
    _ = try? target.store.transact { session in
      guard session.state.windows[target.windowId]?.profileId == target.profileId,
        let download = session.state.download(target.id, in: target.windowId), download.allows(.remove) else { return }
      session.removeDownload(download.id)
    }
  }

  private static func fileExists(_ download: Download) -> Bool {
    download.state == "finished" && !download.path.isEmpty && FileManager.default.fileExists(atPath: download.path)
  }

  private static func open(_ path: String) {
    guard ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1" else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private static func showPage(_ windowId: String) {
    NativeWorkspaceCommands.perform("openLibraryPage", arg: #"{"page":"downloads"}"#, windowId: windowId)
  }

  private static func showMenu(_ target: Target) {
    guard let download = target.download else { return }
    let handler = MenuHandler()
    let menu = NSMenu()
    menu.autoenablesItems = false
    let exists = fileExists(download)
    func item(_ title: String, _ action: DownloadAction) {
      let row = handler.add(title, to: menu) { perform(action, target: target) }
      row.isEnabled = download.allows(action, fileExists: exists)
      if action == .whenDone { row.state = openWhenDone.contains(download.id) ? .on : .off }
    }
    if download.dangerous {
      item("Keep", .keep)
      item("Discard", .cancel)
    } else if download.isDownloading {
      item("Open When Done", .whenDone)
      item(download.paused ? "Resume" : "Pause", download.paused ? .resume : .pause)
      item("Cancel", .cancel)
    } else {
      item("Open", .open)
      item("Show in Finder", .reveal)
      if download.allows(.retry) { item("Retry", .retry) }
    }
    menu.addItem(.separator())
    item("Copy Download Link", .copy)
    handler.add("Show All Downloads", to: menu) {
      guard target.download != nil else { return }
      NativeDownloadsPanel.setOpen(target.windowId, false)
      showPage(target.windowId)
    }
    menu.addItem(.separator())
    if exists { item("Move to Trash", .trash) }
    item("Remove from List", .remove)
    guard let content = target.window.contentView else { return }
    let location = NSApp.currentEvent.flatMap { $0.window === target.window ? $0.locationInWindow : nil }
    let point = location.map { content.convert($0, from: nil) } ?? NSPoint(x: content.bounds.midX, y: content.bounds.midY)
    withExtendedLifetime(handler) {
      menu.popUp(positioning: nil, at: point, in: content)
    }
  }

  private final class MenuHandler: NSObject {
    private var actions: [() -> Void] = []

    @discardableResult
    func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
      item.tag = actions.count
      item.target = self
      actions.append(action)
      menu.addItem(item)
      return item
    }

    @objc private func choose(_ sender: NSMenuItem) { actions[sender.tag]() }
  }
}
