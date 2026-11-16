import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct ProfileIconPersistenceTests {
  @Test(arguments: ["symbol:briefcase.fill", "🍌", "symbol:future.symbol.fill"])
  func iconAndResetSurviveDatabaseAndSessionWrites(_ icon: String) throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze(); try? launch.database.close() }
    let id = try #require(try store.dispatch(Command("createProfile", [["name": "Work", "icon": .string(icon)]])).result?.string)
    for value in [JSONValue.string(icon), .null] {
      try store.dispatch(Command("updateProfile", [.string(id), ["icon": value]]))
      writer.markShadowDirty()
      #expect(writer.flush(timeout: 5) == .saved)
      let database = try #require(try launch.database.load().sessionJSON())
      let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
      for document in [database, shadow] {
        let profile = try #require(document["profiles"]?[id])
        #expect(profile["icon"] == value)
      }
      let reopened = try open(folder)
      #expect(reopened.state.profiles[id]?.json["icon"] == value)
      try reopened.database.close()
    }
    #expect(writer.errors.isEmpty)
  }
}
