import Foundation
import Testing
@testable import SolaraEngine

private final class WebKitResourceFixture {
  let url: String
  let path: String
  init(url: String, path: String = "") {
    self.url = url
    self.path = path
  }
}

@Suite struct WebKitSessionResourcesTests {
  @Test func completedAndCanceledDownloadRecordsAreForgottenWithoutRemovingSavedFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("saved")
    try Data([1, 2, 3]).write(to: file)
    var resources = WebKitSessionResources<WebKitDownloadPayload>()
    let scope = WebKitResourceGeneration(session: "shared", token: "first")
    let completed = WebKitDownloadPayload(url: "https://private.test/finished", profile: "incognito:one@shared")
    completed.path = file.path
    completed.final = file
    completed.filename = "saved"
    let canceled = WebKitDownloadPayload(url: "https://private.test/canceled", profile: "incognito:two@shared")
    canceled.request = URLRequest(url: URL(string: canceled.url)!)
    canceled.resumeData = Data([9])
    resources.insert(completed, id: "finished", generation: scope)
    resources.insert(canceled, id: "canceled", generation: scope)
    let ordinary = WebKitDownloadPayload(url: "https://ordinary.test", profile: "shared")
    resources.insert(ordinary, id: "ordinary", generation: nil)
    for record in resources.removePrivateSession(scope) { record.retire() }
    #expect(resources["finished"] == nil)
    #expect(resources["canceled"] == nil)
    #expect(resources["ordinary"] === ordinary)
    #expect(completed.url.isEmpty && completed.path.isEmpty && completed.filename.isEmpty)
    #expect(completed.final == nil)
    #expect(canceled.url.isEmpty && canceled.profile.isEmpty)
    #expect(canceled.request == nil && canceled.resumeData == nil)
    #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
  }

  @Test func retirementCancelsPendingDestinationOnceAndDropsItsCompletion() {
    let record = WebKitDownloadPayload(url: "https://private.test", profile: "incognito:one@shared")
    var completions: [URL?] = []
    record.destination = { completions.append($0) }
    record.retire()
    record.retire()
    #expect(completions.count == 1)
    #expect(completions[0] == nil)
    #expect(record.destination == nil)
  }

  @Test func sessionAndResourceIdsAreByteExact() {
    var resources = WebKitSessionResources<WebKitResourceFixture>()
    let composed = WebKitResourceGeneration(session: "é", token: "token")
    let decomposed = WebKitResourceGeneration(session: "e\u{301}", token: "token")
    resources.insert(WebKitResourceFixture(url: "first"), id: "é", generation: composed)
    resources.insert(WebKitResourceFixture(url: "second"), id: "e\u{301}", generation: decomposed)
    #expect(resources.removePrivateSession(composed).map(\.url) == ["first"])
    #expect(resources["é"] == nil)
    #expect(resources["e\u{301}"]?.url == "second")
  }

  @Test func retirementReleasesPrivateMetadata() {
    var resources = WebKitSessionResources<WebKitResourceFixture>()
    let generation = WebKitResourceGeneration(session: "shared", token: "token")
    weak var retained: WebKitResourceFixture?
    do {
      let record = WebKitResourceFixture(url: "https://private.test")
      retained = record
      resources.insert(record, id: "private", generation: generation)
    }
    #expect(retained != nil)
    _ = resources.removePrivateSession(generation)
    #expect(retained == nil)
  }
}

@Suite struct WebKitStoreGenerationsTests {
  @Test func capturedNativeGenerationStaysOldAcrossRetirementAndReopen() {
    var generations = WebKitStoreGenerations()
    generations.begin(session: "shared", generation: "old")
    let captured = generations.generation(session: "shared")
    generations.end(session: "shared")
    #expect(generations.generation(session: "shared") == nil)
    generations.begin(session: "shared", generation: "replacement")
    #expect(captured == "old")
    #expect(generations.generation(session: "shared") == "replacement")
    #expect(captured != generations.generation(session: "shared"))
  }

  @Test func generationScopesAreByteExactAndOwnershipLossDropsThem() {
    var generations = WebKitStoreGenerations()
    generations.begin(session: "é", generation: "first")
    generations.begin(session: "e\u{301}", generation: "second")
    generations.end(session: "é")
    #expect(generations.generation(session: "é") == nil)
    #expect(generations.generation(session: "e\u{301}") == "second")
    generations.removeAll()
    #expect(generations.generation(session: "e\u{301}") == nil)
  }
}
