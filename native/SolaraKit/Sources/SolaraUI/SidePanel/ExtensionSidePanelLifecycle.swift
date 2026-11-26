import AppKit
import SolaraModel
import SolaraStore

@MainActor
public final class ExtensionSidePanelLifecycle {
  public enum URLSource {
    case unavailable(fallback: String?)
    case resolved(String?)
    case unsupported

    public init(engine: PageEngine?, browserId: Int32, fallback: String?, resolved: String?) {
      if engine == .webKit { self = .unsupported }
      else { self = browserId == 0 ? .unavailable(fallback: fallback) : .resolved(resolved) }
    }
  }

  public struct Presentation: Equatable {
    public let extensionId: String
    public let pageProfile: String
    public let url: String
    public let key: String

    public func room(width: Double) -> CGFloat { CGFloat(width) + ShellMetrics.cardInset - 1 }
  }

  public private(set) var extensionId: String?
  private var panel: Presentation?
  private var fullscreen = false

  public var presentation: Presentation? { fullscreen ? nil : panel }

  public init() {}

  public func request(_ id: String) {
    if extensionId != id { panel = nil }
    extensionId = id
  }

  public func reconcile(eligible: Bool, pageProfile: String, url: URLSource, fullscreen: Bool) -> Presentation? {
    guard let id = extensionId else { return nil }
    let resume = self.fullscreen && !fullscreen
    self.fullscreen = fullscreen
    let path: String?
    switch url {
    case .unavailable(let fallback):
      path = panel?.pageProfile == pageProfile ? panel?.url : fallback
    case .resolved(let resolved):
      path = resolved
    case .unsupported:
      path = nil
    }
    guard eligible, let path, let parsed = URLComponents(string: path),
      parsed.scheme == "chrome-extension", parsed.host == id else {
      clear()
      return nil
    }
    if resume || panel?.url != path || panel?.pageProfile != pageProfile {
      panel = Presentation(extensionId: id, pageProfile: pageProfile, url: path, key: UUID().uuidString)
    }
    return presentation
  }

  public func matchesRemoval(_ id: String, profile: String, catalogProfile: String) -> Bool {
    extensionId == id && profile == catalogProfile
  }

  public func accepts(key: String) -> Bool { presentation?.key == key }

  @discardableResult
  public func close(key: String) -> Bool {
    guard accepts(key: key) else { return false }
    clear()
    return true
  }

  private func clear() {
    extensionId = nil
    panel = nil
    fullscreen = false
  }

  public func saveWidth(_ width: Double?, key: String, windowId: String, store: Store) -> Bool {
    let value = width ?? Double(SidePanelMetrics.defaultWidth)
    guard accepts(key: key), value.isFinite else { return false }
    let saved = Double(SidePanelMetrics.clamp(CGFloat(value)))
    return (try? store.dispatch(Command("setWindowSidebar", [.string(windowId), ["sidePanelWidth": .number(saved)]]), origin: .native)) != nil
  }
}

@MainActor
public final class ExtensionSidePanelPageSlot<Page: AnyObject> {
  public var page: Page?

  public init() {}

  public func remove(_ release: (Page) -> Void) {
    guard let page else { return }
    self.page = nil
    release(page)
  }
}

@MainActor
public enum ExtensionSidePanelFocus {
  public static func holdsFocus(_ responder: NSResponder?, in page: NSView, beforeDetach: Bool = false) -> Bool {
    if beforeDetach { return true }
    guard let view = responder as? NSView else { return false }
    return view === page || view.isDescendant(of: page)
  }
}
