import Foundation

__PRODUCTION__

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!, isDirectory: true)
let actual = root.appendingPathComponent("actual", isDirectory: true)
let other = root.appendingPathComponent("other", isDirectory: true)
let alias = root.appendingPathComponent("alias", isDirectory: true)
try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
let identity = try ChromiumProfileData.directoryIdentity(actual)
var results: [[String: Bool]] = [[
  "resolvedAlias": try ChromiumProfileData.directoryIdentity(alias) == identity,
  "distinct": try ChromiumProfileData.directoryIdentity(other) != identity,
  "absent": try ChromiumProfileData.directoryIdentity(root.appendingPathComponent("absent")) == nil,
  "refusesAlias": !ChromiumProfileData.deletionAllowed(targets: [alias], liveDirectories: [actual]),
  "allowsSeparate": ChromiumProfileData.deletionAllowed(targets: [other], liveDirectories: [actual]),
  "refusesError": !ChromiumProfileData.deletionAllowed(targets: [actual], liveDirectories: [other], resolve: { _ in throw CocoaError(.fileReadNoPermission) }),
]]
for (live, queued) in [("FOO", "foo"), ("foo", "FOO")] {
  let livePath = root.appendingPathComponent("Profile \(live)")
  let target = root.appendingPathComponent("Profile \(queued)")
  let webkit = root.appendingPathComponent("WebKit/live")
  let shared = ChromiumProfileData.DirectoryIdentity(device: 7, inode: 9)
  let separate = ChromiumProfileData.DirectoryIdentity(device: 7, inode: 10)
  for livePath in [livePath, webkit] {
    let refused = !ChromiumProfileData.deletionAllowed(targets: [target], liveDirectories: [livePath], resolve: { _ in shared })
    let allowed = ChromiumProfileData.deletionAllowed(targets: [target], liveDirectories: [livePath], resolve: { $0.path == target.path ? shared : separate })
    results.append(["refusesShared": refused, "allowsDistinct": allowed])
  }
}
for diskID in ["FOO", "foo"] {
  let disk = root.appendingPathComponent("Profile \(diskID)", isDirectory: true)
  try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
  let sentinel = disk.appendingPathComponent("sentinel")
  try Data("untouched".utf8).write(to: sentinel)
  let live = root.appendingPathComponent("Profile FOO", isDirectory: true)
  let queued = root.appendingPathComponent("Profile foo", isDirectory: true)
  let aliases = FileManager.default.fileExists(atPath: live.path) && FileManager.default.fileExists(atPath: queued.path)
  let allowed = ChromiumProfileData.deletionAllowed(targets: [queued], liveDirectories: [live])
  if allowed && aliases { try FileManager.default.removeItem(at: queued) }
  results.append(["keepsLiveSentinel": try Data(contentsOf: sentinel) == Data("untouched".utf8), "refusesRealCaseAlias": !aliases || !allowed])
  try FileManager.default.removeItem(at: disk)
}
let output = try JSONSerialization.data(withJSONObject: results)
print(String(data: output, encoding: .utf8)!)
