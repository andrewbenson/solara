import CryptoKit
import Foundation
import XCTest
@testable import SolaraLegacySyncCore

final class PairingTests: XCTestCase {
  typealias F = PairingFormat
  typealias C = PairingCrypto

  func bytes(_ hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else { throw F.Failure.format }
    var result = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let end = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<end], radix: 16) else { throw F.Failure.format }
      result.append(byte)
      index = end
    }
    return result
  }

  func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
  func repeated(_ value: UInt8, _ count: Int = 16) -> Data { Data(repeating: value, count: count) }
  func sequence(_ start: UInt8, _ count: Int) -> Data { Data((0..<count).map { start + UInt8($0) }) }

  let jPrivate = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
  let jPublic = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
  let tPrivate = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
  let tPublic = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
  let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"

  func testRFC7748Section61() throws {
    XCTAssertEqual(try C.publicKey(bytes(jPrivate)), try bytes(jPublic))
    XCTAssertEqual(try C.publicKey(bytes(tPrivate)), try bytes(tPublic))
    XCTAssertEqual(try C.sharedSecret(bytes(jPrivate), bytes(tPublic)), try bytes(shared))
    XCTAssertEqual(try C.sharedSecret(bytes(tPrivate), bytes(jPublic)), try bytes(shared))
  }

  func testRFC5869AppendixA1() throws {
    let prk = C.extract(salt: try bytes("000102030405060708090a0b0c"), ikm: repeated(0x0b, 22))
    XCTAssertEqual(prk, try bytes("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
    let info = try bytes("f0f1f2f3f4f5f6f7f8f9")
    let expected = try bytes("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    XCTAssertEqual(try C.expand(prk: prk, info: info, count: 42), expected)
    XCTAssertEqual(try C.expand(prk: prk, info: info, count: 32), expected.prefix(32))
    XCTAssertThrowsError(try C.expand(prk: prk, info: info, count: 8161))
  }

  func testKeyScheduleRejectsAllZeroSecret() throws {
    let f = try fixture()
    let accepted = try C.keys(secret: bytes(shared), transcript: f.keys.transcript)
    XCTAssertEqual(accepted.transcript, f.keys.transcript)
    for label in C.labels { XCTAssertEqual(try accepted.key(label), try f.keys.key(label)) }
    XCTAssertThrowsError(try C.keys(secret: Data(count: 32), transcript: f.keys.transcript)) {
      XCTAssertEqual($0 as? F.Failure, .authentication)
    }
  }

  func testSASBitsAlphabetAndUnusedBits() throws {
    for (input, expected) in [("00000000", "000000"), ("fffffffc", "ZZZZZZ"), ("00000004", "000001")] {
      for low in 0..<4 {
        var value = try bytes(input)
        value[3] |= UInt8(low)
        XCTAssertEqual(try C.sasBits(value), expected)
      }
    }
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    for (index, char) in alphabet.enumerated() {
      let bits = UInt32(index) << 27 | UInt32(index) << 22 | UInt32(index) << 17 | UInt32(index) << 12 | UInt32(index) << 7 | UInt32(index) << 2
      let input = withUnsafeBytes(of: bits.bigEndian) { Data($0) }
      XCTAssertEqual(try C.sasBits(input), String(repeating: String(char), count: 6))
    }
    XCTAssertThrowsError(try C.sasBits(Data(count: 3)))
  }

  func testEncodingVectorsAndDomainFraming() throws {
    XCTAssertEqual(try F.string("Mac"), try bytes("00034d6163"))
    XCTAssertEqual(F.u64(300000), try bytes("00000000000493e0"))
    XCTAssertEqual(try F.string("é"), try bytes("0002c3a9"))
    XCTAssertEqual(try F.frame("x"), try bytes("0010736f6c6172612d706169722f76322f7800000000"))
    XCTAssertEqual(try F.frame("x", Data()), try bytes("0010736f6c6172612d706169722f76322f780000000100000000"))
    XCTAssertNotEqual(try F.frame("x", Data("ab".utf8), Data("c".utf8)), try F.frame("x", Data("a".utf8), Data("bc".utf8)))
    let header = try F.header(F.Header(type: 1, bodyLength: 0, cid: repeated(0), rid: repeated(1), aid: repeated(0)))
    XCTAssertEqual(header, try bytes("53504a320201000000000000" + String(repeating: "00", count: 16) + String(repeating: "01", count: 16) + String(repeating: "00", count: 16)))
    XCTAssertEqual(header.count, 60)
    XCTAssertThrowsError(try F.string(String(repeating: "a", count: 65536)))
  }

  func testReaderStringsPreserveExactUTF8Bytes() throws {
    for name in ["", "A", "é", "①"] {
      let raw = Data(name.utf8)
      var reader = F.Reader(data: F.integer(UInt64(raw.count), bytes: 2) + raw)
      XCTAssertEqual(Data(try reader.string().utf8), raw)
      try reader.finish()
    }
    for raw in [Data([0xef, 0xbb, 0xbf, 0x41]), Data([0xef, 0xbb, 0xbf]) + Data(String(repeating: "é", count: 63).utf8), Data([0xff])] {
      var reader = F.Reader(data: F.integer(UInt64(raw.count), bytes: 2) + raw)
      XCTAssertThrowsError(try reader.string(), "rawBytes=\(raw.count)")
    }
  }

  struct Fixture {
    var request: Data
    var offer: Data
    var select: Data
    var reveal: Data
    var confirm: Data
    var joiningName: Data
    var trustedName: Data
    var approval: Data
    var receipt: Data
    var joiningTerminal: Data
    var trustedTerminal: Data
    var cid: Data
    var keys: C.Keys
    var values: [String: String]
  }

  func fixture(jName: String = "Andrew’s MacBook Pro", tName: String = "Hill Studio") throws -> Fixture {
    var values: [String: String] = [:]
    let cid = try F.cid(SyncKeys(entropy: Data(count: 32)).chainTag)
    let rid = repeated(1), aid = repeated(2)
    let jSalt = sequence(0x80, 32), tSalt = sequence(0xa0, 32)
    let jCommit = try C.nameCommitment(role: .joining, name: jName, salt: jSalt)
    let tCommit = try C.nameCommitment(role: .trusted, name: tName, salt: tSalt)
    var request = F.Message(cid: cid, rid: rid, aid: repeated(0), body: .request(F.Request(session: repeated(3), publicKey: try bytes(jPublic), name: "New Mac", createdMs: 1793552400000, expiresMs: 1793552700000, nameCommitment: jCommit, commitment: Data(count: 32))))
    let requestCore = try F.core(request)
    let cJ = try C.commitment(role: .joining, core: requestCore, random: sequence(0, 32))
    guard case .request(var requestBody) = request.body else { throw F.Failure.format }
    requestBody.commitment = cJ
    request.body = .request(requestBody)
    let requestWire = try F.encode(request)
    var offer = F.Message(cid: cid, rid: rid, aid: aid, body: .offer(F.Offer(requestHash: C.hash(requestWire), session: repeated(4), publicKey: try bytes(tPublic), name: "Trusted Mac", createdMs: 1793552401000, expiresMs: 1793552701000, nameCommitment: tCommit, commitment: Data(count: 32))))
    let offerCore = try F.core(offer)
    let cT = try C.commitment(role: .trusted, core: offerCore, random: sequence(0x20, 32))
    guard case .offer(var offerBody) = offer.body else { throw F.Failure.format }
    offerBody.commitment = cT
    offer.body = .offer(offerBody)
    let offerWire = try F.encode(offer)
    let select = try F.encode(F.Message(cid: cid, rid: rid, aid: aid, body: .select(requestHash: C.hash(requestWire), offerHash: C.hash(offerWire), random: sequence(0, 32))))
    let th = try C.transcript(request: requestWire, offer: offerWire, select: select, trustedRandom: sequence(0x20, 32))
    let z = try C.sharedSecret(bytes(jPrivate), bytes(tPublic))
    let keys = try C.keys(secret: z, transcript: th)
    let reveal = try F.encode(F.Message(cid: cid, rid: rid, aid: aid, body: .reveal(selectHash: C.hash(select), random: sequence(0x20, 32), confirmation: try C.confirmation(role: .trusted, keys: keys))))
    let confirm = try F.encode(F.Message(cid: cid, rid: rid, aid: aid, body: .confirm(transcript: th, confirmation: try C.confirmation(role: .joining, keys: keys))))
    let joiningName = try C.sealName(role: .joining, name: jName, salt: jSalt, cid: cid, rid: rid, aid: aid, keys: keys, rng: { _ in self.sequence(0x50, 12) })
    let trustedName = try C.sealName(role: .trusted, name: tName, salt: tSalt, cid: cid, rid: rid, aid: aid, keys: keys, rng: { _ in self.sequence(0x60, 12) })
    let grant = C.Approval(entropy: Data(count: 32), cid: cid, rid: rid, aid: aid, joiningSession: repeated(3), trustedDevice: repeated(6), transcript: th, approvedMs: 1793552410000, expiresMs: 1793552701000)
    let approval = try C.sealApproval(grant, keys: keys, rng: { _ in self.sequence(0x40, 12) })
    let receipt = try C.receipt(approval: approval, keys: keys)
    let joiningTerminal = try C.terminal(role: .joining, reason: 1, cid: cid, rid: rid, aid: aid, keys: keys)
    let trustedTerminal = try C.terminal(role: .trusted, reason: 2, cid: cid, rid: rid, aid: aid, keys: keys)
    let wires = ["request": requestWire, "offer": offerWire, "select": select, "reveal": reveal, "confirm": confirm, "j-name": joiningName, "t-name": trustedName, "approval": approval, "receipt": receipt, "j-terminal": joiningTerminal, "t-terminal": trustedTerminal]
    for (name, wire) in wires {
      values[name] = hex(wire)
      values[name + "Header"] = hex(wire.prefix(60))
      values[name + "Length"] = String(wire.count)
      values[name + "Hash"] = hex(C.hash(wire))
    }
    for (name, wire) in ["j-name": joiningName, "t-name": trustedName, "approval": approval] {
      values[name + "AAD"] = hex(try F.frame(name == "approval" ? "approval AAD" : "name AAD", Data(wire.prefix(60)), th))
      values[name + "Nonce"] = hex(wire.subdata(in: 92..<104))
      values[name + "Ciphertext"] = hex(wire.subdata(in: 104..<(wire.count - 16)))
      values[name + "Tag"] = hex(wire.suffix(16))
    }
    for (name, value) in ["CID": cid, "requestCore": requestCore, "offerCore": offerCore, "nameCommitJ": jCommit, "nameCommitT": tCommit, "cJ": cJ, "cT": cT, "Z": z, "TH": th, "PRK": C.extract(salt: th, ikm: z), "j-namePlaintext": try C.namePlaintext(name: jName, salt: jSalt), "t-namePlaintext": try C.namePlaintext(name: tName, salt: tSalt), "approvalPlaintext": try C.approvalPlaintext(grant)] { values[name] = hex(value) }
    values["requestCoreLength"] = String(requestCore.count)
    values["offerCoreLength"] = String(offerCore.count)
    values["SAS"] = try C.sas(keys)
    for label in C.labels { values["K_" + label] = hex(try keys.key(label)) }
    return Fixture(request: requestWire, offer: offerWire, select: select, reveal: reveal, confirm: confirm, joiningName: joiningName, trustedName: trustedName, approval: approval, receipt: receipt, joiningTerminal: joiningTerminal, trustedTerminal: trustedTerminal, cid: cid, keys: keys, values: values)
  }

  func testP1LiteralFixtureAndAcceptingControl() throws {
    let f = try fixture()
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/pairing-p1.json")
    let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    XCTAssertEqual(expected.count, 79)
    XCTAssertEqual(f.values.count, expected.count)
    for name in f.values.keys.sorted() { XCTAssertEqual(f.values[name], expected[name], name) }
    XCTAssertEqual(f.request.count, 197)
    XCTAssertEqual(f.offer.count, 233)
    XCTAssertEqual(f.joiningName.count, 376)
    XCTAssertEqual(f.trustedName.count, 376)
    XCTAssertEqual(f.approval.count, 1160)
    try C.validateReveal(f.reveal, request: f.request, offer: f.offer, select: f.select, keys: f.keys)
    try C.validateConfirmation(f.confirm, request: f.request, offer: f.offer, keys: f.keys)
    XCTAssertEqual(try C.openName(f.joiningName, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: bytes(XCTUnwrap(f.values["nameCommitJ"])), keys: f.keys), "Andrew’s MacBook Pro")
    XCTAssertEqual(try C.openName(f.trustedName, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: bytes(XCTUnwrap(f.values["nameCommitT"])), keys: f.keys), "Hill Studio")
    let approval = try C.openApproval(f.approval, request: f.request, offer: f.offer, keys: f.keys)
    XCTAssertEqual(approval.entropy, Data(count: 32))
    XCTAssertEqual(approval.trustedDevice, repeated(6))
    try C.validateReceipt(f.receipt, approval: f.approval, keys: f.keys)
    try C.validateTerminal(f.joiningTerminal, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)
    try C.validateTerminal(f.trustedTerminal, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)
  }

  func testEveryWireRejectsTrailingTruncatedOversizeVersionFlagsAndLength() throws {
    let f = try fixture()
    for wire in [f.request, f.offer, f.select, f.reveal, f.confirm, f.joiningName, f.trustedName, f.approval, f.receipt, f.joiningTerminal, f.trustedTerminal] {
      XCTAssertEqual(try F.encode(F.decode(wire)), wire)
      XCTAssertThrowsError(try F.decode(wire + Data([0])))
      for length in 0..<wire.count { XCTAssertThrowsError(try F.decode(Data(wire.prefix(length))), "length \(length)") }
      for offset in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11] {
        var changed = wire
        changed[offset] ^= 0x80
        XCTAssertThrowsError(try F.decode(changed), "offset \(offset)")
      }
    }
    XCTAssertThrowsError(try F.decode(Data(count: 8193)))
    XCTAssertThrowsError(try F.decode(Data([0x53, 0x50, 0x4a, 0x31]) + Data(count: 56)))
  }

  func testEveryTranscriptBoundFieldRejectsMutation() throws {
    let f = try fixture()
    for (kind, wire, offsets) in [(0, f.request, [12, 28, 44, 60, 76, 108, 110, 117, 125, 133, 165]), (1, f.offer, [12, 28, 44, 60, 92, 108, 140, 142, 153, 161, 169, 201]), (2, f.select, [12, 28, 44, 60, 92, 124])] {
      for offset in offsets {
        var changed = wire
        changed[offset] ^= 1
        XCTAssertThrowsError(try C.transcript(request: kind == 0 ? changed : f.request, offer: kind == 1 ? changed : f.offer, select: kind == 2 ? changed : f.select, trustedRandom: sequence(0x20, 32)), "kind \(kind) offset \(offset)")
      }
    }
    var random = sequence(0x20, 32)
    random[0] ^= 1
    XCTAssertThrowsError(try C.transcript(request: f.request, offer: f.offer, select: f.select, trustedRandom: random))
    for offset in [12, 28, 44, 60, 92, 124] {
      var reveal = f.reveal
      reveal[offset] ^= 1
      XCTAssertThrowsError(try C.validateReveal(reveal, request: f.request, offer: f.offer, select: f.select, keys: f.keys), "reveal \(offset)")
    }
    for offset in [12, 28, 44, 60, 92] {
      var confirm = f.confirm
      confirm[offset] ^= 1
      XCTAssertThrowsError(try C.validateConfirmation(confirm, request: f.request, offer: f.offer, keys: f.keys))
    }
  }

  func testRevealSelectHashOnlyRejectsDespiteUnchangedTranscriptAndMAC() throws {
    let f = try fixture()
    var changed = f.reveal
    changed[60] ^= 1
    XCTAssertEqual(changed.dropFirst(92), f.reveal.dropFirst(92))
    XCTAssertEqual(try C.transcript(request: f.request, offer: f.offer, select: f.select, trustedRandom: Data(changed[92..<124])), f.keys.transcript)
    try C.validateReveal(f.reveal, request: f.request, offer: f.offer, select: f.select, keys: f.keys)
    XCTAssertThrowsError(try C.validateReveal(changed, request: f.request, offer: f.offer, select: f.select, keys: f.keys))
  }

  func testPublicKeyCanonicalityAndLowOrderFailures() throws {
    let invalid = [try bytes("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"), try bytes("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"), Data(), Data(count: 31), Data(count: 33), Data(count: 32), repeated(0xff, 32), try bytes("ed" + String(repeating: "ff", count: 30) + "7f"), try bytes("01" + String(repeating: "00", count: 31)), try bytes("ec" + String(repeating: "ff", count: 30) + "7f")]
    for key in invalid { XCTAssertThrowsError(try C.sharedSecret(bytes(jPrivate), key)) }
    var high = try bytes(tPublic)
    high[31] |= 0x80
    XCTAssertThrowsError(try C.sharedSecret(bytes(jPrivate), high))
    XCTAssertThrowsError(try C.sharedSecret(Data(count: 31), bytes(tPublic)))
  }

  func testHeaderIDsSessionsLabelsTimesAndCanonicalPaths() throws {
    let f = try fixture()
    for (wire, ranges) in [(f.request, [28..<44, 60..<76]), (f.offer, [28..<44, 44..<60, 92..<108])] {
      for range in ranges {
        var changed = wire
        changed.replaceSubrange(range, with: Data(count: range.count))
        XCTAssertThrowsError(try F.decode(changed))
      }
    }
    for (wire, timeOffset, labelOffset) in [(f.request, 117, 110), (f.offer, 153, 142)] {
      var overflow = wire
      overflow.replaceSubrange(timeOffset..<(timeOffset + 8), with: Data(repeating: 0xff, count: 8))
      XCTAssertThrowsError(try F.decode(overflow))
      var wrongLabel = wire
      wrongLabel[labelOffset] = 0x58
      XCTAssertThrowsError(try F.decode(wrongLabel))
    }
    let request = try F.decode(f.request)
    var maximumTime = request
    guard case .request(var maximumBody) = maximumTime.body else { throw F.Failure.format }
    maximumBody.createdMs = UInt64.max - 300000
    maximumBody.expiresMs = UInt64.max
    maximumTime.body = .request(maximumBody)
    XCTAssertEqual(try F.encode(F.decode(F.encode(maximumTime))), try F.encode(maximumTime))
    let cid = SyncKeys(entropy: Data(count: 32)).chainTag
    try F.validatePath(request, namespace: "Solara Pairing v2", cid: cid, rid: String(repeating: "01", count: 16), filename: "request.spj")
    for (namespace, c, rid, filename) in [("Solara Pairing v1", cid, String(repeating: "01", count: 16), "request.spj"), ("Solara Pairing v2", cid.uppercased(), String(repeating: "01", count: 16), "request.spj"), ("Solara Pairing v2", cid, String(repeating: "02", count: 16), "request.spj"), ("Solara Pairing v2", cid, String(repeating: "01", count: 16), "Request.spj"), ("Solara Pairing v2", cid, String(repeating: "01", count: 16), "../request.spj")] { XCTAssertThrowsError(try F.validatePath(request, namespace: namespace, cid: c, rid: rid, filename: filename)) }
    XCTAssertThrowsError(try F.cid(String(cid.dropLast()) + "b"))
    for wire in [f.offer, f.select, f.reveal, f.confirm, f.joiningName, f.trustedName, f.approval, f.receipt, f.joiningTerminal, f.trustedTerminal] {
      let message = try F.decode(wire)
      let suffix: [UInt8: String] = [2: "offer", 3: "select", 4: "reveal", 5: "confirm", 6: "approval", 7: "receipt", 8: "j-terminal", 9: "t-terminal", 10: "j-name", 11: "t-name"]
      let name = String(repeating: "02", count: 16) + "." + (try XCTUnwrap(suffix[wire[5]])) + ".spj"
      try F.validatePath(message, namespace: "Solara Pairing v2", cid: cid, rid: String(repeating: "01", count: 16), filename: name)
      XCTAssertThrowsError(try F.validatePath(message, namespace: "Solara Pairing v2", cid: cid, rid: String(repeating: "01", count: 16), filename: String(repeating: "03", count: 16) + String(name.dropFirst(32))))
    }
  }

  func testNameBoundariesRepertoireAndExactNFCBytes() throws {
    for valid in ["A", String(repeating: "é", count: 64), "Andrew’s MacBook Pro", "山田のMac", "\u{1fae8}"] { XCTAssertEqual(try PairingUnicode.canonicalName(Data(valid.utf8)), valid) }
    let invalid = ["", String(repeating: "A", count: 65), String(repeating: "é", count: 65), "e\u{301}", " A", "A\u{a0}", "\u{2003}A", "A\nB", "A\u{2028}B", "A\u{2029}B", "A\u{202e}B", "A\u{e000}B", "\u{0378}", "\u{1f6d8}", "\u{1c89}", "\u{1fae9}"]
    for name in invalid { XCTAssertThrowsError(try PairingUnicode.canonicalName(Data(name.utf8))) }
    XCTAssertThrowsError(try PairingUnicode.canonicalName(try bytes("c0af")))
    XCTAssertThrowsError(try PairingUnicode.canonicalName(try bytes("eda080")))
    XCTAssertEqual(try PairingUnicode.canonicalName(Data("e\u{301}".utf8), normalizeLocal: true), "é")
    XCTAssertThrowsError(try C.namePlaintext(name: "A", salt: Data(count: 31)))
  }

  func reseal(_ wire: Data, plaintext: Data, key: Data, label: String, transcript: Data) throws -> Data {
    let header = Data(wire.prefix(60))
    let nonce = try AES.GCM.Nonce(data: wire.subdata(in: 92..<104))
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: F.frame(label, header, transcript))
    return header + transcript + Data(box.nonce) + box.ciphertext + box.tag
  }

  func testAuthenticatedNamesRejectBOMWithUnchangedPinnedCommitments() throws {
    for name in ["A", String(repeating: "é", count: 63)] {
      let f = try fixture(jName: name, tName: name)
      guard case .request(let request) = try F.decode(f.request).body,
        case .offer(let offer) = try F.decode(f.offer).body else { throw F.Failure.format }
      for role: F.Role in [.joining, .trusted] {
        let joining = role == .joining
        let type: UInt8 = joining ? 10 : 11
        let salt = sequence(joining ? 0x80 : 0xa0, 32)
        let commitment = joining ? request.nameCommitment : offer.nameCommitment
        let originalWire = joining ? f.joiningName : f.trustedName
        let keyLabel = joining ? "name-j" : "name-t"
        XCTAssertEqual(try C.openName(originalWire, role: role, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), name)
        let raw = Data([0xef, 0xbb, 0xbf]) + Data(name.utf8)
        XCTAssertEqual(raw.count, name == "A" ? 4 : 129)
        XCTAssertThrowsError(try PairingUnicode.canonicalName(raw))
        let payload = Data([1]) + salt + F.integer(UInt64(raw.count), bytes: 2) + raw
        let plaintext = try C.padded(payload, count: 256)
        let wire = try reseal(originalWire, plaintext: plaintext, key: f.keys.key(keyLabel), label: "name AAD", transcript: f.keys.transcript)
        XCTAssertEqual(wire[5], type)
        XCTAssertEqual(try C.open(wire, type: type, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys, label: "name AAD", key: keyLabel), plaintext)
        XCTAssertThrowsError(try C.openName(wire, role: role, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), "type=\(type) rawBytes=\(raw.count)")
      }
    }
  }

  func testNameAndApprovalRejectEveryEnvelopeBoundField() throws {
    let f = try fixture()
    for wire in [f.joiningName, f.trustedName, f.approval] {
      for offset in [5, 12, 28, 44, 60, 92, 104, wire.count - 1] {
        var changed = wire
        changed[offset] ^= 1
        if wire == f.approval { XCTAssertThrowsError(try C.openApproval(changed, request: f.request, offer: f.offer, keys: f.keys)) }
        else {
          let role: F.Role = wire == f.joiningName ? .joining : .trusted
          let commitment = try bytes(XCTUnwrap(f.values[role == .joining ? "nameCommitJ" : "nameCommitT"]))
          XCTAssertThrowsError(try C.openName(changed, role: role, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys))
        }
      }
    }
    let commitment = try bytes(XCTUnwrap(f.values["nameCommitJ"]))
    let originalSAS = try C.sas(f.keys)
    let resealed = try C.sealName(role: .joining, name: "Andrew’s MacBook Pro", salt: sequence(0x80, 32), cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys, rng: { _ in self.sequence(0x70, 12) })
    XCTAssertNotEqual(resealed, f.joiningName)
    XCTAssertEqual(try C.openName(resealed, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), "Andrew’s MacBook Pro")
    XCTAssertEqual(try C.sas(f.keys), originalSAS)
    XCTAssertThrowsError(try C.openName(f.joiningName, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys))
    XCTAssertThrowsError(try C.openName(f.joiningName, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: Data(count: 32), keys: f.keys))
    var wrongKeys = f.keys
    wrongKeys.values["name-j"] = try f.keys.key("name-t")
    XCTAssertThrowsError(try C.openName(f.joiningName, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: wrongKeys))
    let plain = try bytes(XCTUnwrap(f.values["j-namePlaintext"]))
    for offset in [0, 3, 4, 5, 37, 39, 255] {
      var changed = plain
      changed[offset] ^= 1
      let wire = try reseal(f.joiningName, plaintext: changed, key: f.keys.key("name-j"), label: "name AAD", transcript: f.keys.transcript)
      XCTAssertThrowsError(try C.openName(wire, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), "name payload \(offset)")
    }
    let approvalPlain = try bytes(XCTUnwrap(f.values["approvalPlaintext"]))
    for offset in [0, 3, 4, 5, 37, 53, 69, 85, 117, 157, 1039] {
      var changed = approvalPlain
      changed[offset] ^= 1
      let wire = try reseal(f.approval, plaintext: changed, key: f.keys.key("approval"), label: "approval AAD", transcript: f.keys.transcript)
      XCTAssertThrowsError(try C.openApproval(wire, request: f.request, offer: f.offer, keys: f.keys), "approval payload \(offset)")
    }
    var zeroDevice = approvalPlain
    zeroDevice.replaceSubrange(101..<117, with: Data(count: 16))
    XCTAssertThrowsError(try C.openApproval(reseal(f.approval, plaintext: zeroDevice, key: f.keys.key("approval"), label: "approval AAD", transcript: f.keys.transcript), request: f.request, offer: f.offer, keys: f.keys))
    var hint = approvalPlain
    hint[149] ^= 1
    XCTAssertNotEqual(try C.openApproval(reseal(f.approval, plaintext: hint, key: f.keys.key("approval"), label: "approval AAD", transcript: f.keys.transcript), request: f.request, offer: f.offer, keys: f.keys).approvedMs, 1793552410000)
  }

  func testReceiptAndTerminalMACsBindAllFieldsAndRoles() throws {
    let f = try fixture()
    for offset in [12, 28, 44, 60, 92, 124] {
      var changed = f.receipt
      changed[offset] ^= 1
      XCTAssertThrowsError(try C.validateReceipt(changed, approval: f.approval, keys: f.keys))
    }
    for offset in [5, 12, 28, 44, 60, 92, 93] {
      var changed = f.joiningTerminal
      changed[offset] ^= 1
      XCTAssertThrowsError(try C.validateTerminal(changed, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys))
    }
    for reason: UInt8 in [0, 2, 5, 255] { XCTAssertThrowsError(try C.terminal(role: .joining, reason: reason, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)) }
    for reason: UInt8 in [0, 1, 5, 255] { XCTAssertThrowsError(try C.terminal(role: .trusted, reason: reason, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)) }
    for reason: UInt8 in [3, 4] { try C.validateTerminal(C.terminal(role: .trusted, reason: reason, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys), role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys) }
  }

  func testTrustedNameRejectsAuthenticatedChangedSaltNameAndWrongCommitment() throws {
    let f = try fixture()
    let commitment = try bytes(XCTUnwrap(f.values["nameCommitT"]))
    let salt = sequence(0xa0, 32)
    XCTAssertEqual(try C.openName(f.trustedName, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), "Hill Studio")
    var changedSalt = salt
    changedSalt[0] ^= 1
    for (name, salt) in [("Hill Studio", changedSalt), ("Mill Studio", salt)] {
      let plaintext = try C.namePlaintext(name: name, salt: salt)
      let changed = try reseal(f.trustedName, plaintext: plaintext, key: f.keys.key("name-t"), label: "name AAD", transcript: f.keys.transcript)
      XCTAssertEqual(try C.open(changed, type: 11, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys, label: "name AAD", key: "name-t"), plaintext)
      XCTAssertThrowsError(try C.openName(changed, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: commitment, keys: f.keys), name) {
        XCTAssertEqual($0 as? F.Failure, .authentication)
      }
    }
    var wrongCommitment = commitment
    wrongCommitment[0] ^= 1
    XCTAssertThrowsError(try C.openName(f.trustedName, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), commitment: wrongCommitment, keys: f.keys)) {
      XCTAssertEqual($0 as? F.Failure, .authentication)
    }
  }

  func testTrustedTerminalRejectsChangedTranscriptMACAndWrongDirection() throws {
    let f = try fixture()
    try C.validateTerminal(f.trustedTerminal, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)
    for offset in [60, 93] {
      var changed = f.trustedTerminal
      changed[offset] ^= 1
      let message = try F.decode(changed)
      XCTAssertEqual(changed.prefix(60), f.trustedTerminal.prefix(60))
      XCTAssertEqual(message.cid, f.cid)
      XCTAssertEqual(message.rid, repeated(1))
      XCTAssertEqual(message.aid, repeated(2))
      guard case .terminal(let sender, _, let reason, _) = message.body else { throw F.Failure.format }
      XCTAssertEqual(sender, .trusted)
      XCTAssertEqual(reason, 2)
      XCTAssertThrowsError(try C.validateTerminal(changed, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys), "offset \(offset)") {
        XCTAssertEqual($0 as? F.Failure, .authentication)
      }
    }
    var wrongKeys = f.keys
    wrongKeys.values["confirm-t"] = try f.keys.key("confirm-j")
    XCTAssertThrowsError(try C.validateTerminal(f.trustedTerminal, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: wrongKeys)) {
      XCTAssertEqual($0 as? F.Failure, .authentication)
    }
    let sharedReason = try C.terminal(role: .trusted, reason: 3, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)
    try C.validateTerminal(sharedReason, role: .trusted, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)
    XCTAssertThrowsError(try C.validateTerminal(sharedReason, role: .joining, cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys)) {
      XCTAssertEqual($0 as? F.Failure, .format)
    }
  }

  func testInjectedRNGFailureAndExactLength() throws {
    XCTAssertEqual(try C.privateKey(using: { count in self.sequence(0x10, count) }), sequence(0x10, 32))
    XCTAssertEqual(try C.randomBytes(32, using: { count in self.sequence(0x80, count) }), sequence(0x80, 32))
    XCTAssertThrowsError(try C.privateKey(using: { _ in throw F.Failure.random }))
    XCTAssertThrowsError(try C.privateKey(using: { _ in Data(count: 31) }))
    let f = try fixture()
    let grant = try C.openApproval(f.approval, request: f.request, offer: f.offer, keys: f.keys)
    XCTAssertThrowsError(try C.sealApproval(grant, keys: f.keys, rng: { _ in throw F.Failure.random }))
    XCTAssertThrowsError(try C.sealApproval(grant, keys: f.keys, rng: { _ in Data(count: 11) }))
    XCTAssertThrowsError(try C.sealName(role: .joining, name: "A", salt: Data(count: 32), cid: f.cid, rid: repeated(1), aid: repeated(2), keys: f.keys, rng: { _ in throw F.Failure.random }))
    XCTAssertTrue(C.equal(Data([1, 2]), Data([1, 2])))
    XCTAssertFalse(C.equal(Data([1, 2]), Data([1, 3])))
    XCTAssertFalse(C.equal(Data([1]), Data([1, 0])))
  }
}
