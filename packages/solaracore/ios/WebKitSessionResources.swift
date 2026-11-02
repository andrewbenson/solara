import Foundation

struct WebKitResourceGeneration: Equatable {
  let session: Data
  let token: Data

  init(session: String, token: String) {
    self.session = Data(session.utf8)
    self.token = Data(token.utf8)
  }
}

struct WebKitSessionResources<Resource> {
  private struct Entry {
    let resource: Resource
    let generation: WebKitResourceGeneration?
  }

  private var entries: [Data: Entry] = [:]

  var count: Int { entries.count }
  var values: [Resource] { entries.values.map(\.resource) }

  subscript(_ id: String) -> Resource? { entries[Data(id.utf8)]?.resource }

  mutating func insert(_ resource: Resource, id: String, generation: WebKitResourceGeneration?) {
    entries[Data(id.utf8)] = Entry(resource: resource, generation: generation)
  }

  mutating func removeValue(forKey id: String) -> Resource? {
    entries.removeValue(forKey: Data(id.utf8))?.resource
  }

  mutating func removeAll() { entries.removeAll() }

  mutating func removePrivateSession(_ generation: WebKitResourceGeneration) -> [Resource] {
    let keys = entries.filter { $0.value.generation == generation }.map(\.key)
    return keys.compactMap { entries.removeValue(forKey: $0)?.resource }
  }
}

class WebKitDownloadPayload {
  var url: String
  var profile: String
  var destination: ((URL?) -> Void)?
  var request: URLRequest?
  var filename = ""
  var path = ""
  var final: URL?
  var mimeType = ""
  var resumeData: Data?

  init(url: String, profile: String) {
    self.url = url
    self.profile = profile
  }

  func retire() {
    let destination = self.destination
    self.destination = nil
    request = nil
    resumeData = nil
    url = ""
    profile = ""
    filename = ""
    path = ""
    final = nil
    mimeType = ""
    destination?(nil)
  }
}

struct WebKitStoreGenerations {
  private var generations: [Data: String] = [:]

  mutating func begin(session: String, generation: String) { generations[Data(session.utf8)] = generation }
  mutating func end(session: String) { generations.removeValue(forKey: Data(session.utf8)) }
  mutating func removeAll() { generations.removeAll() }
  func generation(session: String) -> String? { generations[Data(session.utf8)] }
}
