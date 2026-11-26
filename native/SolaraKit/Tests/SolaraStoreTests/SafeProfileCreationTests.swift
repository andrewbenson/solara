import SolaraModel
import SolaraStore
import Testing

@Suite struct SafeProfileCreationTests {
  @Test func safeCreationRefusesBeforeIdsStateOrEffectsChange() throws {
    var config = StoreConfig()
    config.safeMode = true
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), config: config, checksInvariants: true)
    let before = store.state
    let ids = store.memory.ids
    do {
      try store.dispatch(SettingsWrites.createProfile(name: "Refused", color: "blue", shareWith: "default"), origin: .native)
      Issue.record("Safe profile creation reported success")
    } catch let error as CommandError {
      #expect(error.description.contains("safe mode"))
    }
    do {
      try store.transact { session in
        _ = try session.createProfile(name: "Refused direct", color: nil, icon: nil, shareWith: nil)
      }
      Issue.record("Safe direct profile creation reported success")
    } catch let error as CommandError {
      #expect(error.description.contains("safe mode"))
    }
    #expect(store.state == before)
    #expect(store.memory.ids == ids)
    #expect(store.rev == 0)
  }
}
