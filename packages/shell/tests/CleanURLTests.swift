import XCTest
@testable import SolaraShellCore

final class CleanURLTests: XCTestCase {
  struct Vectors: Decodable {
    let cases: [[String]]
  }

  func testEveryCaseTheTypeScriptCleanerAgreesOn() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../core/src/cleanUrl.vectors.json").standardizedFileURL
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    XCTAssertGreaterThan(vectors.cases.count, 150)
    for pair in vectors.cases {
      XCTAssertEqual(CleanURL.clean(pair[0]), pair[1], pair[0])
    }
  }

  func testLineBreaksLeaveTheTextAlone() {
    XCTAssertEqual(CleanURL.clean("https://example.com/?a=1\n&utm_source=x"), "https://example.com/?a=1\n&utm_source=x")
  }
}
