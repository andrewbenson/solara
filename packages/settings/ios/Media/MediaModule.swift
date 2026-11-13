import AppKit
import SolaraShell
import ExpoModulesCore
import SolaraUI

public class MediaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraMedia")

    OnCreate {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeMedia.register()
          NativeLittleSolara.install()
          NativePaneOverlays.start()
          NativeDownloadsPanel.start()
        }
      }
    }

    Function("cliIndicatorShown") { () -> Bool? in NativeMedia.cliShown }

    #if DEBUG
      AsyncFunction("devSetCliIndicator") { (shown: Bool) in
        MainActor.assumeIsolated {
          let product = Bundle.main.productName
          CliPillIndicator.shared.set(shown: shown, product: product, command: product.lowercased())
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

    AsyncFunction("describePaneOverlays") { (windowId: String) -> String in
      FrameUpdates.readOnMain { NativePaneOverlays.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("describeDownloadsPanel") { (windowId: String) -> String in
      FrameUpdates.readOnMain { NativeDownloadsPanel.describe(windowId) }
    }.runOnQueue(.main)

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
