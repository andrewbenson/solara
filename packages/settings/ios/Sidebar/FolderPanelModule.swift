import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class FolderPanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraFolderPanel")

    AsyncFunction("look") { (windowId: String, json: String) in
      FrameUpdates.readOnMain {
        guard let look = FolderPanelLook.decode(json) else { return }
        NativeTileFolders.setLook(windowId: windowId, look: look)
      }
    }.runOnQueue(.main)

    AsyncFunction("toggle") { (windowId: String, folderId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.toggle(windowId: windowId, folderId: folderId) }
    }.runOnQueue(.main)

    AsyncFunction("close") { (windowId: String?) -> Bool in
      FrameUpdates.readOnMain {
        guard NativeTileFolders.owned else { return false }
        if let windowId { NativeTileFolders.close(in: windowId) } else { NativeTileFolders.close() }
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("folderMenu") { (windowId: String, folderId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.folderMenu(windowId: windowId, folderId: folderId) }
    }.runOnQueue(.main)

    AsyncFunction("rename") { (windowId: String, folderId: String, title: String?) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.rename(windowId: windowId, folderId: folderId, title: title ?? "Rename Folder") }
    }.runOnQueue(.main)

    AsyncFunction("newFolderWithTab") { (windowId: String, tabId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.newFolderWithTab(windowId: windowId, tabId: tabId) }
    }.runOnQueue(.main)

    AsyncFunction("leaveFolder") { (tabId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.leaveFolder(tabId: tabId) }
    }.runOnQueue(.main)

    AsyncFunction("stripGroupMenu") { (windowId: String, groupId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.stripGroupMenu(windowId: windowId, groupId: groupId) }
    }.runOnQueue(.main)

    AsyncFunction("stripTileMenu") { (windowId: String, folderId: String) -> Bool in
      FrameUpdates.readOnMain { NativeTileFolders.stripTileMenu(windowId: windowId, folderId: folderId) }
    }.runOnQueue(.main)

    #if DEBUG
    AsyncFunction("devHandled") { () -> Int in
      FrameUpdates.readOnMain { NativeTileFolders.handled }
    }.runOnQueue(.main)
    #endif
  }
}

#if SOLARA_PROBES
@MainActor
public enum FolderPanelRead {
  public static func snapshot(windowId: String) -> [String: Any]? {
    guard let page = NativeSidebar.hosts[windowId]?.view.current,
      let panel = SidebarFolderPanelHost.panel(on: page), let window = panel.window else { return nil }
    let height = window.contentView?.bounds.height ?? 0
    func rect(_ view: NSView) -> [Double] {
      let frame = view.convert(view.bounds, to: nil)
      return [frame.minX, height - frame.maxY, frame.width, frame.height].map(Double.init)
    }
    var rows: [NSView] = []
    func collect(_ view: NSView) {
      if String(describing: type(of: view)).hasSuffix("FolderPanelRow"), !view.isHiddenOrHasHiddenAncestor { rows.append(view) }
      for child in view.subviews { collect(child) }
    }
    collect(panel)
    return ["folderId": panel.folderId, "visible": !panel.isHiddenOrHasHiddenAncestor,
      "rows": rows.sorted { rect($0)[1] < rect($1)[1] }.map(rect)]
  }
}
#endif
