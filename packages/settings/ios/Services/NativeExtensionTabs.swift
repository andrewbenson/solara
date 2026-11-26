import AppKit
import SolaraCore
import SolaraModel
import SolaraShell
import SolaraStore
import SolaraUI

@MainActor
enum NativeExtensionTabs {
  private static var requests = ExtensionTabsRequest()

  static func install() {
    SolaraCoreServices.extensionTabsHandler = { payload in
      MainActor.assumeIsolated {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let request = try? JSONValue.parse(data) else { return }
        let action = request["action"]?.string
        let recovery = action == "closeCancelled" ? request["chromeWindow"]?.string : nil
        guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else {
          if let recovery { ACChromeWindowHost.rejectCancelledChromeWindow(recovery) }
          return
        }
        if action == "windowCloseStarted" || action == "windowCloseCommitted" {
          guard WindowHost.publishesWindowTeardown else { return }
          do {
            try requests.apply(request, to: store)
          } catch {
            NSLog("[extensions] Chrome window close failed: %@", String(describing: error))
          }
          return
        }
        let generation = NativeStoreHandle.ownershipGeneration
        DispatchQueue.main.async {
          guard NativeStoreHandle.ownsWorkspace, NativeStoreHandle.store === store,
            NativeStoreHandle.ownershipGeneration == generation else {
            if let recovery { ACChromeWindowHost.rejectCancelledChromeWindow(recovery) }
            return
          }
          do {
            let (before, after, restored) = try store.sequence {
              let before = store.state
              let restored = try requests.apply(request, to: store)
              return (before, store.state, restored)
            }
            if let recovery, restored == nil { ACChromeWindowHost.rejectCancelledChromeWindow(recovery) }
            if before.windows != after.windows { NativeWorkspaceCommands.materializeChanges(before: before, after: after) }
            if before != after { FrameUpdates.flush() }
          } catch {
            if let recovery { ACChromeWindowHost.rejectCancelledChromeWindow(recovery) }
            NSLog("[extensions] Chrome window request failed: %@", String(describing: error))
          }
        }
      }
    }
  }
}
