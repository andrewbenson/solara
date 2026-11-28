import Foundation
import Testing
@testable import SolaraLive

actor PausedRetiredSecrets: LiveSecretStore {
  var deletionStarted = false
  var entered: CheckedContinuation<Void, Never>?
  var release: CheckedContinuation<Void, Never>?

  func secret(account: String) async -> String? { nil }
  nonisolated func setSecret(_ secret: String, account: String) -> Bool { true }

  func deleteSecret(account: String) async -> Bool {
    deletionStarted = true
    entered?.resume()
    entered = nil
    await withCheckedContinuation { release = $0 }
    return true
  }

  func waitForDeletion() async {
    if deletionStarted { return }
    await withCheckedContinuation { entered = $0 }
  }

  func resumeDeletion() {
    release?.resume()
    release = nil
  }
}

@Suite struct RetiredSourcesTests {
  static let retiredFolders = ["confluence-only", "bitbucket-only", "jira-only"]
  static let retainedFolders = ["mixed", "github", "empty"]
  static let folderMaps = ["folders", "items", "known", "unread", "hidden", "completed", "completing", "status"]

  static func document() throws -> [String: Any] {
    var seed = LiveState()
    for id in retiredFolders + retainedFolders {
      seed.createFolder(id: id, profileId: "p", kind: .documents, sources: id == "github" ? [.github] : id == "empty" ? [] : [.notion], now: 5)
      let item = LiveItem(id: id + ":kept", source: id == "github" ? .github : .notion, url: "https://example.com/" + id, title: id, subtitle: "kept", updatedAt: 6)
      seed.items[id] = [item]
      seed.known[id] = [item.id]
      seed.unread[id] = [item.id]
      seed.hidden[id] = [item]
      seed.completed[id] = [CompletedItem(item: item, state: .reviewed, at: 7)]
    }
    seed.config.githubClientId = "github-client"
    seed.config.googleClientId = "google-client"
    seed.config.extra = ["futureConfig": .object(["value": .array([.bool(true), .null])])]
    seed.extra = ["futureSection": .object(["version": .number(3)])]
    seed.accounts = [.github: LiveAccount(login: "gh", name: nil, avatar: nil, connectedAt: 1), .notion: LiveAccount(login: "nt", name: nil, avatar: nil, connectedAt: 2), .gdrive: LiveAccount(login: "gd", name: nil, avatar: nil, connectedAt: 3)]
    var raw = try #require(JSONSerialization.jsonObject(with: LiveJSON.encode(seed)) as? [String: Any])
    var folders = raw["folders"] as! [String: [String: Any]]
    folders["confluence-only"]?["sources"] = ["confluence"]
    folders["bitbucket-only"]?["sources"] = ["bitbucket"]
    folders["jira-only"]?["sources"] = ["jira"]
    folders["mixed"]?["sources"] = ["notion", "confluence"]
    raw["folders"] = folders
    for key in ["items", "hidden", "completed"] {
      var lists = raw[key] as! [String: [[String: Any]]]
      for id in retiredFolders + retainedFolders {
        for source in ["bitbucket", "confluence", "jira"] {
          var item = (raw["items"] as! [String: [[String: Any]]])[id]![0]
          item["source"] = source
          item["id"] = source + ":removed"
          lists[id, default: []].append(key == "completed" ? ["item": item, "state": "closed", "at": 8] : item)
        }
      }
      raw[key] = lists
    }
    var accounts = raw["accounts"] as! [String: Any]
    accounts["bitbucket"] = ["login": "bb", "connectedAt": 4]
    accounts["confluence"] = ["login": "cf", "connectedAt": 5]
    accounts["jira"] = ["login": "jr", "connectedAt": 6]
    accounts["futureSource"] = ["unknown": true]
    raw["accounts"] = accounts
    var config = raw["config"] as! [String: Any]
    config["bitbucketUser"] = "user"
    config["confluenceSite"] = "site"
    config["confluenceEmail"] = "email"
    raw["config"] = config
    raw["completing"] = Dictionary(uniqueKeysWithValues: (retiredFolders + retainedFolders).map { ($0, ["running"]) })
    raw["status"] = Dictionary(uniqueKeysWithValues: (retiredFolders + retainedFolders).map { ($0, ["state": "idle"]) })
    return raw
  }

  static func expected(_ input: [String: Any]) -> [String: Any] {
    var raw = input
    for key in folderMaps {
      if var map = raw[key] as? [String: Any] {
        for id in retiredFolders { map[id] = nil }
        raw[key] = map
      }
    }
    raw["folderOrder"] = (raw["folderOrder"] as! [String]).filter { !retiredFolders.contains($0) }
    var folders = raw["folders"] as! [String: [String: Any]]
    folders["mixed"]?["sources"] = ["notion"]
    raw["folders"] = folders
    for key in ["items", "hidden", "completed"] {
      var lists = raw[key] as! [String: [[String: Any]]]
      for (id, list) in lists {
        lists[id] = list.filter { entry in
          let item = key == "completed" ? entry["item"] as! [String: Any] : entry
          return !["bitbucket", "confluence", "jira"].contains(item["source"] as? String ?? "")
        }
      }
      raw[key] = lists
    }
    var accounts = raw["accounts"] as! [String: Any]
    accounts["bitbucket"] = nil
    accounts["confluence"] = nil
    accounts["jira"] = nil
    raw["accounts"] = accounts
    var config = raw["config"] as! [String: Any]
    for key in ["bitbucketUser", "confluenceSite", "confluenceEmail"] { config[key] = nil }
    raw["config"] = config
    raw["completing"] = nil
    raw["status"] = nil
    return raw
  }

