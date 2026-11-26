import ExpoModulesCore

public class ChromeUIModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraChromeUI")
    Events("onDeviceChooser", "onCastDialog", "onCastRoutes", "onActionPopup", "onActionShortcut")

    OnCreate {
      SolaraCoreHost.chromeUIHandler = { [weak self] name, payload in
        SolaraCoreEventTaps.send(name, payload)
        switch name {
        case "actionPopup": self?.sendEvent("onActionPopup", payload)
        case "actionShortcut": self?.sendEvent("onActionShortcut", payload)
        case "deviceChooser": self?.sendEvent("onDeviceChooser", payload)
        case "castDialog": self?.sendEvent("onCastDialog", payload)
        case "castRoutes": self?.sendEvent("onCastRoutes", payload)
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

    AsyncFunction("showCastDialog") { (browserId: Int) in SolaraCoreHost.showCastDialog(browserId: Int32(browserId)) }.runOnQueue(.main)
    AsyncFunction("startCasting") { (id: Int, sink: String, mode: Int) in
      SolaraCoreHost.castDialog(Int32(id), start: sink, mode: Int32(mode))
    }.runOnQueue(.main)
    AsyncFunction("stopCasting") { (id: Int, route: String) in SolaraCoreHost.castDialog(Int32(id), stop: route) }.runOnQueue(.main)
    AsyncFunction("closeCastDialog") { (id: Int) in SolaraCoreHost.closeCastDialog(Int32(id)) }.runOnQueue(.main)
    AsyncFunction("watchCastRoutes") { (profile: String) in SolaraCoreHost.watchCastRoutes(profile) }.runOnQueue(.main)
    AsyncFunction("terminateCastRoute") { (route: String) in SolaraCoreHost.terminateCastRoute(route) }.runOnQueue(.main)

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
