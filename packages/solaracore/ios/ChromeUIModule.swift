import ExpoModulesCore

public class ChromeUIModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraChromeUI")
    Events("onDeviceChooser", "onActionPopup", "onActionShortcut")

    OnCreate {
      SolaraCoreHost.chromeUIHandler = { [weak self] name, payload in
        SolaraCoreEventTaps.send(name, payload)
        switch name {
        case "actionPopup": self?.sendEvent("onActionPopup", payload)
        case "actionShortcut": self?.sendEvent("onActionShortcut", payload)
        case "deviceChooser": self?.sendEvent("onDeviceChooser", payload)
        default: break
        }
      }
    }

    AsyncFunction("selectDevice") { (id: Int, index: Int) in SolaraCoreHost.deviceChooser(Int32(id), select: Int32(index)) }.runOnQueue(.main)
    AsyncFunction("cancelDeviceChooser") { (id: Int) in SolaraCoreHost.deviceChooser(Int32(id), action: "cancel") }.runOnQueue(.main)
    AsyncFunction("refreshDeviceChooser") { (id: Int) in SolaraCoreHost.deviceChooser(Int32(id), action: "refresh") }.runOnQueue(.main)
    AsyncFunction("openBluetoothSettings") { (id: Int) in SolaraCoreHost.deviceChooser(Int32(id), action: "settings") }.runOnQueue(.main)
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
    AsyncFunction("stopCapture") { (capturer: Int) in SolaraCoreHost.stopCapture(browserId: Int32(capturer)) }.runOnQueue(.main)
    AsyncFunction("showAutofillSuggestions") { (browserId: Int, passwords: Bool) in
      SolaraCoreHost.showAutofillSuggestions(browserId: Int32(browserId), passwords: passwords)
    }.runOnQueue(.main)
  }
}
