import AppKit
import NaturalLanguage
import SwiftUI
@_weakLinked import Translation

@MainActor
public enum PageTranslationProvider {
  public enum Status { case installed, supported, unsupported }

  public static var available: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  public static func detect(_ text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else { return nil }
    return language.rawValue
  }

  public static func status(_ source: String, _ target: String) async -> Status {
    guard #available(macOS 26.0, *) else { return .unsupported }
    switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
    case .installed: return .installed
    case .supported: return .supported
    default: return .unsupported
    }
  }

  nonisolated public static func supportedLanguages() async -> [String] {
    guard #available(macOS 26.0, *) else { return [] }
    return await LanguageAvailability().supportedLanguages.map { $0.minimalIdentifier }
  }

  public static func prepare(_ source: String, _ target: String, in window: NSWindow?) async throws {
    guard #available(macOS 26.0, *) else { throw TranslateError.unavailable }
    guard let content = window?.contentView else { throw TranslateError.noWindow }
    do {
      try await DownloadPrompt().run(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target), in: content)
    } catch {
      throw TranslateError.explained(error)
    }
    let deadline = Date().addingTimeInterval(180)
    while await status(source, target) != .installed {
      guard Date() < deadline else { throw TranslateError.notDownloaded(Locale.current.localizedString(forLanguageCode: source) ?? source) }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  public static func translateBlocks(_ source: String, _ target: String, _ blocks: [[String]]) async -> [[String]?] {
    guard #available(macOS 26.4, *) else { return blocks.map { _ in nil } }
    return await TranslationSessions.translateBlocks(source: source, target: target, blocks)
  }

  public static func translate(_ source: String, _ target: String, _ texts: [String]) async throws -> [String?] {
    guard #available(macOS 26.0, *) else { throw TranslateError.unavailable }
    do {
      return try await TranslationSessions.translate(source: source, target: target, texts)
    } catch {
      throw TranslateError.explained(error)
    }
  }
}

extension PageTranslationProvider {
  static func linkedPieces(_ pieces: [String]) -> AttributedString {
    var text = AttributedString()
    for (i, piece) in pieces.enumerated() {
      var run = AttributedString(piece)
      run.link = URL(string: "ac-piece:\(i)")
      text += run
    }
    return text
  }

  static func isUnchanged(_ parts: [String], from pieces: [String]) -> Bool {
    parts.joined().filter { !$0.isWhitespace } == pieces.joined().filter { !$0.isWhitespace }
  }

  static func parts(of translated: AttributedString, over pieces: [String]) -> [String]? {
    guard !pieces.isEmpty else { return nil }
    var parts = Array(repeating: "", count: pieces.count)
    var order: [Int] = []
    var last = 0
    for run in translated.runs {
      let words = String(translated[run.range].characters)
      if let link = run.link, link.scheme == "ac-piece", let i = Int(link.absoluteString.dropFirst("ac-piece:".count)), parts.indices.contains(i) {
        order.append(i)
        last = i
        parts[i] += words
      } else {
        parts[last] += words
      }
    }
    guard !order.isEmpty else { return nil }
    if zip(order, order.dropFirst()).contains(where: { $0 > $1 }) {
      return distribute(String(translated.characters), over: pieces)
    }
    return parts
  }
}

@available(macOS 26.0, *)
@MainActor
enum TranslationSessions {
  private static var sessions: [String: TranslationSession] = [:]
  private static var lowLatencyPairs: Set<String> = []
  private static var tail: Task<Void, Never>?
  private static var uses = 0
  private static let idleSeconds = 60.0

  private struct PassageKey: Hashable {
    let source: String
    let target: String
    let pieces: [String]
  }

  private static var memo: [PassageKey: [String]] = [:]
  private static let memoLimit = 5000

  static func translations(source: String, target: String, standard: Bool = false, _ requests: [TranslationSession.Request]) async throws -> [TranslationSession.Response] {
    try await run(source: source, target: target, standard: standard) { try await $0.translations(from: requests) }
  }

