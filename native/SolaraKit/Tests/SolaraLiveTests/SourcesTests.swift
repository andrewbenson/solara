import Foundation
import Testing

@testable import SolaraLive

@Suite struct SourcesTests {
  let mock = MockServer()

  func connected() async -> Rig {
    let rig = Rig(mock: mock)
    rig.secrets.setSecret("mock-token", account: "mock:github")
    await rig.engine.setAccount(.github, LiveAccount(login: "octo-dev", name: nil, avatar: nil, connectedAt: 0))
    return rig
  }

  @Test func aGithubFolderFetchesTheSearchThenDetailsInPagesOfTen() async {
    let rig = await connected()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    let fixture = Fixture.decode(GithubResponse.self, "github.json")
    let expected = LiveEngine.order(GitHub.mapGithub(fixture, filters: LiveFilters()))
    #expect(await rig.engine.state.items[id] == expected)
    #expect(await rig.engine.state.status[id] == FolderStatus(state: .idle, lastFetch: rig.clock.now(), error: nil))
    let detailCalls = rig.http.log.current.filter { ($0.bodyText ?? "").contains("LiveFolderDetails") }
    #expect(detailCalls.count == (GitHub.detailIds(fixture, filters: LiveFilters()).count + 9) / 10)
  }

  @Test func aDetailsPageThatFailsOnceIsRetriedAndAFieldErrorEmptiesOnlyThatField() async {
    let rig = await connected()
    let fixture = Fixture.decode(GithubResponse.self, "github.json")
    let target = GitHub.detailIds(fixture, filters: LiveFilters())[1]
    mock.model.with { $0.detailsError = (target, "FIELD") }
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    let item = await rig.engine.state.items[id]!.first { $0.id == "github:\(target)" }
    #expect(item?.pr?.checks == [])
    mock.model.with { $0.detailsError = (target, "PAGE") }
    let other = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(other).value
    #expect(await rig.engine.state.status[other]?.error?.kind == .other)
    let pageCalls = rig.http.log.current.filter { ($0.bodyText ?? "").contains("LiveFolderDetails") && ($0.bodyText ?? "").contains(target) }
    #expect(pageCalls.count == 3)
  }

  @Test func aMergedPullRequestPlaysItsCompletionThenLeavesAndAReviewedOneSaysSo() async {
    let rig = await connected()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    mock.merge("PR_101")
    mock.drop("PR_88")
    await rig.engine.refreshFolder(id).value
    let state = await rig.engine.state
    #expect(state.completing[id]?.sorted() == ["github:PR_101", "github:PR_88"].sorted())
    #expect(state.items[id]!.contains { $0.id == "github:PR_101" }, "it stays in place while its merge plays")
    #expect(Set(state.completed[id]!.map { "\($0.item.id)=\($0.state.rawValue)" }) == ["github:PR_101=merged", "github:PR_88=reviewed"])
    await rig.clock.advance(by: LiveEngine.completionMs - 1)
    #expect(await rig.engine.state.items[id]!.contains { $0.id == "github:PR_101" })
    await rig.clock.advance(by: 1)
    #expect(await !rig.engine.state.items[id]!.contains { $0.id == "github:PR_101" })
    #expect(await rig.engine.state.completing[id] == [])
  }

