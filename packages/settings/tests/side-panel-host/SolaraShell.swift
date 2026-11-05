import AppKit

@MainActor
public enum ShellDrag {
  public static func window(_ id: String) -> NSWindow? { nil }
}

public enum FocusMoves {
  public typealias PageFocus = @MainActor (@escaping @MainActor () -> Bool) -> Bool
}