  static func translate(source: String, target: String, _ texts: [String]) async throws -> [String?] {
    let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
    var out: [String?] = texts.map { _ in nil }
    for response in try await translations(source: source, target: target, requests) {
      if let i = response.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = response.targetText }
    }
    return out
  }

  @available(macOS 26.4, *)
  static func translateBlocks(source: String, target: String, _ blocks: [[String]]) async -> [[String]?] {
    let keys = blocks.map { PassageKey(source: source, target: target, pieces: $0) }
    var found: [PassageKey: [String]] = [:]
    var pending: [(key: PassageKey, pieces: [String])] = []
    var asked = Set<PassageKey>()
    for (key, pieces) in zip(keys, blocks) where asked.insert(key).inserted {
      if let known = memo[key] { found[key] = known } else { pending.append((key, pieces)) }
    }
    await translatePassages(source: source, target: target, standard: false, pending, into: &found)
    let unchanged = pending.filter { passage in
      guard let parts = found[passage.key] else { return true }
      return PageTranslationProvider.isUnchanged(parts, from: passage.pieces)
    }
    if !unchanged.isEmpty, lowLatencyPairs.contains(pairKey(source, target)),
      await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) == .installed
    {
      await translatePassages(source: source, target: target, standard: true, unchanged, into: &found)
    }
    for (key, pieces) in pending {
      if let parts = found[key], !PageTranslationProvider.isUnchanged(parts, from: pieces) { remember(key, parts) }
    }
    return keys.map { found[$0] }
  }

  @available(macOS 26.4, *)
  private static func translatePassages(source: String, target: String, standard: Bool, _ passages: [(key: PassageKey, pieces: [String])], into found: inout [PassageKey: [String]]) async {
    var answered = Set<PassageKey>()
    let single = passages.filter { $0.pieces.count == 1 }
    if !single.isEmpty {
      let requests = single.enumerated().map { TranslationSession.Request(sourceText: $0.element.pieces[0], clientIdentifier: String($0.offset)) }
      for response in (try? await translations(source: source, target: target, standard: standard, requests)) ?? [] {
        guard let i = response.clientIdentifier.flatMap(Int.init), single.indices.contains(i) else { continue }
        let parts = [response.targetText]
        if found[single[i].key] == nil || !PageTranslationProvider.isUnchanged(parts, from: single[i].pieces) { found[single[i].key] = parts }
        answered.insert(single[i].key)
      }
    }
    for (key, pieces) in passages where !answered.contains(key) {
      let text = PageTranslationProvider.linkedPieces(pieces)
      guard let translated = try? await run(source: source, target: target, standard: standard, { try await $0.translate(text).attributedTargetText }),
        let parts = PageTranslationProvider.parts(of: translated, over: pieces)
      else { continue }
      if found[key] == nil || !PageTranslationProvider.isUnchanged(parts, from: pieces) { found[key] = parts }
    }
  }

  private static func pairKey(_ source: String, _ target: String) -> String { "\(source)>\(target)" }

  private static func remember(_ key: PassageKey, _ parts: [String]) {
    if memo.count >= memoLimit { memo.removeAll() }
    memo[key] = parts
  }

  private static func run<T: Sendable>(source: String, target: String, standard: Bool = false, _ work: @escaping @MainActor (TranslationSession) async throws -> T) async throws -> T {
    let previous = tail
    let task = Task { @MainActor () async throws -> T in
      await previous?.value
      try Task.checkCancellation()
      let key = standard ? "\(pairKey(source, target))>standard" : pairKey(source, target)
      let session: TranslationSession
      if let cached = sessions[key] {
        session = cached
      } else {
        session = await make(source: source, target: target, standard: standard)
        sessions[key] = session
      }
      try Task.checkCancellation()
      do {
        return try await work(session)
      } catch {
        sessions[key] = nil
        throw error
      }
    }
    tail = Task { _ = try? await task.value }
    defer { forgetWhenIdle() }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func forgetWhenIdle() {
    uses += 1
    let use = uses
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(idleSeconds))
      if uses == use { sessions.removeAll() }
    }
  }

  private static func make(source: String, target: String, standard: Bool) async -> TranslationSession {
    let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
    if standard { return TranslationSession(installedSource: from, target: to) }
    if #available(macOS 26.4, *), await LanguageAvailability(preferredStrategy: .lowLatency).status(from: from, to: to) == .installed {
      lowLatencyPairs.insert(pairKey(source, target))
      return TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
    }
    lowLatencyPairs.remove(pairKey(source, target))
    return TranslationSession(installedSource: from, target: to)
  }
}

extension PageTranslationProvider {
  static func distribute(_ text: String, over pieces: [String]) -> [String] {
    let chars = Array(text)
    let total = max(1, pieces.reduce(0) { $0 + $1.count })
    var out: [String] = []
    var start = 0
    var seen = 0
    for (i, piece) in pieces.enumerated() {
      seen += piece.count
      var end = i == pieces.count - 1 ? chars.count : min(chars.count, Int((Double(seen) / Double(total) * Double(chars.count)).rounded()))
      if end < chars.count, end > start {
        let window = 12
        if let space = (0...window).lazy.flatMap({ [end + $0, end - $0] }).first(where: { $0 > start && $0 < chars.count && chars[$0] == " " }) {
          end = space + 1
        }
      }
      end = max(start, end)
      out.append(String(chars[start..<end]))
      start = end
    }
    return out
  }
}

enum TranslateError: LocalizedError {
  case unavailable, noWindow, notDownloaded(String), apple(String)
  var errorDescription: String? {
    switch self {
    case .unavailable: return "needs macOS 26"
    case .noWindow: return "no window to ask in"
    case .notDownloaded(let language): return "the \(language) language didn't finish downloading"
    case .apple(let reason): return reason
    }
  }

  static func explained(_ error: Error) -> Error {
    if error is TranslateError { return error }
    let described = error as? LocalizedError
    let title = (described?.errorDescription ?? error.localizedDescription).trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = (described?.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let code = (error as NSError).code
    if reason.isEmpty { return apple("\(title), code \(code)") }
    return apple("\(title): \(reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))), code \(code)")
  }
}

@available(macOS 26.0, *)
@MainActor
private final class DownloadPrompt {
  private weak var host: NSView?
  private var reply: CheckedContinuation<Void, Error>?

  func run(source: Locale.Language, target: Locale.Language, in content: NSView) async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        reply = continuation
        let view = DownloadPromptView(configuration: .init(source: source, target: target)) { [weak self] result in
          self?.finish(result)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        host = hosting
        content.addSubview(hosting)
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard let reply else { return }
    self.reply = nil
    host?.removeFromSuperview()
    reply.resume(with: result)
  }
}

@available(macOS 26.0, *)
private struct DownloadPromptView: View {
  let configuration: TranslationSession.Configuration
  let done: (Result<Void, Error>) -> Void
  var body: some View {
    Color.clear.translationTask(configuration) { session in
      do {
        try await session.prepareTranslation()
        done(.success(()))
      } catch {
        done(.failure(error))
      }
    }
  }
}
