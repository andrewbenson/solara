import Foundation

public enum TranslationScript {
  public static let maximumPassages = 8
  public static let maximumCharacters = 2000

  private static let install = Bundle.module.url(forResource: "PageTranslator", withExtension: "js")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

  public static func sample(url: String) -> String? {
    guard let install else { return nil }
    return """
      (() => {
        if (document.readyState !== "complete" || location.href !== new URL(\(encoded(url))).href) return post("result", "null");
        const newDocument = \(encoded(UUID().uuidString));
        \(install)
        const translator = window[KEY];
        post("result", JSON.stringify({ ...translator.sample(), document: translator.document }));
      })();
      """
  }

  public static func call(_ operation: String, document: String, url: String? = nil, arguments: [Any]) -> String {
    let checkURL = url.map { " || location.href !== new URL(\(encoded($0))).href" } ?? ""
    return """
      (() => {
        const translator = window[Symbol.for("solara.translator")];
        if (!translator || translator.document !== \(encoded(document))\(checkURL)) return post("result", "null");
        post("result", JSON.stringify(translator[\(encoded(operation))](...\(encoded(arguments)))));
      })();
      """
  }

  private static func encoded(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
