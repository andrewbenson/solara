import { test } from "node:test";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const source = readFileSync(new URL("../ios/SolaraCoreProfileData.swift", import.meta.url), "utf8").split("private final class ProfileDataDeletionResult")[0];
const stubs = `
import Foundation
struct SolaraCoreHost {
  static let safeMode = false
  static let dataDirectory = "/unused"
  static func deleteProfileData(_ p: String, deletionAllowed: @escaping () -> Bool, completion: @escaping ([String]) -> Void) { completion([]) }
}
struct ChromiumProfileData {
  static func delete(_ p: String, profilesDirectory: URL, deleteDefault: (@escaping ([String]) -> Void) -> Void, deleteNamed: (String, @escaping ([String]) -> Void) -> Void, completion: @escaping ([String]) -> Void) { deleteDefault(completion) }
}
struct SolaraCoreServices {
  static var denyDisable = false
  static var enabled = true
  static var live = true
  static var durable = true
  static var deep = false
  static var pending: (([String: Any]) -> Void)?
  static var clearCalls = 0
  static func tree() -> [String: Any] {
    if deep { return ["error": "bookmarks nested too deep"] }
    let children: [[String: Any]] = live ? [["id": "fixture"]] : []
    return ["bar": ["k": "f", "c": children], "other": ["k": "f", "c": []]]
  }
  static func call(_ name: String, profile: String, args: [String: Any]?, completion: @escaping ([String: Any]) -> Void) {
    switch name {
    case "ac_bookmarks_tree": completion(tree())
    case "ac_bookmarks_apply": live = false; completion(["applied": (args?["ops"] as? [Any])?.count ?? 0, "skipped": 0, "invalid": [String]()])
    case "ac_bookmarks_clear":
      clearCalls += 1
      live = false
      pending = completion
    default: completion(["ok": true])
    }
  }
  static func commit(_ success: Bool) {
    let callback = pending; pending = nil
    if success { durable = live }
    callback?(["ok": success])
  }
  static func clearBrowsingData(profile: String, types: [String], since: Int, completion: @escaping () -> Void) { if enabled { live = true }; completion() }
  static func listExtensions(profile: String, completion: ([String: Any]) -> Void) { completion(["extensions": enabled ? [["id": "writer", "enabled": true, "mayModify": true]] : []]) }
  static func setExtension(_ id: String, enabled value: Bool, profile: String, completion: ([String: Any]) -> Void) { if !denyDisable { enabled = value }; completion(["ok": !denyDisable]) }
  static func addresses(profile: String, completion: ([String: Any]) -> Void) { completion(["addresses": []]) }
  static func cards(profile: String, completion: ([String: Any]) -> Void) { completion(["cards": []]) }
  static func deleteAutofillEntry(_ id: String, profile: String, completion: ([String: Any]) -> Void) { completion([:]) }
  static func listPasswords(profile: String, completion: ([String: Any]) -> Void) { completion(["passwords": []]) }
  static func neverSaveOrigins(profile: String, completion: ([String: Any]) -> Void) { completion(["origins": [String]()]) }
  static func allowSaving(profile: String, origin: String, completion: ([String: Any]) -> Void) { completion([:]) }
  static func deletePassword(profile: String, origin: String, username: String, completion: ([String: Any]) -> Void) { completion([:]) }
  static func siteSettingsOrigins(profile: String, completion: ([String]) -> Void) { completion([]) }
  static func zoomLevels(profile: String, completion: ([String: Double]) -> Void) { completion([:]) }
  static func setZoom(_ value: Double, profile: String, host: String) {}
}
`;
function run(body) {
  const dir = mkdtempSync(join(tmpdir(), "solara-default-regression-"));
  try {
    const swift = join(dir, "main.swift"), binary = join(dir, "check");
    writeFileSync(swift, source + stubs + body);
    execFileSync("swiftc", [swift, "-o", binary], { timeout: 60000 });
    execFileSync(binary, [], { timeout: 10000 });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
test("Default acknowledgement waits for actual storage completion and failed commits retain the obligation", () => run(`
SolaraCoreServices.enabled = false
var result: [String]?
SolaraCoreProfileData.deleteDefault { result = $0 }
precondition(result == nil)
precondition(SolaraCoreServices.durable)
SolaraCoreServices.commit(false)
while SolaraCoreServices.pending != nil { SolaraCoreServices.commit(false) }
precondition(result?.contains("bookmarks") == true)
`));
test("Default quiesces extension writers before clearing and verifies a final persisted snapshot", () => run(`
var result: [String]?
SolaraCoreProfileData.deleteDefault { result = $0 }
precondition(!SolaraCoreServices.enabled)
precondition(result == nil)
while SolaraCoreServices.pending != nil { SolaraCoreServices.commit(true) }
precondition(result?.isEmpty == true)
precondition(!SolaraCoreServices.live && !SolaraCoreServices.durable)
precondition(SolaraCoreServices.clearCalls == 2)
`));
test("Default cleanup can remove a tree that the depth limited reader rejects", () => run(`
SolaraCoreServices.deep = true
SolaraCoreServices.enabled = false
var result: [String]?
SolaraCoreProfileData.deleteDefault { result = $0 }
while SolaraCoreServices.pending != nil { SolaraCoreServices.commit(true) }
precondition(result?.isEmpty == true)
precondition(!SolaraCoreServices.durable)
`));


test("Default refuses cleanup while extension writers cannot be quiesced", () => run(`
SolaraCoreServices.denyDisable = true
var result: [String]?
SolaraCoreProfileData.deleteDefault { result = $0 }
precondition(result == ["extensions"])
precondition(SolaraCoreServices.live && SolaraCoreServices.durable)
precondition(SolaraCoreServices.clearCalls == 0)
`));
test("Default final storage failure retains the obligation after an earlier committed clear", () => run(`
SolaraCoreServices.enabled = false
var result: [String]?
SolaraCoreProfileData.deleteDefault { result = $0 }
SolaraCoreServices.commit(true)
precondition(result == nil)
precondition(SolaraCoreServices.clearCalls == 2)
SolaraCoreServices.commit(false)
precondition(result == ["bookmarks"])
`));
