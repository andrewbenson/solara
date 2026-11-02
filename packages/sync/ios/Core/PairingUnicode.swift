import Foundation

enum PairingUnicode {
  enum Failure: Error {
    case name
  }

  static let newestRepertoire: Unicode.Version = (major: 15, minor: 0)

  static let refusedCategories: Set<Unicode.GeneralCategory> = [
    .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator,
  ]

  static func canonicalName(_ data: Data, normalizeLocal: Bool = false) throws -> String {
    guard data.count <= (normalizeLocal ? 1024 : 128),
      let original = String(data: data, encoding: .utf8), Data(original.utf8) == data else { throw Failure.name }
    let canonical = original.decomposedStringWithCanonicalMapping.precomposedStringWithCanonicalMapping
    guard normalizeLocal || Data(canonical.utf8) == data else { throw Failure.name }
    let scalars = canonical.unicodeScalars
    guard (1...128).contains(canonical.utf8.count), scalars.count <= 64,
      scalars.allSatisfy(isAllowed),
      let first = scalars.first, let last = scalars.last,
      !first.properties.isWhitespace, !last.properties.isWhitespace else { throw Failure.name }
    return canonical
  }

  static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
    guard let age = scalar.properties.age, age <= newestRepertoire else { return false }
    return !refusedCategories.contains(scalar.properties.generalCategory)
  }
}
