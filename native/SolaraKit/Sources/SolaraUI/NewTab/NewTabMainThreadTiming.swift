#if SOLARA_PROBES
import Foundation

@MainActor
public enum NewTabMainThreadTiming {
  public struct Span {
    public let phase: String
    public let windowId: String?
    public let tabId: String?
    public let startedMs: Double
    public let finishedMs: Double
  }

  public struct Start {
    let phase: String
    let windowId: String?
    let tabId: String?
    let startedMs: Double
  }

  private static let enabled = ProcessInfo.processInfo.environment["SOLARA_NEW_TAB_TIMING"] == "1"
  private static var spans: [Span] = []
  public private(set) static var dropped = 0

  public static func begin(_ phase: String, windowId: String? = nil, tabId: String? = nil) -> Start? {
    guard enabled else { return nil }
    return Start(phase: phase, windowId: windowId, tabId: tabId, startedMs: ProcessInfo.processInfo.systemUptime * 1000)
  }

  public static func end(_ start: Start?) {
    guard let start else { return }
    let finishedMs = ProcessInfo.processInfo.systemUptime * 1000
    guard spans.count < 4096 else { dropped += 1; return }
    spans.append(Span(phase: start.phase, windowId: start.windowId, tabId: start.tabId,
      startedMs: start.startedMs, finishedMs: finishedMs))
  }

  public static func read(reset: Bool = false) -> [Span] {
    let result = spans
    if reset { spans = []; dropped = 0 }
    return result
  }
}
#endif
