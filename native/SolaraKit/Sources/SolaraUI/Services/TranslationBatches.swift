import Foundation

public enum TranslationBatches {
  public struct Piece: Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
      self.id = id
      self.text = text
    }
  }

  public struct Result: Equatable {
    public let id: Int
    public let text: String?

    public init(id: Int, text: String?) {
      self.id = id
      self.text = text
    }
  }

  @MainActor
  public static func translate(_ passages: [[Piece]], blocks: ([[String]]) async -> [[String]?],
    loose: ([String]) async throws -> [String?]) async throws -> [Result] {
    let whole = await blocks(passages.map { $0.map(\.text) })
    try Task.checkCancellation()
    var translated: [Result] = []
    var fallback: [Piece] = []
    for (index, pieces) in passages.enumerated() {
      if whole.indices.contains(index), let parts = whole[index], parts.count == pieces.count {
        translated += zip(pieces, parts).map { Result(id: $0.id, text: $1) }
      } else {
        fallback += pieces
      }
    }
    let asked = fallback.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    translated += fallback.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { Result(id: $0.id, text: $0.text) }
    guard !asked.isEmpty else { return translated }
    do {
      let results = try await loose(asked.map(\.text))
      try Task.checkCancellation()
      translated += asked.enumerated().map { index, piece in
        Result(id: piece.id, text: results.indices.contains(index) ? results[index] : nil)
      }
    } catch {
      try Task.checkCancellation()
      guard asked.count > 1 else { throw error }
      var failures = 0
      for piece in asked {
        try Task.checkCancellation()
        do {
          let value = try await loose([piece.text]).first ?? nil
          translated.append(Result(id: piece.id, text: value))
        } catch {
          failures += 1
          translated.append(Result(id: piece.id, text: nil))
        }
      }
      try Task.checkCancellation()
      if failures == asked.count { throw error }
    }
    return translated
  }
}
