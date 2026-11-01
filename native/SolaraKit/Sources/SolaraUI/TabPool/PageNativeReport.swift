import SolaraModel
import SolaraOmnibox

public enum PageNativeReport {
  public static let names: Set<String> = ["onNavigationChange", "onMedia", "onDownloadNavigation", "onDiscarded", "onReady", "onLoadError"]

  public static func report(name: String, payload: JSONValue) -> JSONValue? {
    let type: String
    switch name {
    case "onNavigationChange": type = "navigation"
    case "onMedia": type = "media"
    case "onDownloadNavigation": type = "download"
    case "onDiscarded": type = "discarded"
    case "onReady": type = "ready"
    case "onLoadError": type = "loadError"
    default: return nil
    }
    guard var fields = payload.object else { return nil }
    fields["type"] = .string(type)
    fields["generation"] = nil
    fields["registrationGeneration"] = nil
    fields["sessionGeneration"] = nil
    for key in ["url", "committedUrl"] {
      if let url = fields[key]?.string { fields[key] = .string(toAppUrl(url)) }
    }
    return .object(fields)
  }
}
