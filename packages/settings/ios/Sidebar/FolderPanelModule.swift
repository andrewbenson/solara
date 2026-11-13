import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class FolderPanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraFolderPanel")

    Events("onFolderPanelEvent")

    AsyncFunction("show") { (windowId: String, json: String) in
      let sink = FolderPanelSink(self)
      FrameUpdates.readOnMain {
        guard let page = NativeSidebar.hosts[windowId]?.view.current, let data = json.data(using: .utf8),
          let request = try? JSONDecoder().decode(FolderPanelRequest.self, from: data)
        else { return }
        SidebarFolderPanelHost.show(on: page, windowId: windowId, request: request) { event in
          sink.module?.send(windowId: windowId, folderId: request.folderId, event)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("hide") { (windowId: String) in
      FrameUpdates.readOnMain {
        guard let page = NativeSidebar.hosts[windowId]?.view.current else { return }
        SidebarFolderPanelHost.hide(on: page)
      }
    }.runOnQueue(.main)
  }

  fileprivate func send(windowId: String, folderId: String, _ event: FolderPanelEvent) {
    var body: [String: Any] = ["windowId": windowId, "folderId": folderId]
    switch event {
    case .open(let tabId):
      body["kind"] = "open"
      body["tabId"] = tabId
    case .tabMenu(let tabId):
      body["kind"] = "tabMenu"
      body["tabId"] = tabId
    case .folderMenu: body["kind"] = "folderMenu"
    case .outsidePress: body["kind"] = "outsidePress"
    case .drag: return
    }
    sendEvent("onFolderPanelEvent", body)
  }
}

private final class FolderPanelSink: @unchecked Sendable {
  weak var module: FolderPanelModule?
  init(_ module: FolderPanelModule) { self.module = module }
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
