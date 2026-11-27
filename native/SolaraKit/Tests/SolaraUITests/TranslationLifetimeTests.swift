import Foundation
import JavaScriptCore
import Testing
@testable import SolaraUI

struct TranslationLifetimeTests {
  @Test func detectionRespectsPreferredLanguagesAndScripts() {
    #expect(TranslationLifetime.offer("de-DE", preferred: ["en-US"]) == "de-DE")
    #expect(TranslationLifetime.offer("en-GB", preferred: ["en-US"]) == nil)
    #expect(TranslationLifetime.offer("zh-TW", preferred: ["zh-Hans"]) == "zh-TW")
    #expect(TranslationLifetime.offer("zh_HK", preferred: ["zh-Hant"]) == nil)
  }

  @Test func sameURLReloadAndOwnerHandoffInvalidateReplies() {
    var life = TranslationLifetime()
    let first = life.replace(document: "first")
    #expect(life.accepts(first))
    let reload = life.replace(document: "reload")
    #expect(!life.accepts(first))
    #expect(life.accepts(reload))
    life.invalidate()
    #expect(!life.accepts(reload))
  }

  @Test func DOMCommandRequiresTheSampledDocument() throws {
    let context = try #require(JSContext())
    context.evaluateScript("""
      const window = this;
      let result;
      function post(_, response) { result = JSON.parse(response); }
      window[Symbol.for("solara.translator")] = { document: "replacement", apply: () => true };
      """)
    context.evaluateScript(TranslationScript.call("apply", document: "original", arguments: ["request", []]))
    #expect(context.evaluateScript("result").isNull)
    context.evaluateScript(TranslationScript.call("apply", document: "replacement", arguments: ["request", []]))
    #expect(context.evaluateScript("result").toBool())
  }

  @Test func revertAndFailedBatchCannotFinishOrCancelNewRequest() {
    var life = TranslationLifetime()
    _ = life.replace(document: "page")
    let first = life.begin(source: "de", target: "en")!
    #expect(life.phase == .translating)
    let cancelled = life.cancel(first)
    #expect(cancelled)
    let second = life.begin(source: "de", target: "fr")!
    let staleFinish = life.finish(first)
    #expect(!staleFinish)
    let staleCancel = life.cancel(first)
    #expect(!staleCancel)
    let finished = life.finish(second)
    #expect(finished)
    #expect(life.phase == .translated)
    life.invalidate()
    #expect(!life.accepts(second))
  }

  @Test @MainActor func failedBatchRetriesPiecesAndRetainsIDs() async throws {
    let passages = [[TranslationBatches.Piece(id: 2, text: "Guten Tag"),
      .init(id: 3, text: " "), .init(id: 5, text: "Auf Wiedersehen")]]
    let values = try await TranslationBatches.translate(passages, blocks: { _ in [nil] }, loose: { texts in
      if texts.count > 1 || texts == ["Auf Wiedersehen"] { throw Failure.provider }
      return ["Hello"]
    })
    #expect(values == [.init(id: 3, text: " "), .init(id: 2, text: "Hello"), .init(id: 5, text: nil)])
    await #expect(throws: Failure.provider) {
      _ = try await TranslationBatches.translate(passages, blocks: { _ in [nil] }, loose: { _ in throw Failure.provider })
    }
  }

  private enum Failure: Error { case provider }

  @Test func privateRulesReadOnlyFromOriginalProfileAndNormalizeSite() {
    #expect(TranslationLifetime.site("https://www.example.com:123/a") == "example.com")
    #expect(TranslationLifetime.site("file:///test") == nil)
    #expect(TranslationLifetime.ruleOwner(profile: "incognito:window@work", original: "work", privateWindow: true) == "work")
    #expect(TranslationLifetime.ruleOwner(profile: "home", original: nil, privateWindow: false) == "home")
    #expect(!TranslationLifetime.canChangeRule(privateWindow: true))
  }
}
