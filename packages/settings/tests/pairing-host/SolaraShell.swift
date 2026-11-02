import AppKit
@MainActor public enum WindowHost { public static var makeAuxController: ((String, String) -> NSViewController?)? }
@MainActor public enum ShellScripting {
  public static var nativeCommand: (([String: Any], @escaping (Any?, String?) -> Void) -> Bool)?
  public static var windows: [Int] = []
  public static var loadingTabs: [String] = []
}
