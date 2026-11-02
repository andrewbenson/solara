import CryptoKit
import Foundation
import Security

enum PairingCrypto {
  typealias Random = (Int) throws -> Data
  typealias Message = PairingFormat.Message
  typealias Role = PairingFormat.Role

  struct Keys {
    var transcript: Data
    var values: [String: Data]
    func key(_ label: String) throws -> Data {
      guard PairingCrypto.labels.contains(label), let value = values[label], value.count == 32 else { throw PairingFormat.Failure.format }
      return value
    }
  }

  struct Approval: Equatable {
    var entropy: Data
    var cid: Data
    var rid: Data
    var aid: Data
    var joiningSession: Data
    var trustedDevice: Data
    var transcript: Data
    var approvedMs: UInt64
    var expiresMs: UInt64
  }

  static let labels = ["sas", "confirm-j", "confirm-t", "approval", "receipt", "name-j", "name-t"]
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  static func random(_ count: Int) throws -> Data {
    guard count >= 0, count <= 8192 else { throw PairingFormat.Failure.random }
    if count == 0 { return Data() }
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
      guard let address = buffer.baseAddress else { return errSecAllocate }
      return SecRandomCopyBytes(kSecRandomDefault, count, address)
    }
    guard status == errSecSuccess else { throw PairingFormat.Failure.random }
    return data
  }

  static func randomBytes(_ count: Int, using rng: Random = random) throws -> Data {
    guard count >= 0, count <= 8192 else { throw PairingFormat.Failure.random }
    let data = try rng(count)
    guard data.count == count else { throw PairingFormat.Failure.random }
    return data
  }

  static func privateKey(using rng: Random = random) throws -> Data { try randomBytes(32, using: rng) }

  static func publicKey(_ privateKey: Data) throws -> Data {
    guard privateKey.count == 32 else { throw PairingFormat.Failure.format }
    return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
  }

  static func sharedSecret(_ privateKey: Data, _ publicKey: Data) throws -> Data {
    guard privateKey.count == 32 else { throw PairingFormat.Failure.format }
    try PairingFormat.validatePublicKey(publicKey)
    let secret: Data
    do {
      let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
      let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
      secret = try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    } catch {
      throw PairingFormat.Failure.authentication
    }
    guard !equal(secret, Data(count: 32)) else { throw PairingFormat.Failure.authentication }
    return secret
  }

  static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

  static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
    return difference == 0
  }

  static func mac(_ key: Data, _ data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  static func extract(salt: Data, ikm: Data) -> Data { mac(salt, ikm) }

  static func expand(prk: Data, info: Data, count: Int) throws -> Data {
    guard prk.count == 32, count >= 0, count <= 255 * 32 else { throw PairingFormat.Failure.format }
    var result = Data(), previous = Data()
    for block in 0..<((count + 31) / 32) {
      previous = mac(prk, previous + info + Data([UInt8(block + 1)]))
      result.append(previous)
    }
    return Data(result.prefix(count))
  }

  static func keys(secret: Data, transcript: Data) throws -> Keys {
    try PairingFormat.fixed((secret, 32), (transcript, 32))
    guard !equal(secret, Data(count: 32)) else { throw PairingFormat.Failure.authentication }
    let prk = extract(salt: transcript, ikm: secret)
    var values: [String: Data] = [:]
    for label in labels {
      values[label] = try expand(prk: prk, info: PairingFormat.frame("key", Data(label.utf8), transcript), count: 32)
    }
    return Keys(transcript: transcript, values: values)
  }

  static func commitment(role: Role, core: Data, random: Data) throws -> Data {
    try PairingFormat.fixed((random, 32))
    return try hash(PairingFormat.frame(role == .joining ? "J commitment" : "T commitment", core, random))
  }

  static func nameCommitment(role: Role, name: String, salt: Data) throws -> Data {
    try PairingFormat.fixed((salt, 32))
    let canonical = try PairingUnicode.canonicalName(Data(name.utf8))
    return try hash(PairingFormat.frame(role == .joining ? "J name" : "T name", PairingFormat.string(canonical), salt))
  }

  static func require(_ condition: Bool) throws {
    guard condition else { throw PairingFormat.Failure.authentication }
  }

  static func matching(_ message: Message, cid: Data, rid: Data, aid: Data) throws {
    try require(message.cid == cid && message.rid == rid && message.aid == aid)
  }

  static func context(request: Data, offer: Data) throws -> (Message, PairingFormat.Request, Message, PairingFormat.Offer) {
    let j = try PairingFormat.decode(request), t = try PairingFormat.decode(offer)
    guard case .request(let joining) = j.body, case .offer(let trusted) = t.body else { throw PairingFormat.Failure.format }
    try require(j.cid == t.cid && j.rid == t.rid)
    try require(equal(trusted.requestHash, hash(request)))
    return (j, joining, t, trusted)
  }

  static func transcript(request: Data, offer: Data, select: Data, trustedRandom: Data) throws -> Data {
    let (j, joining, t, trusted) = try context(request: request, offer: offer)
    let selection = try PairingFormat.decode(select)
    try matching(selection, cid: j.cid, rid: j.rid, aid: t.aid)
    guard case .select(let requestHash, let offerHash, let joiningRandom) = selection.body else { throw PairingFormat.Failure.format }
    try require(equal(requestHash, hash(request)) && equal(offerHash, hash(offer)))
    try require(equal(joining.commitment, commitment(role: .joining, core: PairingFormat.core(j), random: joiningRandom)))
    try require(equal(trusted.commitment, commitment(role: .trusted, core: PairingFormat.core(t), random: trustedRandom)))
    return try hash(PairingFormat.frame("transcript", request, offer, select, trustedRandom))
  }

  static func validateReveal(_ reveal: Data, request: Data, offer: Data, select: Data, keys: Keys) throws {
    let (j, _, t, _) = try context(request: request, offer: offer)
    let message = try PairingFormat.decode(reveal)
    try matching(message, cid: j.cid, rid: j.rid, aid: t.aid)
    guard case .reveal(let selectHash, let random, let confirmation) = message.body else { throw PairingFormat.Failure.format }
    try require(equal(selectHash, hash(select)))
    try require(equal(keys.transcript, transcript(request: request, offer: offer, select: select, trustedRandom: random)))
    try require(equal(confirmation, Self.confirmation(role: .trusted, keys: keys)))
  }

  static func confirmation(role: Role, keys: Keys) throws -> Data {
    try PairingFormat.fixed((keys.transcript, 32))
    return try mac(keys.key(role == .joining ? "confirm-j" : "confirm-t"), PairingFormat.frame(role == .joining ? "J ready" : "T ready", keys.transcript))
  }

  static func validateConfirmation(_ confirm: Data, request: Data, offer: Data, keys: Keys) throws {
    let (j, _, t, _) = try context(request: request, offer: offer)
    let message = try PairingFormat.decode(confirm)
    try matching(message, cid: j.cid, rid: j.rid, aid: t.aid)
    guard case .confirm(let transcript, let confirmation) = message.body else { throw PairingFormat.Failure.format }
    try require(equal(transcript, keys.transcript) && equal(confirmation, Self.confirmation(role: .joining, keys: keys)))
  }

  static func sasBits(_ value: Data) throws -> String {
    guard value.count >= 4 else { throw PairingFormat.Failure.format }
    let bits = value.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    return String((0..<6).map { alphabet[Int((bits >> (27 - $0 * 5)) & 31)] })
  }

  static func sas(_ keys: Keys) throws -> String {
    try sasBits(mac(keys.key("sas"), PairingFormat.frame("compare", keys.transcript)))
  }

  static func padded(_ payload: Data, count: Int) throws -> Data {
    guard payload.count <= count - 4 else { throw PairingFormat.Failure.format }
    return PairingFormat.integer(UInt64(payload.count), bytes: 4) + payload + Data(count: count - 4 - payload.count)
  }

  static func unpad(_ plain: Data, count: Int) throws -> Data {
    guard plain.count == count else { throw PairingFormat.Failure.format }
    var reader = PairingFormat.Reader(data: plain)
    let length = Int(try reader.integer(4))
    let payload = try reader.read(length)
    let padding = try reader.read(plain.count - reader.offset)
    guard equal(padding, Data(count: padding.count)) else { throw PairingFormat.Failure.format }
    return payload
  }

  static func namePlaintext(name: String, salt: Data) throws -> Data {
    try PairingFormat.fixed((salt, 32))
    let canonical = try PairingUnicode.canonicalName(Data(name.utf8))
    return try padded(Data([1]) + salt + PairingFormat.string(canonical), count: 256)
  }

  static func seal(_ plain: Data, type: UInt8, cid: Data, rid: Data, aid: Data, keys: Keys, label: String, key: String, rng: Random) throws -> Data {
    let nonce = try AES.GCM.Nonce(data: randomBytes(12, using: rng))
    let header = try PairingFormat.header(PairingFormat.Header(type: type, bodyLength: 32 + 12 + plain.count + 16, cid: cid, rid: rid, aid: aid))
    let aad = try PairingFormat.frame(label, header, keys.transcript)
    let box = try AES.GCM.seal(plain, using: SymmetricKey(data: keys.key(key)), nonce: nonce, authenticating: aad)
    return try PairingFormat.encode(Message(cid: cid, rid: rid, aid: aid, body: .encrypted(type: type, transcript: keys.transcript, nonce: Data(box.nonce), ciphertext: box.ciphertext, tag: box.tag)))
  }

  static func open(_ wire: Data, type: UInt8, cid: Data, rid: Data, aid: Data, keys: Keys, label: String, key: String) throws -> Data {
    let message = try PairingFormat.decode(wire)
    try matching(message, cid: cid, rid: rid, aid: aid)
    guard case .encrypted(let actualType, let transcript, let nonce, let ciphertext, let tag) = message.body, actualType == type else { throw PairingFormat.Failure.format }
    try require(equal(transcript, keys.transcript))
    let aad = try PairingFormat.frame(label, Data(wire.prefix(60)), keys.transcript)
    do {
      let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
      return try AES.GCM.open(box, using: SymmetricKey(data: keys.key(key)), authenticating: aad)
    } catch {
      throw PairingFormat.Failure.authentication
    }
  }

  static func sealName(role: Role, name: String, salt: Data, cid: Data, rid: Data, aid: Data, keys: Keys, rng: Random = random) throws -> Data {
    try seal(namePlaintext(name: name, salt: salt), type: role == .joining ? 10 : 11, cid: cid, rid: rid, aid: aid, keys: keys, label: "name AAD", key: role == .joining ? "name-j" : "name-t", rng: rng)
  }

  static func openName(_ wire: Data, role: Role, cid: Data, rid: Data, aid: Data, commitment: Data, keys: Keys) throws -> String {
    try PairingFormat.fixed((commitment, 32))
    let plain = try open(wire, type: role == .joining ? 10 : 11, cid: cid, rid: rid, aid: aid, keys: keys, label: "name AAD", key: role == .joining ? "name-j" : "name-t")
    let payload = try unpad(plain, count: 256)
    var reader = PairingFormat.Reader(data: payload)
    guard try reader.integer(1) == 1 else { throw PairingFormat.Failure.format }
    let salt = try reader.read(32)
    let nameLength = Int(try reader.integer(2))
    let nameBytes = try reader.read(nameLength)
    try reader.finish()
    let canonical = try PairingUnicode.canonicalName(nameBytes)
    let nameSTR = PairingFormat.integer(UInt64(nameLength), bytes: 2) + nameBytes
    let actualCommitment = try hash(PairingFormat.frame(role == .joining ? "J name" : "T name", nameSTR, salt))
    try require(equal(commitment, actualCommitment))
    return canonical
  }

  static func approvalPlaintext(_ approval: Approval) throws -> Data {
    try PairingFormat.fixed((approval.entropy, 32), (approval.transcript, 32))
    try PairingFormat.validateIDs(cid: approval.cid, rid: approval.rid, aid: approval.aid, request: false)
    try PairingFormat.session(approval.joiningSession)
    try PairingFormat.session(approval.trustedDevice)
    let payload = Data([1]) + approval.entropy + approval.cid + approval.rid + approval.aid + approval.joiningSession + approval.trustedDevice + approval.transcript + PairingFormat.u64(approval.approvedMs) + PairingFormat.u64(approval.expiresMs)
    return try padded(payload, count: 1040)
  }

  static func sealApproval(_ approval: Approval, keys: Keys, rng: Random = random) throws -> Data {
    try require(equal(approval.transcript, keys.transcript))
    try require(equal(approval.cid, PairingFormat.cid(SyncKeys(entropy: approval.entropy).chainTag)))
    return try seal(approvalPlaintext(approval), type: 6, cid: approval.cid, rid: approval.rid, aid: approval.aid, keys: keys, label: "approval AAD", key: "approval", rng: rng)
  }

  static func openApproval(_ wire: Data, request: Data, offer: Data, keys: Keys) throws -> Approval {
    let (j, joining, t, trusted) = try context(request: request, offer: offer)
    let plain = try open(wire, type: 6, cid: j.cid, rid: j.rid, aid: t.aid, keys: keys, label: "approval AAD", key: "approval")
    let payload = try unpad(plain, count: 1040)
    guard payload.count == 161 else { throw PairingFormat.Failure.format }
    var reader = PairingFormat.Reader(data: payload)
    guard try reader.integer(1) == 1 else { throw PairingFormat.Failure.format }
    let approval = try Approval(entropy: reader.read(32), cid: reader.read(16), rid: reader.read(16), aid: reader.read(16), joiningSession: reader.read(16), trustedDevice: reader.read(16), transcript: reader.read(32), approvedMs: reader.integer(8), expiresMs: reader.integer(8))
    try reader.finish()
    try PairingFormat.session(approval.trustedDevice)
    try require(approval.cid == j.cid && approval.rid == j.rid && approval.aid == t.aid)
    try require(approval.joiningSession == joining.session && approval.expiresMs == trusted.expiresMs)
    try require(equal(approval.transcript, keys.transcript))
    try require(equal(approval.cid, PairingFormat.cid(SyncKeys(entropy: approval.entropy).chainTag)))
    return approval
  }

  static func receipt(approval: Data, keys: Keys) throws -> Data {
    let grant = try PairingFormat.decode(approval)
    guard case .encrypted(let type, let transcript, _, _, _) = grant.body, type == 6 else { throw PairingFormat.Failure.format }
    try require(equal(transcript, keys.transcript))
    let approvalHash = hash(approval)
    let mac = try Self.mac(keys.key("receipt"), PairingFormat.frame("installed", keys.transcript, approvalHash))
    return try PairingFormat.encode(Message(cid: grant.cid, rid: grant.rid, aid: grant.aid, body: .receipt(transcript: keys.transcript, approvalHash: approvalHash, mac: mac)))
  }

  static func validateReceipt(_ wire: Data, approval: Data, keys: Keys) throws {
    let expected = try receipt(approval: approval, keys: keys)
    try require(equal(wire, expected))
  }

  static func terminal(role: Role, reason: UInt8, cid: Data, rid: Data, aid: Data, keys: Keys) throws -> Data {
    var message = Message(cid: cid, rid: rid, aid: aid, body: .terminal(role: role, transcript: keys.transcript, reason: reason, mac: Data(count: 32)))
    let header = try PairingFormat.header(message)
    let mac = try Self.mac(keys.key(role == .joining ? "confirm-j" : "confirm-t"), PairingFormat.frame("terminal", header, keys.transcript, Data([reason])))
    message.body = .terminal(role: role, transcript: keys.transcript, reason: reason, mac: mac)
    return try PairingFormat.encode(message)
  }

  static func validateTerminal(_ wire: Data, role: Role, cid: Data, rid: Data, aid: Data, keys: Keys) throws {
    let message = try PairingFormat.decode(wire)
    try matching(message, cid: cid, rid: rid, aid: aid)
    guard case .terminal(let sender, let transcript, let reason, _) = message.body, sender == role else { throw PairingFormat.Failure.format }
    try require(equal(transcript, keys.transcript))
    try require(equal(wire, terminal(role: role, reason: reason, cid: cid, rid: rid, aid: aid, keys: keys)))
  }
}
