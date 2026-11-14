import AppKit
import SolaraUI

@MainActor
enum NativeSidebar {
  static func favicon(_ request: SidebarFaviconRequest) async throws -> NSImage? { nil }
}

@MainActor
enum SettingsAdapters {
  static func image(_ uri: String) -> NSImage? {
    guard let url = URL(string: uri), url.isFileURL else { return nil }
    return NSImage(contentsOf: url)
  }
}
