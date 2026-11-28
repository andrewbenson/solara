import ExpoModulesCore

public class ChromeUIModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraChromeUI")
    Events("onActionPopup", "onActionShortcut")

    OnCreate {
      SolaraCoreHost.chromeUIHandler = { [weak self] name, payload in
        SolaraCoreEventTaps.send(name, payload)
        switch name {
        case "actionPopup": self?.sendEvent("onActionPopup", payload)
        case "actionShortcut": self?.sendEvent("onActionShortcut", payload)
        default: break
        }
      }
    }

    #if DEBUG
    AsyncFunction("devSelectDevice") { (id: Int, option: Int) in
      SolaraCoreHost.deviceChooser(Int32(id), select: Int32(option))
    }.runOnQueue(.main)
    #endif
    AsyncFunction("devShowBluetoothChooser") { (browserId: Int, unauthorized: Bool) -> Bool in
      SolaraCoreHost.devShowBluetoothChooser(browserId: Int32(browserId), unauthorized: unauthorized)
    }.runOnQueue(.main)
    AsyncFunction("devChooserEvents") { SolaraCoreHost.testChooserEvents() }.runOnQueue(.main)

    AsyncFunction("actionStates") { (browserId: Int, ids: [String]) in
      SolaraCoreHost.actionStates(browserId: Int32(browserId), extensions: ids)
    }.runOnQueue(.main)
    AsyncFunction("sidePanelURL") { (browserId: Int, extensionId: String) -> String? in
      SolaraCoreHost.sidePanelURL(browserId: Int32(browserId), extension: extensionId)
    }.runOnQueue(.main)

    AsyncFunction("changeCaptureSource") { (capturer: Int, target: Int) -> Bool in
      SolaraCoreHost.shareTabInstead(capturer: Int32(capturer), target: Int32(target))
    }.runOnQueue(.main)
#if DEBUG
    AsyncFunction("displayCaptureState") { (capturer: Int) in
      SolaraCoreHost.displayCaptureState(browserId: Int32(capturer))
    }.runOnQueue(.main)
#endif
    AsyncFunction("stopCapture") { (capturer: Int) in SolaraCoreHost.stopCapture(browserId: Int32(capturer)) }.runOnQueue(.main)
    AsyncFunction("showAutofillSuggestions") { (browserId: Int, passwords: Bool) in
      SolaraCoreHost.showAutofillSuggestions(browserId: Int32(browserId), passwords: passwords)
    }.runOnQueue(.main)
  }
}