  @Test func retiredDataIsScrubbedBeforePersistenceAndInitialReplica() throws {
    let raw = try Self.document()
    let text = canonical(raw)
    let state = try LiveJSON.decode(LiveState.self, from: text)
    #expect(state.folderOrder == Self.retainedFolders)
    #expect(Set(state.folders.keys) == Set(Self.retainedFolders))
    #expect(state.folders["mixed"]?.sources == [.notion])
    #expect(state.folders["empty"]?.sources == [])
    for id in Self.retiredFolders {
      #expect(state.items[id] == nil)
      #expect(state.known[id] == nil)
      #expect(state.unread[id] == nil)
      #expect(state.hidden[id] == nil)
      #expect(state.completed[id] == nil)
      #expect(state.completing[id] == nil)
      #expect(state.status[id] == nil)
    }
    for id in Self.retainedFolders {
      #expect(state.items[id]?.map(\.id) == [id + ":kept"])
      #expect(state.hidden[id]?.map(\.id) == [id + ":kept"])
      #expect(state.completed[id]?.map(\.item.id) == [id + ":kept"])
      #expect(state.known[id] == [id + ":kept"])
      #expect(state.unread[id] == [id + ":kept"])
    }
    #expect(Set(state.accounts.keys) == [.github, .notion, .gdrive])
    #expect(state.config.githubClientId == "github-client")
    #expect(state.config.googleClientId == "google-client")
    #expect(state.config.extra.keys.sorted() == ["futureConfig"])
    #expect(state.extra["futureSection"] == .object(["version": .number(3)]))
    let saved = try #require(JSONSerialization.jsonObject(with: Data(try state.persistedJSON().utf8)) as? [String: Any])
    #expect(canonical(saved) == canonical(Self.expected(raw)))
    let clean = try LiveJSON.decode(LiveState.self, from: state.persistedJSON())
    #expect(try clean.persistedJSON() == state.persistedJSON())
  }

  @Test func supportedFoldersRoundTripWithoutSchedulingASave() async throws {
    var seed = LiveState()
    seed.createFolder(id: "github", profileId: "p", kind: .pullRequests, sources: [.github], now: 1)
    seed.createFolder(id: "notion", profileId: "p", kind: .documents, sources: [.notion], now: 2)
    seed.items["github"] = [stubPR("github:item", 1, "head", "main")]
    seed.items["notion"] = [LiveItem(id: "notion:item", source: .notion, url: "https://notion.so/page", title: "Page", subtitle: "", updatedAt: 3)]
    let original = try seed.persistedJSON()
    let decoded = try LiveJSON.decode(LiveState.self, from: original)
    #expect(try decoded.persistedJSON() == original)
    let rig = Rig(documents: [LiveState.documentName: original])
    rig.secrets.values.with { $0 = ["github": "gh", "notion": "nt", "gdrive": "gd", "bitbucket": "bb", "confluence": "cf", "jira": "jr"] }
    let before = rig.secrets.values.current
    await rig.engine.start(jobs: [])
    await rig.clock.advance(by: LiveEngine.saveDebounceMs * 2)
    #expect(rig.secrets.values.current == before)
    #expect(rig.secrets.deletions.current.isEmpty)
    #expect(rig.documents.writes.current == 0)
    await rig.engine.update { $0.markRead("absent") }
    await rig.clock.advance(by: LiveEngine.saveDebounceMs * 2)
    #expect(rig.documents.writes.current == 0)
    await rig.engine.stop()
  }

  @Test(arguments: [false, true]) func startupDeletesOnlyRetiredCredentialsAndSavesOnce(mock: Bool) async throws {
    let raw = try Self.document()
    let rig = Rig(documents: [LiveState.documentName: canonical(raw)], environment: LiveEnvironment(mockBase: mock ? "http://mock" : nil))
    let prefix = mock ? "mock:" : ""
    let secrets = Dictionary(uniqueKeysWithValues: ["github", "notion", "gdrive", "bitbucket", "confluence", "jira"].map { (prefix + $0, $0 + "-secret") })
    rig.secrets.values.with { $0 = secrets }
    await rig.engine.start(jobs: [])
    await rig.clock.advance(by: LiveEngine.saveDebounceMs)
    #expect(Set(rig.secrets.deletions.current) == [prefix + "bitbucket", prefix + "confluence", prefix + "jira"])
    #expect(rig.secrets.values.current == secrets.filter { ![prefix + "bitbucket", prefix + "confluence", prefix + "jira"].contains($0.key) })
    #expect(await rig.engine.state.accounts[.github]?.login == "gh")
    #expect(await rig.engine.state.accounts[.notion]?.login == "nt")
    #expect(await rig.engine.documentError == nil)
    #expect(rig.documents.writes.current == 1)
    let saved = try #require(rig.documents.read(LiveState.documentName))
    let savedRaw = try #require(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
    #expect(canonical(savedRaw) == canonical(Self.expected(raw)))
    await rig.engine.stop()
    let second = Rig(documents: [LiveState.documentName: saved], environment: LiveEnvironment(mockBase: mock ? "http://mock" : nil))
    second.secrets.values.with { $0 = secrets }
    await second.engine.start(jobs: [])
    await second.clock.advance(by: LiveEngine.saveDebounceMs * 2)
    #expect(second.secrets.deletions.current.isEmpty)
    #expect(second.documents.writes.current == 0)
    #expect(second.secrets.values.current == secrets)
    await second.engine.stop()
  }

