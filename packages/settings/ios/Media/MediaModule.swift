import AppKit
import SolaraCore
import SolaraShell
import ExpoModulesCore
import SolaraUI

public class MediaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraMedia")

    View(SmallWindowPageHost.self) {
      Prop("state") { (view: SmallWindowPageHost, json: String) in
        nonisolated(unsafe) let host = view
        MainActor.assumeIsolated { host.setState(json) }
      }
      Prop("windowId") { (view: SmallWindowPageHost, id: String) in
        nonisolated(unsafe) let host = view
        MainActor.assumeIsolated { host.windowId = id }
      }
    }

    OnCreate {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeMedia.register()
          NativeCast.start()
          NativeLittleSolara.install()
          NativePaneOverlays.start()
          NativeDownloadsPanel.start()
        }
      }
    }

    Function("cliIndicatorShown") { () -> Bool? in NativeMedia.cliShown }

    Function("protectionReason") { (tabId: String, pinned: Bool) -> String? in
      if PanePrompts.permissionPending(tabId) { return "answering a permission request" }
      return NowPlayingStore.shared.protectionReason(tabId: tabId, pinned: pinned)
    }

    #if DEBUG
      AsyncFunction("devSetCliIndicator") { (shown: Bool) in
        MainActor.assumeIsolated {
          let product = Bundle.main.productName
          CliPillIndicator.shared.set(shown: shown, product: product, command: product.lowercased())
        }
      }.runOnQueue(.main)
    #endif

    #if DEBUG
      AsyncFunction("devCastState") { () -> String in
        MainActor.assumeIsolated { SolaraCoreTestHooksAllowed() ? NativeCast.probe() : "{}" }
      }.runOnQueue(.main)

      AsyncFunction("devCastToggle") { (windowID: String, tabID: String) -> Bool in
        MainActor.assumeIsolated { SolaraCoreTestHooksAllowed() && NativeCast.toggle(windowID: windowID, tabID: tabID) }
      }.runOnQueue(.main)

      AsyncFunction("devCastFixture") { (tabID: String, json: String) -> Bool in
        MainActor.assumeIsolated { SolaraCoreTestHooksAllowed() && NativeCast.fixture(tabID: tabID, json: json) }
      }.runOnQueue(.main)

      AsyncFunction("devCastAction") { (windowID: String, tabID: String, dialogID: Int32, name: String, value: String) -> Bool in
        MainActor.assumeIsolated {
          SolaraCoreTestHooksAllowed() && NativeCast.devAction(windowID: windowID, tabID: tabID, dialogID: dialogID, name: name, value: value)
        }
      }.runOnQueue(.main)
    #endif

    Function("littleActive") { (windowId: String) -> Bool in
      NativeLittleSolara.active(windowId)
    }

    AsyncFunction("setLittleBar") { (windowId: String, json: String) in
      FrameUpdates.readOnMain { NativeLittleSolara.host(windowId)?.setBar(json) }
    }.runOnQueue(.main)

    AsyncFunction("setLittleBackdrop") { (windowId: String, json: String) in
      FrameUpdates.readOnMain { NativeLittleSolara.host(windowId)?.setBackdrop(json) }
    }.runOnQueue(.main)

    AsyncFunction("paneSwipe") { (windowId: String, tabId: String, json: String) in
      FrameUpdates.readOnMain { NativePaneOverlays.swipe(windowId, tabId, json) }
    }.runOnQueue(.main)

    #if DEBUG
      AsyncFunction("devPromptFixture") { (tabId: String, name: String, payload: [String: Any]) -> Bool in
      nonisolated(unsafe) let body = payload
      return MainActor.assumeIsolated {
        SolaraCoreTestHooksAllowed() && PanePrompts.devFixture(tabId, name: name, payload: body)
      }
    }.runOnQueue(.main)

    AsyncFunction("devPromptState") { (tabId: String) -> String in
      MainActor.assumeIsolated { SolaraCoreTestHooksAllowed() ? PanePrompts.devState(tabId) : "{}" }
    }.runOnQueue(.main)

    AsyncFunction("devPromptAnswer") { (tabId: String, kind: String, id: String, action: String, option: String) -> Bool in
      MainActor.assumeIsolated {
        SolaraCoreTestHooksAllowed() && PanePrompts.devAnswer(tabId, kind: kind, id: id, action: action, option: option)
      }
    }.runOnQueue(.main)

    AsyncFunction("describePaneOverlays") { (windowId: String) -> String in
        FrameUpdates.readOnMain { NativePaneOverlays.describe(windowId) }
      }.runOnQueue(.main)
    #endif

    #if DEBUG
      AsyncFunction("describeDownloadsPanel") { (windowId: String) -> String in
        FrameUpdates.readOnMain { NativeDownloadsPanel.describe(windowId) }
      }.runOnQueue(.main)
    #endif

    AsyncFunction("describeLittle") { (windowId: String) -> String in
      FrameUpdates.readOnMain {
        guard let info = NativeLittleSolara.describe(windowId), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)

    AsyncFunction("probe") { (kind: String, windowId: String) -> String in
      FrameUpdates.readOnMain { NativeMedia.probe(kind: kind, windowId: windowId) }
    }.runOnQueue(.main)
  }
}

@MainActor
final class SmallWindowPageHost: ExpoView {
  let card = SmallWindowCardView(frame: .zero)
  var windowId = "" { didSet { track() } }
  #if DEBUG
    private var tracking: UUID?
  #endif

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    addSubview(card)
    setAccessibilityElement(false)
  }

  override var isFlipped: Bool { true }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    card.hostContent(in: self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    track()
  }

  private func track() {
    #if DEBUG
      if let tracking { HostedSmallWindowCard.untrack(tracking) }
      tracking = nil
      if window != nil, !windowId.isEmpty { tracking = HostedSmallWindowCard.track(card, windowId: windowId, pageHost: self) }
    #endif
  }

  func setState(_ json: String) {
    card.update(SmallWindowCardState.decode(json))
    card.hostContent(in: self)
  }

  override func layout() {
    super.layout()
    card.hostContent(in: self)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    card.hostContent(in: self)
  }

  override func updateLayer() {
    super.updateLayer()
    card.hostContent(in: self)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point), hit !== self else { return nil }
    return hit
  }
}