  @Test func aSignedOutTokenReadsAsSignBackIn() async {
    let rig = Rig(mock: mock)
    rig.secrets.setSecret("stale", account: "mock:github")
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.status[id]?.error == FolderError(kind: .signedOut, message: "Signed out", source: .github))
    #expect(await rig.engine.statusText(id) == "Sign back in to GitHub")
    let fresh = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [.notion])
    await rig.engine.refreshFolder(fresh).value
    #expect(await rig.engine.statusText(fresh) == "Connect Notion in Settings")
  }

  @Test func documentSourcesFetchThroughTheirConnectedAccounts() async throws {
    let rig = Rig(mock: mock)
    let engine = rig.engine
    try await engine.connectNotion(token: " mock-notion ")
    #expect(await engine.state.accounts[.notion]?.login == "Acme")
    rig.auth.respond.with { $0 = { url in
      let state = googleQuery(url)["state"]!
      return "\(GoogleAuth.redirect)?code=mock-google-code&state=\(state)"
    } }
    try await engine.connectGoogleDrive(clientId: " cid ", clientSecret: "secret")
    #expect(await engine.state.accounts[.gdrive]?.login == "octo@acme.com")
    #expect(await engine.state.config.googleClientId == "cid")
    let id = await engine.newProfileLiveFolder(profileId: "p", kind: .documents)
    #expect(await engine.state.folders[id]?.sources == [.notion, .gdrive])
    await engine.refreshFolder(id).value
    let items = await engine.state.items[id]!
    #expect(Set(items.map(\.source)) == [.notion, .gdrive])
    #expect(items.map(\.updatedAt) == items.map(\.updatedAt).sorted(by: >))
    #expect(await engine.state.unread[id] == [], "the first fetch marks nothing unread")
    #expect(await engine.liveFolderIcon(engine.state.folders[id]!).icon == "symbol:doc.text")
  }

  @Test func anExpiredGoogleTokenIsRefreshedAndStored() async throws {
    let rig = Rig(mock: mock)
    let tokens = GoogleTokens(access_token: "old", refresh_token: "r", expires_at: rig.clock.now() + 59_000, client_secret: "s")
    rig.secrets.setSecret(try LiveJSON.text(tokens), account: "mock:gdrive")
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [.gdrive])
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.items[id]?.count == 2)
    let stored = try LiveJSON.decode(GoogleTokens.self, from: await rig.secrets.secret(account: "mock:gdrive")!)
    #expect(stored.access_token == "mock-google-access")
    #expect(stored.expires_at == rig.clock.now() + 3_600_000)
    #expect(rig.http.log.current.first?.bodyText?.contains("grant_type=refresh_token") == true)
    #expect(rig.http.log.current.first?.followsRedirects == false)
  }

  @Test func googleSignInRejectsARedirectFromAnotherRequest() async {
    let rig = Rig(mock: mock)
    rig.auth.respond.with { $0 = { _ in "\(GoogleAuth.redirect)?code=c&state=wrong" } }
    await #expect(throws: LiveAuthError("Sign-in didn't match this request")) {
      try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s")
    }
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?error=access_denied&state=\(googleQuery(url)["state"]!)" } }
    await #expect(throws: LiveAuthError("access_denied")) { try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s") }
    let opened = rig.auth.opened.current.last!
    let q = googleQuery(opened)
    #expect(opened.hasPrefix("\(MockServer.base)/google/auth?client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fsolara-oauth"))
    #expect(q["code_challenge"]?.count == 43 && q["state"]?.count == 24 && q["code_challenge_method"] == "S256")
  }

  @Test func googleSignInRejectsWrongRedirectTargetsAndDuplicateStateBeforeExchange() async {
    let rig = Rig(mock: mock)
    for target in [
      "http://127.0.0.1:53682/solara-oauth-other",
      "http://localhost:53682/solara-oauth",
      "https://127.0.0.1:53682/solara-oauth",
      "http://127.0.0.1:53683/solara-oauth",
      "http://user@127.0.0.1:53682/solara-oauth",
    ] {
      rig.auth.respond.with { $0 = { url in "\(target)?code=c&state=\(googleQuery(url)["state"]!)" } }
      await #expect(throws: LiveAuthError.self) { try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s") }
    }
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?code=c&state=wrong&state=\(googleQuery(url)["state"]!)" } }
    await #expect(throws: LiveAuthError.self) { try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s") }
    #expect(rig.http.log.current.isEmpty)
    #expect(await rig.secrets.secret(account: "mock:gdrive") == nil)
  }

  @Test func googleCredentialFailureDoesNotExposeTheResponseBodyOrSaveAccount() async throws {
    let rig = Rig(environment: LiveEnvironment(mockBase: MockServer.base), http: FakeHTTP { _ in
      json(["error": "invalid_client", "description": "private-client-secret"], status: 400)
    })
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?code=c&state=\(googleQuery(url)["state"]!)" } }
    await #expect(throws: LiveAuthError("Google couldn't verify these credentials")) {
      try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "private-client-secret")
    }
    #expect(await rig.engine.state.accounts[.gdrive] == nil)
    #expect(await rig.secrets.secret(account: "mock:gdrive") == nil)
  }

  @Test(.timeLimit(.minutes(1))) func replacingAnAccountRejectsItsLateTokenRefresh() async throws {
    let (started, enter) = AsyncStream<Void>.makeStream()
    let (release, resume) = AsyncStream<Void>.makeStream()
    let rig = Rig(environment: LiveEnvironment(mockBase: MockServer.base), http: FakeHTTP { request in
      if request.bodyText?.contains("grant_type=refresh_token") == true {
        enter.finish()
        for await _ in release {}
        return json(["access_token": "late-old-access", "expires_in": 3600])
      }
      if request.url.contains("/about") {
        return json(["user": ["emailAddress": "new@example.test", "displayName": "Fixture"]])
      }
      return json(["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600])
    })
    let old = GoogleTokens(access_token: "old-access", refresh_token: "old-refresh", expires_at: rig.clock.now(), client_secret: "old")
    _ = rig.secrets.setSecret(try LiveJSON.text(old), account: "mock:gdrive")
    let refreshing = Task { try await rig.engine.googleAccessToken() }
    defer { resume.finish() }
    for await _ in started {}
    try await rig.engine.disconnect(.gdrive)
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?code=c&state=\(googleQuery(url)["state"]!)" } }
    try await rig.engine.connectGoogleDrive(clientId: "new", clientSecret: "new")
    resume.finish()

    await #expect(throws: LiveError(.signedOut, "Google Drive sign-in changed")) {
      try await refreshing.value
    }
    #expect(try await rig.engine.googleAccessToken() == "new-access")
    #expect(await rig.engine.state.config.googleClientId == "new")
    #expect(await rig.engine.state.accounts[.gdrive]?.login == "new@example.test")
  }

  @Test(.timeLimit(.minutes(1))) func cancellationBeforeTheCredentialCommitPreservesThePreviousAccount() async throws {
    let (started, enter) = AsyncStream<Void>.makeStream()
    let (release, resume) = AsyncStream<Void>.makeStream()
    let rig = Rig(environment: LiveEnvironment(mockBase: MockServer.base), http: FakeHTTP { request in
      if request.url.contains("/about") {
        enter.finish()
        for await _ in release {}
        return json(["user": ["emailAddress": "new@example.test", "displayName": "Fixture"]])
      }
      return json(["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600])
    })
    let old = GoogleTokens(access_token: "old-access", refresh_token: "old-refresh", expires_at: rig.clock.now() + 3_600_000, client_secret: "old")
    let oldSecret = try LiveJSON.text(old)
    _ = rig.secrets.setSecret(oldSecret, account: "mock:gdrive")
    await rig.engine.updateConfig(ConfigPatch(googleClientId: "old"))
    await rig.engine.setAccount(.gdrive, LiveAccount(login: "old@example.test", name: nil, avatar: nil, connectedAt: 1))
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?code=c&state=\(googleQuery(url)["state"]!)" } }
    let connecting = Task { try await rig.engine.connectGoogleDrive(clientId: "new", clientSecret: "new") }
    defer { resume.finish() }
    for await _ in started {}
    connecting.cancel()
    resume.finish()

    await #expect(throws: LiveAuthError("Cancelled")) { try await connecting.value }
    #expect(await rig.secrets.secret(account: "mock:gdrive") == oldSecret)
    #expect(await rig.engine.state.config.googleClientId == "old")
    #expect(await rig.engine.state.accounts[.gdrive]?.login == "old@example.test")
  }

  @Test func theDeviceFlowPollsAtItsIntervalBacksOffOnSlowDownAndConnects() async throws {
    let rig = Rig(mock: mock)
    mock.model.with { $0.deviceResponses = [["error": "authorization_pending"], ["error": "slow_down", "interval": 6]] }
    let flow = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    #expect(flow.userCode == "WDJB-MJHT")
    #expect(flow.expiresAt == rig.clock.now() + 900_000)
    await settle()
    #expect(rig.clock.pending == [rig.clock.now() + 1000])
    await rig.clock.advance(by: 1000)
    await rig.clock.advance(by: 1000)
    #expect(rig.clock.pending == [rig.clock.now() + 6000])
    mock.model.with { $0.approved = true }
    await rig.clock.advance(by: 6000)
    try await flow.done.value
    #expect(await rig.engine.state.accounts[.github]?.login == "octo-dev")
    #expect(await rig.secrets.secret(account: "mock:github") == "mock-token")
  }

  @Test func aCancelledOrDeniedDeviceFlowSaysWhy() async throws {
    let rig = Rig(mock: mock)
    let flow = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    await settle()
    flow.cancel()
    await #expect(throws: LiveError(.signedOut, "Cancelled")) { try await flow.done.value }
    mock.model.with { $0.deviceResponses = [["error": "access_denied"]] }
    let denied = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    await settle()
    await rig.clock.advance(by: 1000)
    await #expect(throws: LiveError(.signedOut, "Access was denied")) { try await denied.done.value }
  }
}

private func googleQuery(_ url: String) -> [String: String] {
  let fields = URLComponents(string: url)?.queryItems ?? []
  return Dictionary(uniqueKeysWithValues: fields.compactMap { field in field.value.map { (field.name, $0) } })
}
