import ExpoModulesCore

public class ExtensionsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraExtensions")
    Events("onChanged")

    OnCreate {
      SolaraCoreServices.extensionsHandler = { [weak self] name, payload in
        if name == "changed" { self?.sendEvent("onChanged", payload) }
      }
    }

    AsyncFunction("list") { (profile: String, promise: Promise) in
      SolaraCoreServices.listExtensions(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("inspectUnpacked") { (path: String) in SolaraCoreServices.inspectUnpacked(path) }.runOnQueue(.main)
    AsyncFunction("install") { (path: String, profile: String, promise: Promise) in
      SolaraCoreServices.installExtension(path: path, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("installCrx") { (path: String, profile: String, promise: Promise) in
      SolaraCoreServices.installCrx(path: path, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("setEnabled") { (id: String, profile: String, enabled: Bool, promise: Promise) in
      SolaraCoreServices.setExtension(id, enabled: enabled, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("uninstall") { (id: String, profile: String, promise: Promise) in
      SolaraCoreServices.uninstallExtension(id, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("reload") { (id: String, profile: String, promise: Promise) in
      SolaraCoreServices.reloadExtension(id, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("configure") { (id: String, profile: String, options: [String: Any], promise: Promise) in
      SolaraCoreServices.configureExtension(id, profile: profile, options: options) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("searchEngineList") { (profile: String, promise: Promise) in
      SolaraCoreServices.searchEngineList(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("chooseFolder") { (promise: Promise) in
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Select"
      panel.message = "Choose an extension folder (with a manifest.json)"
      panel.begin { response in promise.resolve(response == .OK ? panel.url?.path : nil) }
    }.runOnQueue(.main)
  }
}
