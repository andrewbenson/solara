import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingReaderTests: XCTestCase {
  func testReaderAcceptsSlicedData() throws {
    let payload = Data([0x01, 0x02, 0x00, 0x03, 0x4d, 0x61, 0x63, 0xff])
    let slice = (Data([0xab]) + payload).dropFirst()
    XCTAssertEqual(slice.startIndex, 1)
    var reader = PairingFormat.Reader(data: slice)
    XCTAssertEqual(try reader.integer(2), 0x0102)
    XCTAssertEqual(try reader.string(), "Mac")
    XCTAssertThrowsError(try reader.finish())
    XCTAssertThrowsError(try reader.read(-1))
    XCTAssertThrowsError(try reader.read(2))
    XCTAssertEqual(try reader.read(1), Data([0xff]))
    XCTAssertEqual(try reader.read(0), Data())
    XCTAssertEqual(reader.offset, payload.count)
    try reader.finish()
    XCTAssertThrowsError(try reader.read(1))
  }

  func testUnpadAcceptsSlicedData() throws {
    let payload = Data([1, 2, 3])
    let plain = try PairingCrypto.padded(payload, count: 256)
    let slice = (Data([0xab]) + plain).dropFirst()
    XCTAssertEqual(slice.startIndex, 1)
    XCTAssertEqual(try PairingCrypto.unpad(slice, count: 256), payload)
    var changed = Data([0xab]) + plain
    changed[changed.count - 1] = 1
    XCTAssertThrowsError(try PairingCrypto.unpad(changed.dropFirst(), count: 256)) { error in
      XCTAssertEqual(error as? PairingFormat.Failure, .format)
    }
  }
}
