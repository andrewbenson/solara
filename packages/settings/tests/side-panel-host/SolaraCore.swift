import AppKit

@objc public protocol SolaraCoreWebViewDelegate: NSObjectProtocol {
  func webView(_ web: SolaraCoreWebView, event name: String, payload: [String: Any])
}

@MainActor
public class SolaraCoreWebView: NSView {
  public weak var delegate: (any SolaraCoreWebViewDelegate)?
  public var profile: String = ""
  public var initialURL: String?
  public var transferKey: String?
  public var standalone = false
  public var extensionHost: String?
  public var pageBackgroundColor: NSColor?

  public func closeBrowser() {}
  public func focusPage() {}
}
