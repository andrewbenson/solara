import AppKit

@MainActor
enum SettingsAdapters {
  static func image(_ uri: String?) -> NSImage? {
    uri == "fixture:valid" ? NSImage(size: NSSize(width: 16, height: 16)) : nil
  }
}