  @Test func folderOnlyRetirementSavesWithoutDeletingSecrets() async throws {
    var raw = try Self.document()
    raw["accounts"] = [:] as [String: Any]
    raw["config"] = ["githubClientId": "gh", "googleClientId": "gd"]
    let rig = Rig(documents: [LiveState.documentName: canonical(raw)])
    await rig.engine.start(jobs: [])
    await rig.clock.advance(by: LiveEngine.saveDebounceMs)
    #expect(rig.secrets.deletions.current.isEmpty)
    #expect(rig.documents.writes.current == 1)
    await rig.engine.stop()
  }

  @Test func suspendedRetirementCannotRestartJobsAfterStop() async throws {
    var seed = LiveState()
    seed.createFolder(id: "kept", profileId: "p", kind: .documents, sources: [], now: 1)
    var raw = try #require(JSONSerialization.jsonObject(with: LiveJSON.encode(seed)) as? [String: Any])
    raw["config"] = ["bitbucketUser": "old"]
    let rig = Rig()
    let secrets = PausedRetiredSecrets()
    var effects = rig.engine.effects
    effects.secrets = secrets
    let engine = LiveEngine(effects: effects, state: try LiveJSON.decode(LiveState.self, from: canonical(raw)))
    let first = Task { await engine.start(jobs: [.folders]) }
    await secrets.waitForDeletion()
    await engine.stop()
    await engine.start(jobs: [])
    await secrets.resumeDeletion()
    await first.value
    await rig.clock.advance(by: LiveEngine.firstRefreshDelayMs)
    #expect(await engine.state.status["kept"] == nil)
    await engine.stop()
  }

  @Test(arguments: ["item", "account", "config"], [false, true])
  func isolatedRetirementSavesAndIgnoresCredentialDeletionFailures(shape: String, rejectsDeletion: Bool) async throws {
    let text: String
    let expectedDeletions: Set<String>
    switch shape {
    case "item":
      text = #"{"items":{"loose":[{"source":"bitbucket"}]}}"#
      expectedDeletions = []
    case "account":
      text = #"{"accounts":{"bitbucket":null}}"#
      expectedDeletions = ["bitbucket"]
    default:
      text = #"{"config":{"confluenceSite":null,"confluenceEmail":17}}"#
      expectedDeletions = ["confluence"]
    }
    let rig = Rig(documents: [LiveState.documentName: text])
    rig.secrets.allowWrite.with { $0 = !rejectsDeletion }
    await rig.engine.start(jobs: [])
    await rig.clock.advance(by: LiveEngine.saveDebounceMs)
    #expect(Set(rig.secrets.deletions.current) == expectedDeletions)
    #expect(rig.documents.writes.current == 1)
    #expect(await rig.engine.documentError == nil)
    #expect(await rig.engine.state.status.isEmpty)
    let saved = try #require(rig.documents.read(LiveState.documentName))
    #expect(!saved.contains("bitbucket"))
    #expect(!saved.contains("confluence"))
    await rig.engine.stop()
  }

  @Test func malformedShapesAndUnknownSourcesStayUntouched() throws {
    let text = #"{"folders":{"future":{"id":"future","profileId":"p","kind":"documents","name":"Future","sources":["confluence","future"]},"broken":17},"items":{"broken":"confluence"},"hidden":{"broken":[17,{"source":false}]},"completed":{"broken":[{"item":null}]},"accounts":[],"config":false}"#
    let state = try LiveJSON.decode(LiveState.self, from: text)
    #expect(state.folders["future"] != nil)
    let raw = try #require(JSONSerialization.jsonObject(with: Data(try state.persistedJSON().utf8)) as? [String: Any])
    let folders = raw["folders"] as? [String: Any]
    #expect((folders?["future"] as? [String: Any])?["sources"] as? [String] == ["future"])
    #expect(folders?["broken"] as? Int == 17)
    #expect((raw["items"] as? [String: Any])?["broken"] as? String == "confluence")
    #expect(raw["accounts"] as? [String] == [])
    #expect(raw["config"] as? Bool == false)
    #expect(canonical(raw["hidden"]!) == #"{"broken":[17,{"source":false}]}"#)
    #expect(canonical(raw["completed"]!) == #"{"broken":[{"item":null}]}"#)
  }
}
