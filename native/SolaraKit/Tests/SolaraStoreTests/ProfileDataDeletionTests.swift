import Foundation
import SolaraModel
@testable import SolaraStore
import Testing

@MainActor
private final class ProfileDeletionCallback {
  private var completion: ProfileDataCleanup.Completion?
  private var signal = ProfileCleanupSignal()

  func begin(_ done: @escaping ProfileDataCleanup.Completion) {
    completion = done
    signal.signal()
  }

  func started(producer: Task<Void, Never>) async -> Bool { await signal.wait(producer: producer) }

  func finish(_ remaining: [String] = []) {
    let done = completion
    completion = nil
    signal = ProfileCleanupSignal()
    done?(remaining)
  }
}

private func deletionStore(_ engines: [String], launch: String = UUID().uuidString, tombstones: URL? = nil) -> Store {
  var state = BrowserState(settings: Settings.hydrated(from: nil))
  var current = state.profiles[Settings.defaultProfileID]!
  current.dataId = "p-active-1"
  state.profiles[current.id] = current
  state.orphanedProfileData = engines
  var config = StoreConfig()
  config.syncOrigins = true
  config.profileDataTombstones = tombstones ?? FileManager.default.temporaryDirectory.appendingPathComponent("profile-tombstones-\(UUID().uuidString).json")
  return Store(state: state, memory: StoreMemory(ids: IdSource(launch: launch)), config: config, clock: { 1_000 })
}

private func sameProfile(_ stored: Profile?, _ expected: Profile) -> Bool {
  stored?.id == expected.id && stored?.name == expected.name && stored?.color == expected.color && stored?.dataId == expected.dataId
}

