import Foundation

public enum OmniboxFill {
  public static func text(for suggestion: Suggestion) -> String? {
    switch suggestion {
    case .page(let url, _, _, _, _, _):
      return addressWithoutWebScheme(url)
    case .search(let query, _, _, _, let bang):
      return bang ? nil : query
    case .calc, .action, .create, .extension:
      return nil
    }
  }

  public static func shown(selected: Int, home: Int, items: [Suggestion]) -> String? {
    guard selected != home, items.indices.contains(selected) else { return nil }
    return text(for: items[selected])
  }

  static func addressWithoutWebScheme(_ url: String) -> String {
    let lower = url.lowercased()
    guard let scheme = ["https://", "http://"].first(where: { lower.hasPrefix($0) }) else { return url }
    let rest = String(url.dropFirst(scheme.count))
    guard rest.hasSuffix("/"), let slash = rest.firstIndex(of: "/"), rest.index(after: slash) == rest.endIndex else { return rest }
    return String(rest[..<slash])
  }
}
