import Foundation

public enum PinnedLinkPolicy {
  private struct Rules {
    var exact: Set<String> = []
    var wildcard: Set<String> = []
    var exception: Set<String> = []
  }

  private static let rules: Rules = {
    var rules = Rules()
    for rule in (pslTlds + "\n" + pinnedLinkSiteRules).split(whereSeparator: \.isWhitespace) {
      let name = rule.hasPrefix("!") ? rule.dropFirst() : rule.hasPrefix("*.") ? rule.dropFirst(2) : rule
      guard let host = URL(string: "https://\(name)")?.host(percentEncoded: false)?.lowercased() else { continue }
      if rule.hasPrefix("!") { rules.exception.insert(host) }
      else if rule.hasPrefix("*.") { rules.wildcard.insert(host) }
      else { rules.exact.insert(host) }
    }
    return rules
  }()

  private static func httpURL(_ raw: String) -> URL? {
    let lower = raw.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
      !raw.utf8.contains(where: { $0 <= 32 || $0 == 127 }),
      raw.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
      let url = URL(string: raw), let host = url.host(percentEncoded: false), !host.isEmpty,
      url.user == nil, url.password == nil else { return nil }
    return url
  }

  private static func hostName(_ url: URL) -> String {
    let host = (url.host(percentEncoded: false) ?? "").lowercased()
    return host.hasSuffix(".") ? String(host.dropLast()) : host
  }

  public static func registrableDomain(_ raw: String) -> String? {
    guard let url = httpURL(raw) else { return nil }
    let host = hostName(url)
    if !host.contains(".") { return rules.exact.contains(host) ? nil : host }
    if host.hasPrefix("[") || host.hasSuffix(".localhost") || host.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil { return host }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.contains(where: \.isEmpty) else { return nil }
    var suffixLength = 1
    for index in labels.indices {
      let suffix = labels[index...].joined(separator: ".")
      if rules.exception.contains(suffix) { return suffix }
      if rules.exact.contains(suffix) { suffixLength = max(suffixLength, labels.count - index) }
      if index > 0, rules.wildcard.contains(suffix) { suffixLength = max(suffixLength, labels.count - index + 1) }
    }
    return labels.count > suffixLength ? labels.suffix(suffixLength + 1).joined(separator: ".") : nil
  }

  private static func redirectParameters(_ url: URL) -> Set<String>? {
    let host = hostName(url)
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    if ["google.com", "www.google.com"].contains(host), path == "/url" { return ["q", "url"] }
    if host == "slack-redir.net", path == "/link" { return ["url"] }
    if host.hasSuffix(".safelinks.protection.outlook.com"), path == "/" || path.isEmpty { return ["url"] }
    if ["facebook.com", "www.facebook.com", "l.facebook.com", "lm.facebook.com", "m.facebook.com"].contains(host), path == "/l.php" { return ["u"] }
    if ["linkedin.com", "www.linkedin.com"].contains(host), ["/redir/redirect", "/safety/go"].contains(path) { return ["url"] }
    return nil
  }

  public static func unwrapRedirects(_ raw: String) -> String? {
    var current = raw
    var seen: Set<URL> = []
    for _ in 0..<8 {
      guard let url = httpURL(current), seen.insert(url).inserted else { return nil }
      guard let parameters = redirectParameters(url) else { return current }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
      components?.percentEncodedQuery = query
      let targets = components?.queryItems?.compactMap { item -> String? in
        guard parameters.contains(item.name), let value = item.value, !value.isEmpty else { return nil }
        return value
      } ?? []
      guard targets.count == 1 else { return nil }
      current = targets[0]
    }
    return nil
  }

  public static func crossesSites(from source: String, to target: String) -> Bool {
    guard let from = registrableDomain(source), let to = registrableDomain(unwrapRedirects(target) ?? target) else { return false }
    return from != to
  }
}
