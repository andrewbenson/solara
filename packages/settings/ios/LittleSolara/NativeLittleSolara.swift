import AppKit
import SolaraShaders
import SolaraShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import Synchronization

@MainActor
enum NativeLittleSolara {
  private static var installed = false
  private static var hosts: [String: LittleSolaraHost] = [:]
  nonisolated private static let activeIds = Mutex<Set<String>>([])

  static func install() {
    guard !installed, let make = WindowHost.makeContentView else { return }
    installed = true
    WindowHost.makeContentView = { windowId in
      guard isSmallWindow(windowId) else { return make(windowId) }
      activeIds.withLock { _ = $0.insert(windowId) }
      let host = LittleSolaraHost(windowId: windowId, root: make(windowId))
      hosts[windowId] = host
      host.shell.onDetach = { [weak host] in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let host, host.shell.superview == nil, hosts[windowId] === host else { return }
            hosts[windowId] = nil
            host.stop()
            activeIds.withLock { _ = $0.remove(windowId) }
          }
        }
      }
      return host.shell
    }
  }

  static func isSmallWindow(_ windowId: String) -> Bool {
    NativeStoreHandle.store?.state.windows[windowId]?.kind == "small"
  }

  static func host(_ windowId: String) -> LittleSolaraHost? { hosts[windowId] }

  nonisolated static func active(_ windowId: String) -> Bool { activeIds.withLock { $0.contains(windowId) } }

  static func describe(_ windowId: String) -> [String: Any]? { host(windowId)?.describe() }

  static func barAction(_ action: SmallBarAction, windowId: String, bar: SmallBarView) {
    guard bar.window != nil, NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store,
      let tabId = bar.tabId,
      let command = SmallBarCommand.resolve(action, windowId: windowId, tabId: tabId, state: store.state, closing: store.memory.closingWindows)
    else { return }
    switch command {
    case .edit(let url):
      guard (try? store.dispatch(Command("openPanel", [.string(windowId), .string(url)]), origin: .native)) != nil else { return }
      NativeOmniboxView.hosts[windowId]?.view?.openNativePanel(text: url)
    case .menu:
      NativeOmniboxActions.urlMenu(tabId: tabId, windowId: windowId, in: bar)
    case .copy:
      guard let data = try? JSONEncoder().encode(["tabId": tabId]),
        NativeLinkCommands.perform("copyUrl", arg: String(decoding: data, as: UTF8.self), windowId: windowId) else { return }
      bar.showCopyConfirmation()
    case .expand:
      _ = NativeBrowserServiceCommands.perform("openFile", arg: nil, windowId: windowId)
    case .profile:
      NativeWorkspaceCommands.littleProfileMenu(windowId: windowId, store: store)
    }
  }
}

@MainActor
final class LittleSolaraHost {
  let shell: LittleSolaraShellView
  private weak var root: NSView?
  private var backdropJSON: String?
  private var observers: [NSObjectProtocol] = []
  private var contentSizer: NSObjectProtocol?
  private var untrack: (() -> Void)?

  init(windowId: String, root: NSView) {
    shell = LittleSolaraShellView(windowId: windowId)
    self.root = root
    shell.mount(.react, root)
    shell.bar.isHidden = true
    shell.bar.onAction = { [weak bar = shell.bar] action in
      if let bar { NativeLittleSolara.barAction(action, windowId: windowId, bar: bar) }
    }
    untrack = NativeMedia.track(NativeMedia.smallBar, windowId, shell.bar)
    let center = NotificationCenter.default
    let appeared = Notification.Name("RCTContentDidAppearNotification")
    observers.append(
      center.addObserver(forName: appeared, object: root, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.keepContentSized()
          center.post(name: appeared, object: self.shell)
        }
      })
    keepContentSized()
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    untrack?()
    untrack = nil
  }

  private func keepContentSized() {
    if let contentSizer { NotificationCenter.default.removeObserver(contentSizer) }
    contentSizer = nil
    guard let root, let content = root.subviews.first(where: { NSStringFromClass(type(of: $0)).hasSuffix("RootContentView") }) else { return }
    content.postsFrameChangedNotifications = true
    contentSizer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) {
      [weak root, weak content] _ in
      MainActor.assumeIsolated {
        guard let root, let content, content.superview === root, root.window != nil, !root.bounds.isEmpty, content.frame.size != root.bounds.size
        else { return }
        root.needsLayout = true
        content.needsLayout = true
      }
    }
  }

  func setBar(_ json: String) {
    guard let state = SmallBarState.decode(json) else { return }
    shell.bar.isHidden = false
    shell.bar.update(state)
  }

  func setBackdrop(_ json: String) {
    guard json != backdropJSON else { return }
    backdropJSON = json
    guard let data = json.data(using: .utf8), let props = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
      let view = EarlyBackdrop.make(props)
    else { return shell.mount(.backdrop, nil) }
    shell.mount(.backdrop, view)
  }

  private func blankBarHit() -> Any {
    guard let superview = shell.superview else { return NSNull() }
    let point = superview.convert(NSPoint(x: 60, y: SmallBarMetrics.height / 2), from: shell)
    return shell.hitTest(point).map { NSStringFromClass(type(of: $0)) } ?? NSNull()
  }

  func describe() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    return [
      "bounds": rect(shell.bounds),
      "bar": rect(shell.barFrame),
      "card": rect(shell.cardFrame),
      "barShown": !shell.bar.isHidden,
      "blankBarHit": blankBarHit(),
      "reactFill": (root?.value(forKey: "backgroundColor") as? NSColor).map { $0.description } ?? NSNull(),
      "slots": LittleSolaraShellView.Slot.allCases.compactMap { slot in shell.view(in: slot).map { [slot.rawValue, NSStringFromClass(type(of: $0))] } },
      "order": shell.subviews.map { NSStringFromClass(type(of: $0)) },
      "backdrop": backdropJSON ?? NSNull(),
    ]
  }
}
