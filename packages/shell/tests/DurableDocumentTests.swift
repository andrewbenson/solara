import Darwin
import Foundation
import XCTest
@testable import SolaraShellCore

final class DurableDocumentTests: XCTestCase {
  func testAtomicReplacementLeavesNoTemporaryFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("history.json")
    try Data("original".utf8).write(to: file)
    let contents = String(repeating: "replacement", count: 100_000)
    try DurableDocument.write(contents, to: file)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["history.json"])
  }

  func testFailedReplacementPreservesSourceAndCleansTemporaryFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = folder.appendingPathComponent("history.json")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = destination.appendingPathComponent("source")
    try Data("original".utf8).write(to: source)
    XCTAssertThrowsError(try DurableDocument.write("replacement", to: destination))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["history.json"])
  }

  func testInjectedWriteFailurePreservesOriginalBytes() throws {
    try assertPreservedAfterFailure(DurableDocument.Operations(
      write: { _, _, _ in
        errno = EIO
        return -1
      },
      fileBarrier: DurableDocument.Operations.standard.fileBarrier,
      directoryBarrier: DurableDocument.Operations.standard.directoryBarrier))
  }

  func testInjectedFileBarrierFailurePreservesOriginalBytes() throws {
    try assertPreservedAfterFailure(DurableDocument.Operations(
      write: DurableDocument.Operations.standard.write,
      fileBarrier: { _ in throw POSIXError(.EIO) },
      directoryBarrier: DurableDocument.Operations.standard.directoryBarrier))
  }

  func testInjectedDirectoryBarrierFailureKeepsCompleteReplacement() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("history.json")
    try Data("original".utf8).write(to: file)
    let operations = DurableDocument.Operations(
      write: DurableDocument.Operations.standard.write,
      fileBarrier: DurableDocument.Operations.standard.fileBarrier,
      directoryBarrier: { _ in throw POSIXError(.EIO) })
    XCTAssertThrowsError(try DurableDocument.write("replacement", to: file, operations: operations))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "replacement")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["history.json"])
  }

  private func assertPreservedAfterFailure(_ operations: DurableDocument.Operations) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("history.json")
    try Data("original".utf8).write(to: file)
    XCTAssertThrowsError(try DurableDocument.write("replacement", to: file, operations: operations))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["history.json"])
  }
}
