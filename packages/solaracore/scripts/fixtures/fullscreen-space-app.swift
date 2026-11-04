import AppKit

final class FullScreenSpaceApp: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var leave: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Solara full-screen Space fixture"
    window.collectionBehavior = [.fullScreenPrimary]
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
      print("fullscreen")
      fflush(stdout)
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
      print("windowed")
      fflush(stdout)
    }
    signal(SIGUSR1, SIG_IGN)
    leave = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    leave?.setEventHandler { [weak self] in
      guard let window = self?.window, window.styleMask.contains(.fullScreen) else { return }
      window.toggleFullScreen(nil)
    }
    leave?.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.window.toggleFullScreen(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }
  }
}

let app = NSApplication.shared
let delegate = FullScreenSpaceApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
