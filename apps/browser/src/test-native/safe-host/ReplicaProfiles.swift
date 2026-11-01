import Foundation
import Darwin

struct CommandError: Error {
  let description: String
  init(_ description: String) { self.description = description }
}
struct Profile: Equatable {
  var id: String
  var dataId: String?
  var name = "Saved"
}
func dataIdOf(_ profile: Profile) -> String { profile.dataId ?? profile.id }
extension String {
  func jsEquals(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }
}
enum ProfileDataCleanup {
  static func validProfileId(_ id: String) -> Bool {
    id == "default" || id.range(of: "^p-[a-z0-9]+-[1-9a-z][a-z0-9]*$", options: .regularExpression) != nil
  }
}
enum Value {
  case profiles([String: Profile]), order([String]), bool(Bool)
  var truthy: Bool { if case .bool(let value) = self { value } else { false } }
  subscript(_ key: String) -> Value? { nil }
}
typealias JSONObject = [String: Value]
struct Config {
  var replicaProfilesFromDisk = true
}
struct Memory {
  var replicaProfilesAttached = false
  var fromSyncDepth = 0
}
struct State: Equatable {
  var profiles: [String: Profile] = [:]
  var profileOrder: [String] = []
  mutating func applySlice(_ name: String, _ value: Value) throws {
    switch (name, value) {
    case ("profiles", .profiles(let profiles)): self.profiles = profiles
    case ("profileOrder", .order(let order)): profileOrder = order
    default: throw CommandError("bad slice")
    }
  }
}
struct Args {
  let data: JSONObject
  func object(_ index: Int) -> JSONObject { data }
  subscript(_ index: Int) -> Value? { nil }
}
final class Fixture {
  var config = Config()
  var memory = Memory()
  var fromSyncOrigin = false
  var state = State()
  func refusePendingProfileData(_ next: State) throws {
    if next.profiles["pending"] != nil { throw CommandError("pending deletion") }
  }
  func set(_ next: State) { state = next }
}
extension Fixture {
__PRODUCTION__
}
func refused(_ run: () throws -> Void) -> Bool {
  do { try run(); return false } catch { return true }
}
func payload(_ profiles: [Profile]) -> JSONObject {
  ["profiles": .profiles(Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })), "profileOrder": .order(profiles.map(\.id))]
}
let stderr = Pipe()
let originalStderr = dup(STDERR_FILENO)
dup2(stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
let saved = Profile(id: "Saved-MixedCase", dataId: "Saved-Data")
let first = Fixture()
try first.apply("attachReplicaProfiles", payload([saved]))
var results = [first.state.profiles[saved.id] == saved, first.memory.replicaProfilesAttached]
results.append(!refused { try first.apply("attachReplicaProfiles", payload([saved])) })
var renamed = saved
renamed.name = "Renamed"
try? first.apply("attachReplicaProfiles", payload([renamed]))
results.append(first.state.profiles[saved.id]?.name == "Renamed")
let generated = Profile(id: "p-generated-1", dataId: "p-data-1")
let fresh = Profile(id: "New-OffShape", dataId: "New-Data")
try? first.apply("attachReplicaProfiles", payload([saved, fresh, generated]))
results.append(first.state.profiles[fresh.id] == nil)
results.append(first.state.profiles[generated.id] == generated)
results.append(first.state.profileOrder == [saved.id, generated.id])
for changed in [Profile(id: saved.id, dataId: "saved-data"), Profile(id: "saved-MixedCase", dataId: saved.dataId)] {
  let reload = Fixture()
  try reload.apply("attachReplicaProfiles", payload([saved]))
  try? reload.apply("attachReplicaProfiles", payload([changed, generated]))
  results.append(reload.state.profiles[changed.id] == nil && reload.state.profiles[generated.id] == generated)
}
let nfc = Profile(id: "Sav\u{e9}d", dataId: "Dat\u{e9}")
let nfd = Profile(id: "Save\u{301}d", dataId: "Date\u{301}")
let canonical = Fixture()
try canonical.apply("attachReplicaProfiles", payload([nfc]))
try? canonical.apply("attachReplicaProfiles", payload([nfd]))
results.append(canonical.state.profiles.isEmpty)
let dataCanonical = Fixture()
let canonicalData = Profile(id: "Saved-MixedCase", dataId: "Dat\u{e9}")
try dataCanonical.apply("attachReplicaProfiles", payload([canonicalData]))
try? dataCanonical.apply("attachReplicaProfiles", payload([Profile(id: "Saved-MixedCase", dataId: "Date\u{301}")]))
results.append(dataCanonical.state.profiles.isEmpty)
for (stored, incoming) in [(nil, Optional("Saved-MixedCase")), (Optional("Saved-MixedCase"), nil)] {
  let optionalData = Fixture()
  try optionalData.apply("attachReplicaProfiles", payload([Profile(id: "Saved-MixedCase", dataId: stored)]))
  try? optionalData.apply("attachReplicaProfiles", payload([Profile(id: "Saved-MixedCase", dataId: incoming)]))
  results.append(optionalData.state.profiles.isEmpty)
}
let fullNative = Fixture()
fullNative.config.replicaProfilesFromDisk = false
results.append(refused { try fullNative.apply("attachReplicaProfiles", payload([saved])) })
let sync = Fixture()
results.append(refused { try sync.dispatch("attachReplicaProfiles", payload([saved]), fromSync: true) })
let syncOrigin = Fixture()
results.append(refused { try syncOrigin.dispatch("attachReplicaProfiles", payload([saved]), originSync: true) })
let pending = Fixture()
results.append(refused { try pending.apply("attachReplicaProfiles", payload([Profile(id: "pending")])) })
results.append(pending.state.profiles.isEmpty && !pending.memory.replicaProfilesAttached)
let malformed = Fixture()
results.append(refused { try malformed.apply("attachReplicaProfiles", ["profiles": .profiles([:])]) })
let validReload = Fixture()
try validReload.apply("attachReplicaProfiles", payload([generated]))
results.append(!refused { try validReload.apply("attachReplicaProfiles", payload([generated])) })
dup2(originalStderr, STDERR_FILENO)
close(originalStderr)
try stderr.fileHandleForWriting.close()
let messages = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
results.append(messages.contains("New-OffShape") && messages.contains("saved-data"))
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
