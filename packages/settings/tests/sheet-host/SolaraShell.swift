import AppKit

@MainActor
public enum ShellDrag {
  public static var windows: [String: NSWindow] = [:]
  public static func window(_ id: String) -> NSWindow? { windows[id] }
}
