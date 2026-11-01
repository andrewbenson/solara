import Foundation

enum Settings {
  static let defaultProfileID = "default"
}

enum ProfileDataCleanup {
  __PRODUCTION__
}

let results = CommandLine.arguments.dropFirst().map(ProfileDataCleanup.validProfileId)
let data = try JSONSerialization.data(withJSONObject: results)
print(String(data: data, encoding: .utf8)!)
