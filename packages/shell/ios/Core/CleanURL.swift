import Foundation

public enum CleanURL {
  struct SiteRule {
    let hosts: [String]
    let params: Set<String>
    let prefixes: [String]
  }

  static let globalParams: Set<String> = [
    "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "_ga", "_gl", "srsltid",
    "fbclid", "igshid", "msclkid", "twclid", "ttclid", "li_fat_id", "yclid", "ysclid", "rdt_cid", "epik", "mc_cid",
    "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "elqtrackid", "elqtrack",
    "vero_id", "vero_conv", "_kx", "__s", "oly_anon_id", "oly_enc_id", "_openstat", "wickedid", "rb_clickid",
    "s_cid", "irclickid", "cjevent", "sscid", "zanpid", "ranmid", "raneaid", "ransiteid", "trk_contact", "trk_msg",
    "trk_module", "trk_sid"
  ]

  static let globalPrefixes = ["utm_", "pk_", "mtm_", "piwik_", "matomo_", "hsa_", "stm_"]

  static let siteRules: [SiteRule] = [
    SiteRule(
      hosts: [
        "youtube.com", "youtu.be", "music.youtube.com"
      ],
      params: [
        "si", "pp", "feature"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "open.spotify.com"
      ],
      params: [
        "si", "nd", "context"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "instagram.com"
      ],
      params: [
        "igsh", "img_index"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "x.com", "twitter.com"
      ],
      params: [
        "s", "t", "ref_src", "ref_url"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "threads.net", "threads.com"
      ],
      params: [
        "xmt", "slof"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "tiktok.com"
      ],
      params: [
        "is_from_webapp", "sender_device", "sender_web_id", "_r", "_t"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "linkedin.com"
      ],
      params: [
        "trk", "trackingid", "lipi", "midtoken", "midsig", "trkemail", "eid"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "reddit.com"
      ],
      params: [
        "share_id", "ref_source", "ref_campaign"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "medium.com"
      ],
      params: [
        "source"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "facebook.com"
      ],
      params: [
        "mibextid", "sfnsn", "rdid", "share_url"
      ],
      prefixes: []),
    SiteRule(
      hosts: [
        "amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca",
        "amazon.co.jp", "amazon.in", "amazon.com.au"
      ],
      params: [
        "_encoding", "psc", "ref", "ref_", "tag", "linkcode", "linkid", "camp", "creative", "creativeasin",
        "content-id", "crid", "sprefix", "qid", "sr", "dib", "dib_tag"
      ],
      prefixes: ["pd_rd_", "pf_rd_"]),
  ]

  public static func clean(_ url: String) -> String {
    if url.contains(where: { "\n\r\u{2028}\u{2029}".contains($0) }) { return url }
    let hashStart = url.firstIndex(of: "#") ?? url.endIndex
    guard let queryStart = url[..<hashStart].firstIndex(of: "?") else { return url }
    guard let host = webHost(url) else { return url }
    let base = url[..<queryStart]
    let hash = url[hashStart...]
    let pairs = url[url.index(after: queryStart)..<hashStart].split(separator: "&", omittingEmptySubsequences: false)
    let rules = siteRules.filter { rule in rule.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    let kept = pairs.filter { pair in
      guard !pair.isEmpty else { return false }
      let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
      return !isTracking(decodedName(name), rules)
    }
    if kept.count == pairs.count { return url }
    return String(base) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + String(hash)
  }

  static func webHost(_ url: String) -> String? {
    let lower = url.lowercased()
    let scheme = lower.hasPrefix("https://") ? "https://" : lower.hasPrefix("http://") ? "http://" : nil
    guard let scheme else { return nil }
    let rest = url.dropFirst(scheme.count)
    let authority = rest.prefix { !"/?#\\".contains($0) }
    let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
    let host: Substring
    if hostAndPort.hasPrefix("["), let close = hostAndPort.firstIndex(of: "]") {
      host = hostAndPort[...close]
    } else {
      host = hostAndPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }
    guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else { return nil }
    return host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
  }

  static func decodedName(_ raw: String) -> String {
    (raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw).lowercased()
  }

  static func isTracking(_ name: String, _ rules: [SiteRule]) -> Bool {
    if globalParams.contains(name) || globalPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
    return rules.contains { rule in rule.params.contains(name) || rule.prefixes.contains { name.hasPrefix($0) } }
  }
}