private func adoption(_ dataId: String, profileId: String = Settings.defaultProfileID) -> Command {
  Command("updateProfile", [.string(profileId), ["dataId": .string(dataId)]])
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ProfileDataDeletionTests {
  @Test(arguments: ["default", "p-mgg8w000-1", "p-mgg8w000abcd-z", "p-01234567-89ab-cdef-0123-456789abcdef-1"])
  func historicalGeneratedIdentitiesAreAccepted(id: String) throws {
    #expect(ProfileDataCleanup.validProfileId(id))
    let store = deletionStore([])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    try store.dispatch(adoption(id))
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == id)
    let profile = Profile(id: id, name: "Historical", color: "blue", icon: nil, createdAt: 0)
    var profiles = store.state.profiles.map.mapValues(\.jsonValue)
    profiles[id] = profile.jsonValue
    try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": JSONValue(id == Settings.defaultProfileID ? [id] : [Settings.defaultProfileID, id])]]))
    #expect(store.state.profiles[id]?.id == id)
  }

  @Test(arguments: ["P-mgg8w000-1", "p-mgg8W000-1", "p-01234567-89AB-cdef-0123-456789abcdef-1", "off-shape", "p-launch-01", "p-launch-1\n"])
  func offShapeIdentitiesCannotBeCreatedAdoptedOrApplied(id: String) throws {
    #expect(!ProfileDataCleanup.validProfileId(id))
    let store = deletionStore([])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let before = store.state
    #expect(throws: CommandError.self) { try store.dispatch(adoption(id)) }
    #expect(throws: CommandError.self) { try store.dispatch(Command("updateProfile", ["default", ["id": .string(id)]])) }
    let profile = Profile(id: id, name: "Rejected", color: "blue", icon: nil, createdAt: 0)
    let payload: JSONValue = ["profiles": [id: profile.jsonValue]]
    #expect(throws: CommandError.self) { try store.dispatch(Command("applyState", [payload, ["fromSync": true]]), fromSync: true) }
    #expect(throws: CommandError.self) { try store.dispatch(Command("hydrate", [payload])) }
    #expect(store.state == before)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let saved: JSONValue = ["version": 2, "profiles": [id: profile.jsonValue], "profileOrder": JSONValue([id])]
    let file = folder.appendingPathComponent("session.json")
    try Data(saved.text().utf8).write(to: file)
    let loaded = try JSONValue.parse(Data(contentsOf: file))
    try store.transact { _ = $0.loadSession(loaded, downloads: nil) }
    #expect(store.state.profiles[id]?.id == id)
    #expect(throws: CommandError.self) { try store.dispatch(Command("updateProfile", [.string(id), ["name": "Remote rename"]]), fromSync: true) }
    try store.dispatch(Command("updateProfile", [.string(id), ["name": "Still visible"]]))
    #expect(store.state.profiles[id]?.name == "Still visible")
    #expect(throws: CommandError.self) { try store.dispatch(Command("createProfile", [["name": "Sharer", "shareWith": .string(id)]])) }
  }

  @Test func diskReplicaProfilesReloadExactIdentitiesAndLiveAdmissionStaysStrict() throws {
    var config = StoreConfig()
    config.replicaProfilesFromDisk = true
    config.profileDataTombstones = FileManager.default.temporaryDirectory.appendingPathComponent("profile-tombstones-\(UUID().uuidString).json")
    let store = Store(config: config)
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    var profile = Profile(id: "Saved-MixedCase", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    profile.dataId = "Saved-Data"
    let payload: JSONValue = ["profiles": [profile.id: profile.jsonValue], "profileOrder": JSONValue([profile.id])]
    try store.dispatch(Command("attachReplicaProfiles", [payload]))
    #expect(sameProfile(store.state.profiles[profile.id], profile))
    let before = store.state
    try store.dispatch(Command("attachReplicaProfiles", [payload]))
    #expect(store.state == before)
    #expect(throws: CommandError.self) { try store.dispatch(Command("applyState", [payload, ["attach": true]])) }
    #expect(throws: CommandError.self) { try store.dispatch(Command("hydrate", [payload])) }
    #expect(store.state == before)
    let fullNative = deletionStore([])
    defer { if let file = fullNative.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    #expect(throws: CommandError.self) { try fullNative.dispatch(Command("attachReplicaProfiles", [payload])) }
    #expect(fullNative.state.profiles[profile.id] == nil)
  }

  @Test(arguments: ["Saved-MixedCase", "saved-MixedCase", "Sav\u{e9}d", "Save\u{301}d"])
  func reloadRefusesNewOffShapeProfilesWithoutDroppingValidProfiles(id: String) throws {
    var config = StoreConfig()
    config.replicaProfilesFromDisk = true
    let store = Store(config: config)
    let saved = Profile(id: "Saved-MixedCase", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    let first: JSONValue = ["profiles": [saved.id: saved.jsonValue], "profileOrder": JSONValue([saved.id])]
    try store.dispatch(Command("attachReplicaProfiles", [first]))
    var changed = Profile(id: id, name: "Changed", color: "blue", icon: nil, createdAt: 0)
    changed.dataId = "Other-Data"
    let generated = Profile(id: "p-valid-1", name: "Valid", color: "blue", icon: nil, createdAt: 0)
    let reload: JSONValue = ["profiles": [id: changed.jsonValue, generated.id: generated.jsonValue], "profileOrder": JSONValue([id, generated.id])]
    try store.dispatch(Command("attachReplicaProfiles", [reload]))
    #expect(store.state.profiles[id] == nil)
    #expect(sameProfile(store.state.profiles[generated.id], generated))
    #expect(!store.state.profileOrder.contains { $0.jsEquals(id) })
    #expect(store.state.profileOrder.contains { $0.jsEquals(generated.id) })
  }

  @Test(arguments: [false, true])
  func reloadRequiresExactOptionalDataId(hadExplicitDataId: Bool) throws {
    var config = StoreConfig()
    config.replicaProfilesFromDisk = true
    let store = Store(config: config)
    var profile = Profile(id: "Saved-MixedCase", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    profile.dataId = hadExplicitDataId ? profile.id : nil
    let first: JSONValue = ["profiles": [profile.id: profile.jsonValue], "profileOrder": JSONValue([profile.id])]
    try store.dispatch(Command("attachReplicaProfiles", [first]))
    profile.dataId = hadExplicitDataId ? nil : profile.id
    let reload: JSONValue = ["profiles": [profile.id: profile.jsonValue], "profileOrder": JSONValue([profile.id])]
    try store.dispatch(Command("attachReplicaProfiles", [reload]))
    #expect(store.state.profiles[profile.id] == nil)
  }

  @Test(arguments: [false, true])
  func diskReplicaAttachRefusesEverySyncOriginWithoutDependingOnSyncTags(tags: Bool) throws {
    var config = StoreConfig()
    config.replicaProfilesFromDisk = true
    config.syncOrigins = tags
    let profile = Profile(id: "Saved-MixedCase", name: "Saved", color: "blue", icon: nil, createdAt: 0)
    let payload: JSONValue = ["profiles": [profile.id: profile.jsonValue], "profileOrder": JSONValue([profile.id])]
    let command = Command("attachReplicaProfiles", [payload])
    let flagged = Store(config: config)
    #expect(throws: CommandError.self) { try flagged.dispatch(command, fromSync: true) }
    #expect(flagged.state.profiles[profile.id] == nil)
    try flagged.dispatch(command)
    #expect(sameProfile(flagged.state.profiles[profile.id], profile))
    let origin = Store(config: config)
    #expect(throws: CommandError.self) { try origin.dispatch(command, origin: .sync) }
    #expect(origin.state.profiles[profile.id] == nil)
    let transaction = Store(config: config)
    #expect(throws: CommandError.self) { try transaction.transact(fromSync: true) { try $0.apply(command) } }
    #expect(transaction.state.profiles[profile.id] == nil)
    let bracketed = Store(config: config)
    try bracketed.dispatch(Command("beginFromSync"))
    #expect(throws: CommandError.self) { try bracketed.dispatch(command) }
    try bracketed.dispatch(Command("endFromSync"))
    try bracketed.dispatch(command)
    #expect(sameProfile(bracketed.state.profiles[profile.id], profile))
    let argument = Store(config: config)
    #expect(throws: CommandError.self) { try argument.dispatch(Command("attachReplicaProfiles", [payload, ["fromSync": true]])) }
    #expect(argument.state.profiles[profile.id] == nil)
  }

  @Test func inMemoryReplayKeepsItsSyntheticIdentityContract() throws {
    let store = Store()
    let profile = Profile(id: "work", name: "Synthetic replay", color: "blue", icon: nil, createdAt: 0)
    try store.dispatch(Command("hydrate", [["profiles": ["work": profile.jsonValue], "profileOrder": ["work"]]]))
    #expect(store.state.profiles["work"]?.id == "work")
    try store.dispatch(Command("createProfile", [["name": "Shared replay", "shareWith": "work"]]))
    #expect(store.state.profiles.values.contains { $0.dataId == "work" })
  }

  @Test func callbackArrivalFailsWhenCleanupExitsBeforeDeletion() async throws {
    let store = deletionStore(["p-retired-1"])
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: { throw CancellationError() })
    service.start()
    defer { service.stop() }
    let draining = try #require(service.task)
    #expect(!(await callback.started(producer: draining)))
    #expect(store.state.orphanedProfileData == ["p-retired-1"])
  }

  @Test(arguments: ["", "p-retired-1", "retiré"])
  func inFlightExactAdoptionIsRefusedAndFilesSurvive(engine: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let active = root.appendingPathComponent("Profile p-active-1", isDirectory: true)
    let retired = root.appendingPathComponent(engine.isEmpty ? "Default" : "Profile \(engine)", isDirectory: true)
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
    let sentinel = active.appendingPathComponent("sentinel")
    try Data("adopter data".utf8).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = deletionStore([engine])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    try ProfileDataTombstones.insert(engine, at: store.config.profileDataTombstones)
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    let before = store.state
    let dataIds = engine.isEmpty ? [Settings.defaultProfileID] : [engine]
    for id in dataIds {
      #expect(throws: CommandError.self) { try store.dispatch(adoption(id)) }
      #expect(store.state == before)
    }
    try FileManager.default.removeItem(at: retired)
    callback.finish()
    await draining.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(try Data(contentsOf: sentinel) == Data("adopter data".utf8))
    #expect(throws: CommandError.self) { try store.dispatch(adoption(dataIds[0])) }
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-active-1")
  }

  @Test func aPublicAcknowledgementCannotReleaseAnInFlightReservation() async throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    try store.dispatch(Command("profileDataDeleted", ["p-retired-1"]))
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(throws: CommandError.self) { try store.dispatch(adoption("p-retired-1")) }
    callback.finish()
    await draining.value
    #expect(throws: CommandError.self) { try store.dispatch(adoption("p-retired-1")) }
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-active-1")
  }

  @Test func aLegacyDefaultQueueReservesItsNameOnlyWhenCleanupExecutes() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("profile-tombstones-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = deletionStore([""], tombstones: file)
    #expect(try ProfileDataTombstones.read(file, pending: [""], live: ["p-active-1"]).isEmpty)
    var deleted: [String] = []
    let service = ProfileDataCleanup(store: store, delete: { engine, done in deleted.append(engine); done([]) }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(deleted == [""])
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(throws: CommandError.self) { try store.dispatch(adoption(Settings.defaultProfileID)) }
    let ledger = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((ledger["deleted"] as? [String]) == [])
    #expect((ledger["reserved"] as? [String]) == [""])
  }

  @Test func aFailedCallbackKeepsTheNameRetiredEvenAfterASuccessfulRetry() async throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    try store.dispatch(Command("profileDataDeleted", ["p-retired-1"]))
    callback.finish(["Chromium profile directory"])
    await draining.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(throws: CommandError.self) { try store.dispatch(adoption("p-retired-1")) }
    try store.transact { $0.update { $0.orphanedProfileData = ["p-retired-1"] } }
    service.retry()
    try #require(await callback.started(producer: try #require(service.task)))
    let retrying = try #require(service.task)
    callback.finish()
    await retrying.value
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(throws: CommandError.self) { try store.dispatch(adoption("p-retired-1")) }
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-active-1")
  }

  @Test func creatingASharerOfPendingDataIsRefused() throws {
    let store = deletionStore(["p-active-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let before = store.state
    #expect(throws: CommandError.self) {
      try store.dispatch(Command("createProfile", [["name": "Shared", "shareWith": .string(Settings.defaultProfileID)]]))
    }
    #expect(store.state == before)
  }

  @Test func removingDataIdAndChangingProfileIdCannotBypassTheFence() throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    var profiles = store.state.profiles
    var profile = profiles[Settings.defaultProfileID]!
    profile.id = "p-retired-1"
    profiles[profile.id] = profile
    try store.transact { $0.update { $0.profiles = profiles; $0.profileOrder.append(profile.id) } }
    let before = store.state
    #expect(throws: CommandError.self) {
      try store.dispatch(Command("updateProfile", ["p-retired-1", ["$unset": ["dataId"]]]))
    }
    #expect(store.state == before)
    #expect(throws: CommandError.self) {
      try store.dispatch(Command("updateProfile", ["p-retired-1", ["id": "different-key", "dataId": "p-retired-1"]]))
    }
    #expect(store.state == before)
  }

  @Test func aSyncProfileApplyThrowsWithoutChangingTheSessionEvenAfterAck() async throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    let before = store.state
    var profile = before.profiles[Settings.defaultProfileID]!
    profile.dataId = "p-retired-1"
    let payload: JSONValue = ["profiles": [Settings.defaultProfileID: profile.jsonValue], "orphanedProfileData": []]
    let apply = { try store.dispatch(Command("applyState", [payload, ["fromSync": true]]), origin: .bridge, fromSync: true) }
    #expect(throws: CommandError.self) { try apply() }
    #expect(store.state == before)
    #expect(store.rev == 0)
    callback.finish()
    await draining.value
    #expect(throws: CommandError.self) { try apply() }
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-active-1")
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func theSameSyncAdoptionSucceedsOnceTheBindingIsLegitimate() async throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    var profile = store.state.profiles[Settings.defaultProfileID]!
    profile.dataId = "p-retired-1"
    let payload: JSONValue = ["profiles": [Settings.defaultProfileID: profile.jsonValue], "profileOrder": [.string(Settings.defaultProfileID)]]
    let apply = { try store.dispatch(Command("applyState", [payload, ["fromSync": true]]), origin: .bridge, fromSync: true) }
    let before = store.state
    #expect(throws: CommandError.self) { try apply() }
    #expect(store.state == before)
    try store.transact { session in
      session.update {
        $0.profiles["p-legitimate-1"] = Profile(id: "p-legitimate-1", name: "Live", color: "blue", icon: nil, createdAt: 0, dataId: "p-retired-1")
        $0.profileOrder.append("p-legitimate-1")
      }
    }
    let service = ProfileDataCleanup(store: store, delete: { _, _ in Issue.record("Live data reached deletion") }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(store.state.orphanedProfileData.isEmpty)
    _ = try apply()
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-retired-1")
  }

  @Test func applyStateCannotIntroduceANewProfileWithPendingData() throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let before = store.state
    let added = Profile(id: "p-retired-1", name: "Restored", color: "blue", icon: nil, createdAt: 0)
    var profiles = before.profiles.map.mapValues(\.jsonValue)
    profiles[added.id] = added.jsonValue
    #expect(throws: CommandError.self) {
      try store.dispatch(Command("applyState", [["profiles": .object(profiles), "profileOrder": JSONValue(before.profileOrder + [added.id])]]))
    }
    #expect(store.state == before)
  }

  @Test func diskHydrationKeepsTheSavedIdentityAndDropsItsStaleQueueItem() throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    var profile = store.state.profiles[Settings.defaultProfileID]!
    profile.dataId = "p-retired-1"
    let saved: JSONValue = ["profiles": [Settings.defaultProfileID: profile.jsonValue], "orphanedProfileData": ["p-retired-1"]]
    try store.transact { $0.hydrate(try HydrateData(json: saved.object!)) }
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-retired-1")
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func inFlightHydrationCannotRaceDeletionButSavedDiskIdentityWinsAfterward() async throws {
    let store = deletionStore(["p-retired-1"])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in callback.begin(done) }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    var profile = store.state.profiles[Settings.defaultProfileID]!
    profile.dataId = "p-retired-1"
    let saved: JSONValue = ["profiles": [Settings.defaultProfileID: profile.jsonValue]]
    let before = store.state
    #expect(throws: CommandError.self) { try store.dispatch(Command("hydrate", [saved])) }
    #expect(store.state == before)
    callback.finish()
    await draining.value
    try store.dispatch(Command("hydrate", [saved]))
    #expect(store.state.profiles[Settings.defaultProfileID]?.dataId == "p-retired-1")
  }

  @Test func deletionHistoryIsWrittenOncePerDeletionAndNeverByReadsOrItsOwnCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    func fileNumber() throws -> Int? {
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      return try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    }
    let store = deletionStore([], tombstones: file)
    let first = try #require(try store.dispatch(Command("createProfile", [["name": "First"]])).result?.string)
    let second = try #require(try store.dispatch(Command("createProfile", [["name": "Second"]])).result?.string)
    #expect(try fileNumber() == nil)
    try store.dispatch(Command("deleteProfile", [.string(first)]))
    let written = try #require(try fileNumber())
    let service = ProfileDataCleanup(store: store, delete: { _, done in done([]) }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(store.state.orphanedProfileData.isEmpty)
    _ = try store.dispatch(Command("createProfile", [["name": "Third"]]))
    try store.dispatch(Command("updateProfile", [.string(second), ["name": "Renamed"]]))
    #expect(try fileNumber() == written)
    #expect(try ProfileDataTombstones.read(file).contains { $0.jsEquals(first) })
  }

  @Test func aFailedDurabilityBarrierIsRetriedBeforeTheDeletionIsAccepted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    let store = deletionStore([], tombstones: file)
    let doomed = try #require(try store.dispatch(Command("createProfile", [["name": "Doomed"]])).result?.string)
    ProfileDataTombstones.failingSynchronization.withLock { _ = $0.insert(file.path) }
    defer { ProfileDataTombstones.failingSynchronization.withLock { _ = $0.remove(file.path) } }
    #expect(throws: (any Error).self) { try store.dispatch(Command("deleteProfile", [.string(doomed)])) }
    #expect(store.state.profiles[doomed] != nil)
    #expect(try ProfileDataTombstones.read(file).contains { $0.jsEquals(doomed) })
    #expect(throws: (any Error).self) { try store.dispatch(Command("deleteProfile", [.string(doomed)])) }
    #expect(throws: (any Error).self) {
      try ProfileDataTombstones.reserve(doomed, at: file, pending: [doomed], live: [])
    }
    ProfileDataTombstones.failingSynchronization.withLock { _ = $0.remove(file.path) }
    try store.dispatch(Command("deleteProfile", [.string(doomed)]))
    #expect(store.state.profiles[doomed] == nil)
    #expect(store.state.orphanedProfileData.contains { $0.jsEquals(doomed) })
  }

  @Test(arguments: [false, true])
  func aLedgerFromAnEarlierLaunchIsSynchronizedBeforeItIsReliedOn(reserving: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    try Data(#"{"deleted":["p-earlier-1"],"reserved":[]}"#.utf8).write(to: file)
    ProfileDataTombstones.failingSynchronization.withLock { _ = $0.insert(file.path) }
    defer { ProfileDataTombstones.failingSynchronization.withLock { _ = $0.remove(file.path) } }
    func rely() throws {
      if reserving { try ProfileDataTombstones.reserve("p-earlier-1", at: file, pending: ["p-earlier-1"], live: []) }
      else { try ProfileDataTombstones.insert("p-earlier-1", at: file) }
    }
    #expect(throws: (any Error).self) { try rely() }
    #expect(throws: (any Error).self) { try rely() }
    ProfileDataTombstones.failingSynchronization.withLock { _ = $0.remove(file.path) }
    try rely()
    let number = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    try rely()
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int == number)
  }

  @Test(arguments: [false, true])
  func aRebuiltLedgerIsWrittenBeforeCleanupDeletesANameItAlreadyFound(corrupt: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Chromium/Profile p-found-1"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    if corrupt { try Data("broken".utf8).write(to: file) }
    let store = deletionStore(["p-found-1"], tombstones: file)
    var reservedBeforeDeletion: [String]? = nil
    let service = ProfileDataCleanup(store: store, delete: { _, done in
      let ledger = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      reservedBeforeDeletion = ledger?["reserved"] as? [String]
      done([])
    }, grace: {})
    service.start()
    defer { service.stop() }
    await service.task?.value
    #expect(reservedBeforeDeletion?.contains("p-found-1") == true)
    #expect(store.state.orphanedProfileData.isEmpty)
    #expect(try ProfileDataTombstones.read(file).contains { $0.jsEquals("p-found-1") })
  }

  @Test func startupNukeCannotReachFreshDataAfterAcknowledgementOrRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let launch = UUID().uuidString
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    let store = deletionStore([], launch: launch, tombstones: file)
    let retired = try #require(try store.dispatch(Command("createProfile", [["name": "Retiring"]])).result?.string)
    let oldDirectory = root.appendingPathComponent("Profile \(retired)", isDirectory: true)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    try store.dispatch(Command("deleteProfile", [.string(retired)]))
    let releaseStartupNuke = ProfileCleanupSignal()
    let startupNuke = Task.detached {
      guard await releaseStartupNuke.wait() else { return false }
      try? FileManager.default.removeItem(at: oldDirectory)
      return true
    }
    defer { releaseStartupNuke.finish() }
    let callback = ProfileDeletionCallback()
    let service = ProfileDataCleanup(store: store, delete: { _, done in
      try? FileManager.default.removeItem(at: oldDirectory)
      #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
      callback.begin(done)
    }, grace: {})
    service.start()
    defer { service.stop() }
    try #require(await callback.started(producer: try #require(service.task)))
    let draining = try #require(service.task)
    #expect(try ProfileDataTombstones.contains(retired, at: file))
    callback.finish()
    await draining.value
    #expect(store.state.orphanedProfileData.isEmpty)
    let fresh = try #require(try store.dispatch(Command("createProfile", [["name": "Fresh"]])).result?.string)
    #expect(!fresh.jsEquals(retired))
    try store.dispatch(adoption(fresh))
    #expect(throws: CommandError.self) { try store.dispatch(adoption(retired)) }
    let firstSentinel = root.appendingPathComponent("Profile \(fresh)/sentinel")
    try FileManager.default.createDirectory(at: firstSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("first".utf8).write(to: firstSentinel)
    service.stop()
    let restarted = Store(state: store.state, memory: StoreMemory(ids: IdSource(launch: launch)), config: store.config)
    #expect(throws: CommandError.self) { try restarted.dispatch(adoption(retired)) }
    let next = try #require(try restarted.dispatch(Command("createProfile", [["name": "After restart"]])).result?.string)
    #expect(!next.jsEquals(retired))
    #expect(next != fresh)
    #expect(restarted.state.profiles[fresh] == store.state.profiles[fresh])
    try restarted.dispatch(adoption(next))
    #expect(restarted.state.profiles[Settings.defaultProfileID]?.dataId == next)
    let nextSentinel = root.appendingPathComponent("Profile \(next)/sentinel")
    try FileManager.default.createDirectory(at: nextSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("next".utf8).write(to: nextSentinel)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    releaseStartupNuke.signal()
    try #require(await startupNuke.value)
    #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
    #expect(try Data(contentsOf: firstSentinel) == Data("first".utf8))
    #expect(try Data(contentsOf: nextSentinel) == Data("next".utf8))
    #expect(throws: CommandError.self) { try restarted.dispatch(adoption(retired)) }
  }

  @Test func theUnversionedDefaultAcknowledgementKeepsItsCommandContract() throws {
    let store = deletionStore([""])
    defer { if let file = store.config.profileDataTombstones { try? FileManager.default.removeItem(at: file) } }
    try store.dispatch(Command("profileDataDeleted", [""]))
    #expect(store.state.orphanedProfileData.isEmpty)
  }

  @Test func interruptedDeletionReloadsTheSavedSessionUnchangedThenRetriesInSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var config = StoreConfig()
    config.profileDataTombstones = root.appendingPathComponent("profile-data-tombstones.json")
    let store = Store(config: config)
    let retired = try #require(try store.dispatch(Command("createProfile", [["name": "Retiring"]])).result?.string)
    _ = try store.dispatch(Command("createWindow", [["url": "https://kept.example"]]))
    let target = root.appendingPathComponent("Chromium/Profile \(retired)")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try store.dispatch(Command("deleteProfile", [.string(retired)]))
    #expect(try ProfileDataTombstones.contains(retired, at: config.profileDataTombstones))
    let deleting = ProfileDataCleanup(store: store, delete: { _, done in done(["pending restart"]) }, grace: {})
    deleting.start()
    await deleting.task?.value
    deleting.stop()
    let saved = store.state
    let restarted = Store(state: saved, memory: StoreMemory(ids: IdSource(launch: UUID().uuidString)), config: config)
    #expect(restarted.state == saved)
    #expect(restarted.state.orphanedProfileData == [retired])
    #expect(FileManager.default.fileExists(atPath: target.path))
    let cleanup = ProfileDataCleanup(store: restarted, delete: { engine, done in
      #expect(engine.jsEquals(retired))
      do { try FileManager.default.removeItem(at: target); done([]) } catch { done([String(describing: error)]) }
    }, grace: {})
    cleanup.start()
    defer { cleanup.stop() }
    await cleanup.task?.value
    #expect(!FileManager.default.fileExists(atPath: target.path))
    var expected = saved
    expected.orphanedProfileData = []
    #expect(restarted.state == expected)
    #expect(throws: CommandError.self) { try restarted.dispatch(adoption(retired)) }
  }

  @Test(arguments: [false, true])
  func damagedHistoryRebuildsReservationsWithoutBlockingCreationOrLiveSharing(unreadable: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let chromium = root.appendingPathComponent("Chromium")
    for name in ["Profile on-disk", "Default", "Profile p-live-1"] {
      try FileManager.default.createDirectory(at: chromium.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("profile-data-tombstones.json")
    if unreadable { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
    else { try Data("broken".utf8).write(to: file) }
    try Data(#"{"profiles":{"profile_basenames_deleted":["Profile marked","Default","Profile p-live-1"]}}"#.utf8)
      .write(to: chromium.appendingPathComponent("Local State"))
    var config = StoreConfig()
    config.profileDataTombstones = file
    var saved = BrowserState(settings: Settings.hydrated(from: nil))
    saved.profiles["p-named-1"] = Profile(id: "p-named-1", name: "Named", color: "blue", icon: nil, createdAt: 0, dataId: "p-live-1")
    saved.profileOrder.append("p-named-1")
    saved.orphanedProfileData = ["queued"]
    let store = Store(state: saved, memory: StoreMemory(ids: IdSource(launch: "reused")), config: config)
    #expect(store.state == saved)
    let fresh = try #require(try store.dispatch(Command("createProfile", [["name": "Fresh"]])).result?.string)
    #expect(fresh != "p-reused-1")
    for id in [Settings.defaultProfileID, "p-named-1"] {
      let shared = try #require(try store.dispatch(Command("createProfile", [["name": "Shared", "shareWith": .string(id)]])).result?.string)
      #expect(store.state.profiles[shared]?.dataId == dataIdOf(saved.profiles[id]!))
    }
    for engine in ["on-disk", "queued", "marked"] {
      #expect(throws: CommandError.self) {
        try store.dispatch(Command("updateProfile", ["default", ["dataId": .string(engine)]]))
      }
    }
    #expect(store.state.profiles[Settings.defaultProfileID] == saved.profiles[Settings.defaultProfileID])
    #expect(store.state.profiles["p-named-1"] == saved.profiles["p-named-1"])
    if !unreadable {
      let ledger = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      #expect((ledger["deleted"] as? [String]) == [])
      let reserved = try #require(ledger["reserved"] as? [String])
      #expect(Set(reserved) == Set(["on-disk", "queued", "marked"]))
      #expect(!reserved.contains(""))
      #expect(!reserved.contains("p-live-1"))
    }
  }

  @Test func unwritableDeletionHistoryKeepsTheProfileDataAndQueueUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("Chromium/Profile p-live-1")
    let ledger = root.appendingPathComponent("profile-data-tombstones.json")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = target.appendingPathComponent("sentinel")
    try Data("live data".utf8).write(to: sentinel)
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    state.profiles["p-named-1"] = Profile(id: "p-named-1", name: "Named", color: "blue", icon: nil, createdAt: 0, dataId: "p-live-1")
    state.profileOrder.append("p-named-1")
    var config = StoreConfig()
    config.profileDataTombstones = ledger
    let store = Store(state: state, config: config)
    #expect(throws: (any Error).self) { try store.dispatch(Command("deleteProfile", ["p-named-1"])) }
    #expect(store.state == state)
    #expect(store.state.profiles["p-named-1"]?.dataId == "p-live-1")
    #expect(store.state.orphanedProfileData.isEmpty)
    var deletions = 0
    let cleanup = ProfileDataCleanup(store: store, delete: { _, done in deletions += 1; done([]) }, grace: {})
    cleanup.start()
    defer { cleanup.stop() }
    await cleanup.task?.value
    #expect(deletions == 0)
    #expect(try Data(contentsOf: sentinel) == Data("live data".utf8))
  }
}
