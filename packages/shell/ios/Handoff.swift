import AppKit

public enum Handoff {
  private static var urls: [String: URL] = [:]

  public static func setActivity(windowId: String, url: String?, title: String?) {
    guard let window = WindowManager.shared.windows[windowId] else { return }
    guard let url = url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      urls[windowId] = nil
      window.userActivity?.invalidate()
      window.userActivity = nil
      return
    }
    if urls[windowId] == url, let activity = window.userActivity {
      activity.title = title
      return
    }
    urls[windowId] = url
    window.userActivity?.invalidate()
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = url
    activity.title = title
    activity.isEligibleForHandoff = true
    window.userActivity = activity
    if window.isKeyWindow { activity.becomeCurrent() }
  }

  public static func `continue`(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return false }
    OpenURLInbox.receiveFromOutside([url])
    return true
  }
}

enum SharePicker {
  private static var current: NSSharingServicePicker?
  private static let delegate = ShareDelegate()
  private static let background = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"

  static func show(url: String, title: String?, windowId: String?, anchor: [Double]?, done: @escaping () -> Void) {
    let window = windowId.flatMap { WindowManager.shared.windows[$0] } ?? NSApp.keyWindow
    guard let link = URL(string: url), let window, let view = window.contentView else { return done() }
    var rect = NSRect(x: view.bounds.midX - 1, y: view.isFlipped ? 40 : view.bounds.maxY - 42, width: 2, height: 2)
    var edge = NSRectEdge.minY
    if let a = anchor, a.count == 4 {
      rect = view.convert(NSRect(x: a[0], y: view.frame.height - a[1] - a[3], width: a[2], height: a[3]), from: nil)
      edge = rect.midX < view.bounds.midX ? .maxX : .minX
    }
    if background {
      log("share sheet (not shown): \(describe(url, title)) window=#\(window.windowNumber) anchor=\(NSStringFromRect(rect))"
        + " services=\(services().map(\.title).joined(separator: "|"))")
      return done()
    }
    delegate.finish()
    delegate.window = window
    delegate.done = done
    let item = NSPreviewRepresentingActivityItem(
      item: link as NSURL, title: title?.isEmpty == false ? title : link.host, image: nil, icon: nil)
    let picker = NSSharingServicePicker(items: [item])
    picker.delegate = delegate
    current = picker
    picker.show(relativeTo: rect, of: view, preferredEdge: edge)
  }

  static func show(_ content: ShareContent, imagePath: String?, view: NSView, at point: NSPoint) {
    guard let window = view.window else { return }
    var items: [Any] = []
    var described = ""
    switch content {
    case .text(let text):
      items = [text as NSString]
      described = "text=\"\(text)\""
    case .link(let url, let title), .media(let url, let title):
      items = [NSPreviewRepresentingActivityItem(item: url as NSURL, title: title?.isEmpty == false ? title : url.host, image: nil, icon: nil)]
      described = describe(url.absoluteString, title)
    case .image(let source, _):
      if let imagePath, let size = (try? FileManager.default.attributesOfItem(atPath: imagePath))?[.size] as? NSNumber {
        items = [URL(fileURLWithPath: imagePath) as NSURL]
        described = "image=\(imagePath) bytes=\(size.intValue)"
      } else if let source {
        items = [source as NSURL]
        described = "image-link=\(source.absoluteString)"
      }
    }
    guard !items.isEmpty else { return }
    let rect = NSRect(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y, width: 1, height: 1)
    if background {
      return log("share sheet (not shown): \(described) window=#\(window.windowNumber) anchor=\(NSStringFromRect(rect)) windowAnchor=\(NSStringFromRect(view.convert(rect, to: nil)))")
    }
    delegate.finish()
    delegate.window = window
    let picker = NSSharingServicePicker(items: items)
    picker.delegate = delegate
    current = picker
    picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
  }

  static func perform(service: String, url: String, title: String?, windowId: String?) {
    guard let link = URL(string: url), let match = services().first(where: { $0.title == service }) else { return }
    if background {
      return log("share via \(service) (not performed): \(describe(url, title))")
    }
    delegate.finish()
    delegate.window = windowId.flatMap { WindowManager.shared.windows[$0] } ?? NSApp.keyWindow
    match.delegate = delegate
    match.subject = title
    match.perform(withItems: [link])
  }

  static func services() -> [NSSharingService] {
    let probe: [Any] = [NSURL(string: "https://example.com")!]
    let listed = (NSSharingService.self as AnyObject).perform(NSSelectorFromString("sharingServicesForItems:"), with: probe)
    let all = listed?.takeUnretainedValue() as? [NSSharingService] ?? []
    let skipped = Set([NSSharingService.Name.composeEmail, .addToSafariReadingList].compactMap { NSSharingService(named: $0)?.title })
    return all.filter { !skipped.contains($0.title) }
  }

  static func menuItems(target: AnyObject, action: Selector, choice: (String) -> String) -> [NSMenuItem] {
    var items = services().map { service in
      let item = NSMenuItem(title: service.menuItemTitle, action: action, keyEquivalent: "")
      item.target = target
      item.image = service.image
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
      item.representedObject = choice(service.title)
      return item
    }
    let more = NSMenuItem(title: "More…", action: #selector(ShareMenu.openSharingSettings(_:)), keyEquivalent: "")
    more.target = ShareMenu.shared
    let picker = NSSharingServicePicker.self as AnyObject
    let image = NSSelectorFromString("sharedMoreMenuImage")
    if picker.responds(to: image) { more.image = picker.perform(image)?.takeUnretainedValue() as? NSImage }
    if more.image == nil { more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil) }
    if #available(macOS 27.0, *) { more.preferredImageVisibility = .visible }
    items.append(more)
    return items
  }

  private static func describe(_ url: String, _ title: String?) -> String {
    "url=\(url) title=\"\(title ?? "")\""
  }

  private static func log(_ line: String) {
    guard let dir = ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] else { return }
    let path = (dir as NSString).appendingPathComponent("activation.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(data)
      handle.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: data)
    }
  }
}

private final class ShareDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  weak var window: NSWindow?
  var done: (() -> Void)?

  func finish() {
    let done = done
    self.done = nil
    done?()
  }

  func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? {
    self
  }

  func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) { finish() }

  func sharingService(
    _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
  ) -> NSWindow? {
    window
  }
}

final class ShareMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
  static let shared = ShareMenu()

  func menuHasKeyEquivalent(
    _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
    action: UnsafeMutablePointer<Selector?>
  ) -> Bool {
    false
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    SharePicker.menuItems(target: self, action: #selector(share(_:)), choice: { "via:\($0)" }).forEach(menu.addItem)
  }

  @objc func share(_ sender: NSMenuItem) {
    MenuTarget.shared.handler?("share", sender.representedObject as? String, WindowManager.shared.keyWindowId)
  }

  @objc func openSharingSettings(_ sender: Any?) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services") {
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[handoff] background instance, not opening %@", url.absoluteString) }
      NSWorkspace.shared.open(url)
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    item.action == #selector(openSharingSettings(_:)) || !MenuState.current.disabled.contains("share")
  }
}
