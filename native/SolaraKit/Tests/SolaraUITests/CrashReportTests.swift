import Foundation
import Testing
@testable import SolaraUI

struct CrashReportTests {
  static let bundleId = "network.benson.solara"
  static let home = "/Users/fixture-person"

  static func ips(bundleId: String = bundleId, frames: Int = 20, faulting: Int = 1, bugType: String = "309") -> Data {
    let header: [String: Any] = [
      "app_name": "Solara", "timestamp": "2026-11-19 09:15:02.00 -0800", "app_version": "0.4.5", "build_version": "107",
      "bug_type": bugType, "bundleID": bundleId, "name": "Solara", "os_version": "macOS 26.6.2 (25G90)",
      "incident_id": "11111111-2222-3333-4444-555555555555",
    ]
    let crashedFrames: [[String: Any]] = (0..<frames).map { index in
      switch index {
      case 0: ["imageOffset": 4096, "imageIndex": 1, "symbol": "objc_msgSend", "symbolLocation": 32]
      case 1: ["imageOffset": 8192, "imageIndex": 0, "symbol": "closure #1 in NativeThing.load(from:) https://private.example/secret?token=1", "symbolLocation": 12]
      case 2: ["imageOffset": 12288, "imageIndex": 0]
      default: ["imageOffset": 16384 + index, "imageIndex": 0, "symbol": "frame\(index)", "symbolLocation": index]
      }
    }
    let body: [String: Any] = [
      "procPath": "\(home)/Applications/Solara.app/Contents/MacOS/Solara",
      "procName": "Solara",
      "bundleInfo": ["CFBundleShortVersionString": "0.4.5", "CFBundleVersion": "107", "CFBundleIdentifier": bundleId],
      "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000010"],
      "asi": ["CoreFoundation": ["*** Terminating app: page https://bank.example/account titled My Bank Statement"]],
      "faultingThread": faulting,
      "threads": [
        ["id": 1, "queue": "com.apple.root.default-qos", "frames": [["imageOffset": 1, "imageIndex": 1, "symbol": "otherThreadFrame"]]],
        ["id": 2, "triggered": true, "queue": "com.apple.main-thread", "name": "My Bank Statement — https://bank.example", "frames": crashedFrames],
      ],
      "usedImages": [
        ["name": "Solara", "path": "\(home)/Applications/Solara.app/Contents/MacOS/Solara", "uuid": "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", "CFBundleShortVersionString": "0.4.5", "CFBundleVersion": "107"],
        ["name": "libobjc.A.dylib", "path": "/usr/lib/libobjc.A.dylib", "uuid": "FFFFFFFF-0000-1111-2222-333333333333"],
      ],
      "vmSummary": "ReadOnly portion of Libraries: Total=1.0G \(home)/Library/Caches/whatever",
    ]
    var data = try! JSONSerialization.data(withJSONObject: header)
    data.append(UInt8(ascii: "\n"))
    data.append(try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]))
    return data
  }

  @Test func theSummaryHasTheExceptionQueueTopFramesAndBinary() throws {
    let summary = try #require(CrashReport.summary(Self.ips(), bundleId: Self.bundleId, home: Self.home))
    #expect(summary.exceptionType == "EXC_BAD_ACCESS")
    #expect(summary.signal == "SIGSEGV")
    #expect(summary.queue == "com.apple.main-thread")
    #expect(summary.binary == "Solara")
    #expect(summary.uuid == "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    #expect(summary.version == "0.4.5 (107)")
    #expect(summary.frames.count == CrashReport.frameLimit)
    #expect(summary.frames[0] == "0  libobjc.A.dylib  objc_msgSend + 32")
    #expect(summary.frames[2] == "2  Solara  0x3000")
    #expect(summary.frames[14] == "14  Solara  frame14 + 14")
    #expect(summary.text.hasPrefix("Exception: EXC_BAD_ACCESS (SIGSEGV)\nQueue: com.apple.main-thread\nBinary: Solara 0.4.5 (107) UUID 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9\nCrashed thread:\n0  libobjc"))
  }

  @Test func nothingButFramesAndTheirLabelsGetsIn() throws {
    let text = try #require(CrashReport.summary(Self.ips(), bundleId: Self.bundleId, home: Self.home)).text
    for leak in ["bank.example", "My Bank Statement", "private.example", "token=1", "://", Self.home, "fixture-person", "Terminating", "KERN_INVALID_ADDRESS", "otherThreadFrame", "vmSummary", "Caches"] {
      #expect(!text.contains(leak), "\(leak)")
    }
    #expect(text.contains("closure #1 in NativeThing.load(from:) <url>"))
  }

  @Test func theHomeFolderBecomesATilde() {
    #expect(CrashReport.sanitize("\(Self.home)/Library/x.dylib", home: Self.home) == "~/Library/x.dylib")
    #expect(CrashReport.sanitize("a\nb\u{0}c", home: Self.home) == "a bc")
    #expect(CrashReport.sanitize("/", home: "/") == "/")
  }

  @Test func theTriggeredThreadIsUsedWhenTheFaultingIndexIsMissing() throws {
    let summary = try #require(CrashReport.summary(Self.ips(faulting: 9), bundleId: Self.bundleId, home: Self.home))
    #expect(summary.queue == "com.apple.main-thread")
  }

  @Test func aResourceDiagnosticOrAReportWithoutACrashIsNotACrash() {
    #expect(!CrashReport.isOurCrash(Self.ips(bugType: "202"), bundleId: Self.bundleId))
    #expect(CrashReport.summary(Self.ips(bugType: "145"), bundleId: Self.bundleId, home: Self.home) == nil)
    #expect(CrashReport.summary(Self.ips(frames: 0), bundleId: Self.bundleId, home: Self.home) == nil)
    #expect(CrashReport.isOurCrash(Self.ips(), bundleId: Self.bundleId))
  }

  @Test func anotherAppsOrAHelpersReportIsNotOurs() {
    #expect(CrashReport.summary(Self.ips(bundleId: "network.benson.solara.helper.renderer"), bundleId: Self.bundleId, home: Self.home) == nil)
    #expect(CrashReport.summary(Self.ips(), bundleId: "", home: Self.home) == nil)
    #expect(CrashReport.summary(Data("not json\n{}".utf8), bundleId: Self.bundleId, home: Self.home) == nil)
    #expect(!CrashReport.isOurs(Data(), bundleId: Self.bundleId))
  }

  @Test func theScanFindsTheNewestOfOurReportsAfterTheMark() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("crash-scan-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    func write(_ name: String, _ data: Data, at time: Double) throws {
      let url = dir.appendingPathComponent(name)
      try data.write(to: url)
      try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
    }
    try write("Solara-2026-11-18-100000.ips", Self.ips(), at: 1000)
    try write("Solara-2026-11-19-100000.ips", Self.ips(), at: 3000)
    try write("Solara Helper (Renderer)-2026-11-19-110000.ips", Self.ips(bundleId: "network.benson.solara.helper"), at: 4000)
    try write("Mail-2026-11-19-110000.ips", Self.ips(bundleId: "com.apple.mail"), at: 5000)
    try write("Solara-2026-11-19-120000.txt", Self.ips(), at: 6000)
    try write("Solara_2026-11-19-113000_Mac.cpu_resource.diag.ips", Self.ips(bugType: "202"), at: 3500)

    let first = CrashReport.scan(directory: dir, executable: "Solara", bundleId: Self.bundleId, after: 2000, fileManager: fm)
    #expect(first.report?.lastPathComponent == "Solara-2026-11-19-100000.ips")
    #expect(first.mark == 4000)
    let onlyResource = CrashReport.scan(directory: dir, executable: "Solara", bundleId: Self.bundleId, after: 3200, fileManager: fm)
    #expect(onlyResource.report == nil)
    #expect(onlyResource.mark == 4000)
    let again = CrashReport.scan(directory: dir, executable: "Solara", bundleId: Self.bundleId, after: first.mark, fileManager: fm)
    #expect(again.report == nil)
    #expect(again.mark == 4000)
    let none = CrashReport.scan(directory: dir.appendingPathComponent("missing"), executable: "Solara", bundleId: Self.bundleId, after: 7, fileManager: fm)
    #expect(none == CrashReportScan(report: nil, mark: 7))
  }

  @Test func theSummaryFitsTheLinkWithTheRestOfTheForm() throws {
    let text = try #require(CrashReport.summary(Self.ips(), bundleId: Self.bundleId, home: Self.home)).text
    let url = try #require(BugReport.url(BugReportTests.facts, crash: text))
    #expect(BugReportTests.query(url)["crash"] == text)
    #expect(url.utf8.count < BugReport.urlLimit)
  }
}
