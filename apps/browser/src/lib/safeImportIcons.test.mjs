import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { declaration, source } from "../test-native/safe-host/run.mjs";

function icons() {
  const directory = mkdtempSync(join(tmpdir(), "solara-safe-import-icons-"));
  try {
    const appIcons = source("packages/import/ios/Core/AppIcons.swift").replace("import AppKit", "");
    const importer = declaration(source("packages/import/ios/ImportModule.swift"), "private let importer: Importer = {");
    const consumer = source("native/SolaraKit/Sources/SolaraUI/Import/ImportComponents.swift");
    const imageLoader = declaration(consumer, "static func image(at path:");
    const program = `${directory}/main.swift`;
    const binary = `${directory}/test`;
    writeFileSync(program, `
import Foundation
import CoreGraphics

let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pngFixture = Data("png fixture".utf8)
let app = fixture.appendingPathComponent("Browser.app", isDirectory: true)

enum SolaraCoreHost { static var safeMode = false }
final class FileManager {
  static let \`default\` = FileManager()
  private let manager = Foundation.FileManager.default
  func urls(for directory: Foundation.FileManager.SearchPathDirectory, in domain: Foundation.FileManager.SearchPathDomainMask) -> [URL] {
    [fixture.appendingPathComponent(directory == .cachesDirectory ? "caches" : "support", isDirectory: true)]
  }
  func fileExists(atPath path: String) -> Bool { manager.fileExists(atPath: path) }
  func createDirectory(at directory: URL, withIntermediateDirectories: Bool) throws {
    try manager.createDirectory(at: directory, withIntermediateDirectories: withIntermediateDirectories)
  }
  func contentsOfDirectory(atPath path: String) throws -> [String] { try manager.contentsOfDirectory(atPath: path) }
  func removeItem(at url: URL) throws { try manager.removeItem(at: url) }
}
final class NSImage {
  let data: Data
  init(data: Data) { self.data = data }
  convenience init?(contentsOfFile path: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    self.init(data: data)
  }
  func draw(in rect: NSRect, from: NSRect, operation: Operation, fraction: Double) {}
  enum Operation { case copy }
}
final class NSWorkspace {
  static let shared = NSWorkspace()
  func urlForApplication(withBundleIdentifier: String) -> URL? { app }
  func icon(forFile: String) -> NSImage { NSImage(data: pngFixture) }
}
final class NSBitmapImageRep {
  enum ColorSpace { case deviceRGB }
  enum Format { case png }
  var size = NSSize.zero
  init?(bitmapDataPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, pixelsWide: Int, pixelsHigh: Int, bitsPerSample: Int, samplesPerPixel: Int, hasAlpha: Bool, isPlanar: Bool, colorSpaceName: ColorSpace, bytesPerRow: Int, bitsPerPixel: Int) {}
  func representation(using format: Format, properties: [String: String]) -> Data? { pngFixture }
}
final class NSGraphicsContext {
  static var current: NSGraphicsContext?
  init(bitmapImageRep: NSBitmapImageRep) {}
  static func saveGraphicsState() {}
  static func restoreGraphicsState() {}
}
struct BrowserDiscovery {
  let applicationSupport: URL
  let locateApp: ([String]) -> URL?
  let iconFor: (URL, String) -> String?
}
struct Importer { let discovery: BrowserDiscovery }
struct ImportFileIcon {
${imageLoader}
}
${appIcons}
struct ImportModule {
${importer}()
  func icon() -> String? { importer.discovery.iconFor(app, "fixture") }
}

try Foundation.FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
let cache = fixture.appendingPathComponent("caches/Solara/ImportIcons", isDirectory: true)
try Foundation.FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
let old = cache.appendingPathComponent("fixture-old.png")
let other = cache.appendingPathComponent("another-old.png")
try Data("old icon".utf8).write(to: old)
try Data("another icon".utf8).write(to: other)
var rows: [[String: Any]] = []
for safe in [true, false, true] {
  SolaraCoreHost.safeMode = safe
  let value = ImportModule().icon()
  let image = ImportFileIcon.image(at: value)
  let files = try Foundation.FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
  rows.append([
    "safe": safe,
    "uri": value ?? "",
    "image": image.map { String(decoding: $0.data, as: UTF8.self) } ?? "",
    "files": files,
    "old": (try? String(contentsOf: old, encoding: .utf8)) ?? "",
    "other": (try? String(contentsOf: other, encoding: .utf8)) ?? "",
    "cached": files.filter { $0.hasPrefix("fixture-") }.compactMap { try? String(contentsOf: cache.appendingPathComponent($0), encoding: .utf8) }
  ])
}
let absent = fixture.appendingPathComponent("absent-cache", isDirectory: true)
SolaraCoreHost.safeMode = true
let fresh = AppIcons.png(for: app, id: "fresh", directory: absent, safeMode: true)
let result: [String: Any] = ["rows": rows, "absentCreated": Foundation.FileManager.default.fileExists(atPath: absent.path), "fresh": fresh ?? ""]
let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: output, as: UTF8.self))
`);
    const env = { ...process.env, TMPDIR: directory, CLANG_MODULE_CACHE_PATH: `${directory}/cache`, SWIFT_MODULECACHE_PATH: `${directory}/cache` };
    execFileSync("/usr/bin/swiftc", ["-module-cache-path", `${directory}/cache`, program, "-o", binary], { env, stdio: "pipe", timeout: 300000 });
    return JSON.parse(execFileSync(binary, [directory], { env, encoding: "utf8", timeout: 10000 }));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("opening the import chooser renders icons in memory without changing caches in safe mode; normal mode replaces old cache entries", () => {
  const result = icons();
  const [safe, normal, warm] = result.rows;
  assert.equal(safe.safe, true);
  assert.equal(safe.uri, "data:image/png;base64,cG5nIGZpeHR1cmU=");
  assert.equal(safe.image, "png fixture");
  assert.deepEqual(safe.files, ["another-old.png", "fixture-old.png"]);
  assert.equal(safe.old, "old icon");
  assert.equal(safe.other, "another icon");
  assert.equal(normal.safe, false);
  assert.match(normal.uri, /\/fixture-\d+\.png$/);
  assert.equal(normal.image, "png fixture");
  assert.equal(normal.files.length, 2);
  assert.equal(normal.files.includes("fixture-old.png"), false);
  assert.equal(normal.old, "");
  assert.equal(normal.other, "another icon");
  assert.deepEqual(normal.cached, ["png fixture"]);
  assert.equal(warm.safe, true);
  assert.equal(warm.uri, "data:image/png;base64,cG5nIGZpeHR1cmU=");
  assert.equal(warm.image, "png fixture");
  assert.deepEqual(warm.files, normal.files);
  assert.deepEqual(warm.cached, normal.cached);
  assert.equal(result.absentCreated, false);
  assert.equal(result.fresh, "data:image/png;base64,cG5nIGZpeHR1cmU=");
});
