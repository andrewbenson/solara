#if DEBUG
import Foundation
@testable import SolaraImportAdapter
import SolaraUI
import SolaraModel
import SolaraStore

@main
@MainActor
struct ImportTransportTests {
  static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let importer = Importer(discovery: BrowserDiscovery(applicationSupport: root, locateApp: { _ in nil }, iconFor: { _, _ in nil }))
    let filters: [Set<String>?] = [nil, [], ["S-PERSONAL"], ["unknown"]]
    for ids in filters {
      let result = try importer.importData(browserId: "arc", profileId: "Default", kinds: [.spaces, .pinnedTabs, .tabs, .favorites], options: ImportOptions(spaceIds: ids))
      let service = ImportService.readValue(result, vaultToken: "token")
      let read = ImportRunEngine.imported(service)
      let actual = try await ImportRunEngine().read(jobId: UUID().uuidString, browserId: "arc", profileId: "Default", kinds: [.spaces, .pinnedTabs, .tabs, .favorites], spaceIds: ids) { _, _ in }
      precondition(actual.spaces == read.spaces)
      precondition(actual.favicons == read.favicons)
      precondition(actual.favorites == read.favorites)

      precondition(service.hasSpaces == !service.spaces.isEmpty)
      precondition(read.hasSpaces == !read.spaces.isEmpty)
      precondition(read.spaces.map(\.id) == (ids == nil ? ["S-PERSONAL", "S-UNTITLED"] : ids == ["S-PERSONAL"] ? ["S-PERSONAL"] : []))
      precondition(read.vaultToken == "token")
      precondition(read.favicons.count == (ids == nil ? 5 : ids == ["S-PERSONAL"] ? 4 : 1))
      for (input, output) in zip(service.spaces, read.spaces) {
        precondition(output.id == input.id && output.name == input.name && output.profileId == input.profileId)
        precondition(output.color == input.color && output.colors == input.colors)
        precondition(output.emoji == input.emoji && output.icon == input.icon && output.theme == input.theme)
        compare(input.pinned, output.pinned)
        precondition(output.tabs.count == input.tabs.count)
        for (tab, row) in zip(input.tabs, output.tabs) {
          precondition(row.url == tab.url && row.title == tab.title && row.pinned == tab.pinned && row.customTitle == tab.customTitle)
        }
      }
    }
    let work = try importer.importData(browserId: "arc", profileId: "Profile 1", kinds: [.spaces, .pinnedTabs], options: ImportOptions(spaceIds: ["S-WORK"]))
    let workRead = ImportRunEngine.imported(ImportService.readValue(work, vaultToken: nil))
    precondition(workRead.spaces.first?.icon == "briefcase")
    precondition(workRead.spaces.first?.theme != nil)
    precondition(workRead.spaces.first?.colors?.count == 2)
    let synthetic = try JSONDecoder().decode(SpaceSuggestion.self, from: Data(#"{"id":"s","name":"Space","profileId":"source","color":"#123456","colors":["#123456","#ABCDEF"],"emoji":"🌱","icon":"leaf","theme":"{}","pinned":[{"type":"folder","title":"Live","role":"liveGitHubPullRequests","children":[{"type":"url","title":"Alias","url":"https://pin.example/","pageTitle":"","dateAdded":123}]}],"tabs":[{"url":"https://open.example/","title":"Open","pinned":false,"customTitle":"Alias","windowIndex":0,"active":false}]}"#.utf8))
    let mapped = ImportRunEngine.space(synthetic)
    precondition(mapped.emoji == "🌱" && mapped.icon == "leaf" && mapped.theme == "{}")
    precondition(mapped.color == "#123456" && mapped.colors == ["#123456", "#ABCDEF"])
    compare(synthetic.pinned, mapped.pinned)
    precondition(mapped.tabs.first?.customTitle == "Alias")
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "import-transport")), checksInvariants: true, clock: { 1_000 })
    let payload = ImportRunEngine.profilePayload(name: "Shared", color: "blue", icon: "🌱", shareWith: "default")
    precondition(payload["icon"]?.string == "🌱" && payload["shareWith"]?.string == "default")
    let id = try store.dispatch(Command("createProfile", [payload])).result!.string!
    precondition(store.state.profiles[id]?.icon == "🌱")
    precondition(store.state.engineProfile(id) == store.state.engineProfile("default"))
    let independentPayload = ImportRunEngine.profilePayload(name: "Independent", color: nil, icon: nil, shareWith: nil)
    precondition(independentPayload["icon"] == nil && independentPayload["shareWith"] == nil && independentPayload["color"] == nil)
    let independent = try store.dispatch(Command("createProfile", [independentPayload])).result!.string!
    precondition(store.state.engineProfile(independent) != store.state.engineProfile("default"))
    print("ok import transport, exact filters, recursive metadata and real profile sharing")
  }

  static func compare(_ inputs: [SolaraImportAdapter.BookmarkNode], _ outputs: [ImportBookmarkNode]) {
    precondition(inputs.count == outputs.count)
    for (input, output) in zip(inputs, outputs) {
      precondition(output.isFolder == (input.type != .url) && output.title == input.title && output.url == input.url)
      precondition(output.dateAdded == input.dateAdded && output.pageTitle == input.pageTitle)
      precondition(output.role == (input.role?.isEmpty == true ? nil : input.role))
      precondition((input.children == nil) == (output.children == nil))
      compare(input.children ?? [], output.children ?? [])
    }
  }
}
#endif
