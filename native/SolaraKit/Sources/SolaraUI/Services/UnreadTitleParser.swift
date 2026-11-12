import Foundation

public enum UnreadTitleParser {
  private static let number = #"([1-9][0-9]{0,8}|[1-9][0-9]{0,2}(?:,[0-9]{3}){1,2})"#
  private static let patterns = [
    #"^\("# + number + #"\)\s+\S.*$"#,
    #"^\["# + number + #"\](?:\s+\S.*)?$"#,
    #"^\S.*\s+\("# + number + #"\)$"#,
    #"^\S.*\s+\["# + number + #"\]$"#,
    #"^Inbox\s+\("# + number + #"\)(?:\s+[-–—|]\s+.+)$"#,
    #"^"# + number + #"\s+(?:new(?:\s+(?:messages?|notifications?|emails?|chats?))?|unread(?:\s+(?:messages?|notifications?|emails?|chats?))?)(?:\s+[-–—|:]\s+.+)?$"#,
  ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

  public static func count(in title: String) -> Int? {
    guard title.utf16.count <= 4096 else { return nil }
    let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(text.startIndex..., in: text)
    for pattern in patterns {
      guard let match = pattern.firstMatch(in: text, range: range), let capture = Range(match.range(at: 1), in: text),
        let count = Int(text[capture].replacingOccurrences(of: ",", with: "")), count > 0,
        !(1900...2099).contains(count)
      else { continue }
      return count
    }
    return nil
  }
}
