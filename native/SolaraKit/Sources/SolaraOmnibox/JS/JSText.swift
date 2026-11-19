public enum JSText {
  public static func trim(_ text: String) -> String { JS.trim(text) }
  public static func hasSpace(_ text: String) -> Bool { JS.hasSpace(text.units) }
  public static func isSpace(_ unit: UInt16) -> Bool { JS.isSpace(unit) }
}
