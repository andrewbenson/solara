import SolaraModel

public struct CommandShortcutSnapshot: Sendable {
  public let hints: [JSKey: String]

  public init(resolvedHints: [JSKey: String]) {
    hints = resolvedHints
  }

  public func hint(_ id: String) -> String? { hints[JSKey(id)] }
}
