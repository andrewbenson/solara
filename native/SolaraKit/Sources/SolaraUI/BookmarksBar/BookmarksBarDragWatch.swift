import AppKit

@MainActor
final class BookmarksBarDragWatch {
  private var keyMonitor: Any?
  private var resignObservers: [NSObjectProtocol] = []

  init(view: BookmarksBarView, window: NSWindow) {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak window] event in
      guard let view, let window, event.window === window, event.keyCode == 53 else { return event }
      view.cancelOperation(nil)
      return nil
    }
    for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
      let observer = NotificationCenter.default.addObserver(forName: name, object: name == NSWindow.didResignKeyNotification ? window : nil, queue: .main) { [weak view] _ in
        MainActor.assumeIsolated { view?.cancelOperation(nil) }
      }
      resignObservers.append(observer)
    }
  }

  func stop() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    for observer in resignObservers { NotificationCenter.default.removeObserver(observer) }
    resignObservers = []
  }

  isolated deinit { stop() }
}
