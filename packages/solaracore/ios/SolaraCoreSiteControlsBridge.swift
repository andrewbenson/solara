import Foundation

@MainActor
public enum SolaraCoreSiteControlsBridge {
  public static func webKitBlockerStatus(host: String) -> [String: Any] {
    WebKitHub.shared.contentBlocker.status(host: host)
  }

  public static func webKitSettings(profile: String, origin: String) -> [String: [String: Any]] {
    WebKitHub.shared.sitePermissions(profile: profile, origin: origin)
  }

  public static func setWebKitPermission(profile: String, origin: String, kind: String, value: String) {
    WebKitHub.shared.setSitePermission(profile: profile, origin: origin, kind: kind, value: value)
  }
}

@MainActor
public enum SolaraCorePromptAnswers {
  public static func installEventTap() {
    WebKitHub.shared.permissionEvents = { name, payload in SolaraCoreEventTaps.send(name, payload) }
    SolaraCoreHost.deviceChooserHandler = { payload in SolaraCoreEventTaps.send("deviceChooser", payload) }
  }

  public static func externalApp(_ id: String, open: Bool, remember: Bool) {
    if id.hasPrefix("wk-external-") { WebKitHub.shared.resolveExternalApp(id, open: open, remember: remember) }
    else { SolaraCoreHost.resolveExternalApp(id, open: open, remember: remember) }
  }

  public static func permission(_ id: String, result: String, remember: Bool) {
    if id.hasPrefix("wk-permission-") { WebKitHub.shared.resolvePermission(id, result: result, remember: remember) }
    else { SolaraCoreHost.resolvePermission(id, result: result, remember: remember) }
  }
}
