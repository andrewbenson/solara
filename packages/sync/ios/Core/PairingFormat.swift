import Foundation

enum PairingFormat {
  enum Failure: Error, Equatable {
    case format
    case authentication
    case random
  }

  enum Role: UInt8 {
    case joining
    case trusted
  }

  struct Header: Equatable {
    var type: UInt8
    var bodyLength: Int
    var cid: Data
    var rid: Data
    var aid: Data
  }

  struct Request: Equatable {
    var session: Data
    var publicKey: Data
    var name: String
    var createdMs: UInt64
    var expiresMs: UInt64
    var nameCommitment: Data
    var commitment: Data
  }

  struct Offer: Equatable {
    var requestHash: Data
    var session: Data
    var publicKey: Data
    var name: String
    var createdMs: UInt64
    var expiresMs: UInt64
    var nameCommitment: Data
    var commitment: Data
  }

  enum Body: Equatable {
    case request(Request)
    case offer(Offer)
    case select(requestHash: Data, offerHash: Data, random: Data)
    case reveal(selectHash: Data, random: Data, confirmation: Data)
    case confirm(transcript: Data, confirmation: Data)
    case encrypted(type: UInt8, transcript: Data, nonce: Data, ciphertext: Data, tag: Data)
    case receipt(transcript: Data, approvalHash: Data, mac: Data)
    case terminal(role: Role, transcript: Data, reason: UInt8, mac: Data)
  }

  struct Message: Equatable {
    var cid: Data
    var rid: Data
    var aid: Data
    var body: Body
  }

  struct Reader {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
      self.data = Data(data)
    }

    mutating func read(_ count: Int) throws -> Data {
      guard count >= 0, count <= data.count - offset else { throw Failure.format }
      defer { offset += count }
      return data.subdata(in: offset..<(offset + count))
    }

    mutating func integer(_ count: Int) throws -> UInt64 {
      try read(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func string() throws -> String {
      let count = Int(try integer(2))
      let raw = try read(count)
      guard let value = String(data: raw, encoding: .utf8), Data(value.utf8) == raw else { throw Failure.format }
      return value
    }

    func finish() throws {
      guard offset == data.count else { throw Failure.format }
    }
  }

  static func integer(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  static func string(_ value: String) throws -> Data {
    let bytes = Data(value.utf8)
    guard bytes.count <= Int(UInt16.max) else { throw Failure.format }
    return integer(UInt64(bytes.count), bytes: 2) + bytes
  }

  static func u64(_ value: UInt64) -> Data { integer(value, bytes: 8) }

  static func frame(_ label: String, _ arguments: Data...) throws -> Data {
    guard arguments.count <= Int(UInt32.max) else { throw Failure.format }
    var data = try string("solara-pair/v2/" + label)
    data.append(integer(UInt64(arguments.count), bytes: 4))
    for argument in arguments {
      guard argument.count <= Int(UInt32.max) else { throw Failure.format }
      data.append(integer(UInt64(argument.count), bytes: 4))
      data.append(argument)
    }
    return data
  }

  static func validateIDs(cid: Data, rid: Data, aid: Data, request: Bool) throws {
    guard cid.count == 16, rid.count == 16, aid.count == 16, rid.contains(where: { $0 != 0 }), request == !aid.contains(where: { $0 != 0 }) else { throw Failure.format }
  }

  static func header(_ value: Header) throws -> Data {
    guard (1...11).contains(value.type), value.bodyLength >= 0, value.bodyLength <= 8192 - 60 else { throw Failure.format }
    try validateIDs(cid: value.cid, rid: value.rid, aid: value.aid, request: value.type == 1)
    return Data("SPJ2".utf8) + Data([2, value.type, 0, 0]) + integer(UInt64(value.bodyLength), bytes: 4) + value.cid + value.rid + value.aid
  }

  static func fixed(_ values: (Data, Int)...) throws {
    guard values.allSatisfy({ $0.0.count == $0.1 }) else { throw Failure.format }
  }

  static func times(_ created: UInt64, _ expires: UInt64) throws {
    let (expected, overflow) = created.addingReportingOverflow(300000)
    guard !overflow, expires == expected else { throw Failure.format }
  }

  static func session(_ data: Data) throws {
    guard data.count == 16, data.contains(where: { $0 != 0 }) else { throw Failure.format }
  }

  static func validatePublicKey(_ key: Data) throws {
    guard key.count == 32 else { throw Failure.format }
    let prime = Data([0xed] + Array(repeating: UInt8(0xff), count: 30) + [0x7f])
    guard key.reversed().lexicographicallyPrecedes(prime.reversed()) else { throw Failure.format }
  }

  static func body(_ message: Message) throws -> (UInt8, Data) {
    switch message.body {
    case .request(let value):
      try session(value.session)
      try validatePublicKey(value.publicKey)
      try fixed((value.nameCommitment, 32), (value.commitment, 32))
      try times(value.createdMs, value.expiresMs)
      guard value.name == "New Mac" else { throw Failure.format }
      return (1, try value.session + value.publicKey + string(value.name) + u64(value.createdMs) + u64(value.expiresMs) + value.nameCommitment + value.commitment)
    case .offer(let value):
      try session(value.session)
      try validatePublicKey(value.publicKey)
      try fixed((value.requestHash, 32), (value.nameCommitment, 32), (value.commitment, 32))
      try times(value.createdMs, value.expiresMs)
      guard value.name == "Trusted Mac" else { throw Failure.format }
      return (2, try value.requestHash + value.session + value.publicKey + string(value.name) + u64(value.createdMs) + u64(value.expiresMs) + value.nameCommitment + value.commitment)
    case .select(let requestHash, let offerHash, let random):
      try fixed((requestHash, 32), (offerHash, 32), (random, 32))
      return (3, requestHash + offerHash + random)
    case .reveal(let selectHash, let random, let confirmation):
      try fixed((selectHash, 32), (random, 32), (confirmation, 32))
      return (4, selectHash + random + confirmation)
    case .confirm(let transcript, let confirmation):
      try fixed((transcript, 32), (confirmation, 32))
      return (5, transcript + confirmation)
    case .encrypted(let type, let transcript, let nonce, let ciphertext, let tag):
      guard [6, 10, 11].contains(type) else { throw Failure.format }
      try fixed((transcript, 32), (nonce, 12), (ciphertext, type == 6 ? 1040 : 256), (tag, 16))
      return (type, transcript + nonce + ciphertext + tag)
    case .receipt(let transcript, let approvalHash, let mac):
      try fixed((transcript, 32), (approvalHash, 32), (mac, 32))
      return (7, transcript + approvalHash + mac)
    case .terminal(let role, let transcript, let reason, let mac):
      guard (role == .joining ? [1, 3, 4] : [2, 3, 4]).contains(reason) else { throw Failure.format }
      try fixed((transcript, 32), (mac, 32))
      return (role == .joining ? 8 : 9, transcript + Data([reason]) + mac)
    }
  }

  static func header(_ message: Message) throws -> Data {
    let (type, bytes) = try body(message)
    return try header(Header(type: type, bodyLength: bytes.count, cid: message.cid, rid: message.rid, aid: message.aid))
  }

  static func encode(_ message: Message) throws -> Data {
    let (type, bytes) = try body(message)
    let prefix = try header(Header(type: type, bodyLength: bytes.count, cid: message.cid, rid: message.rid, aid: message.aid))
    let wire = prefix + bytes
    guard wire.count <= (type <= 2 ? 1024 : type == 6 ? 1160 : 512) else { throw Failure.format }
    return wire
  }

  static func decode(_ wire: Data) throws -> Message {
    guard wire.count >= 60, wire.count <= 8192 else { throw Failure.format }
    var reader = Reader(data: Data(wire))
    guard try reader.read(4) == Data("SPJ2".utf8), try reader.integer(1) == 2 else { throw Failure.format }
    let type = UInt8(try reader.integer(1))
    guard try reader.integer(2) == 0 else { throw Failure.format }
    let count = Int(try reader.integer(4))
    guard count == wire.count - 60 else { throw Failure.format }
    let cid = try reader.read(16), rid = try reader.read(16), aid = try reader.read(16)
    try validateIDs(cid: cid, rid: rid, aid: aid, request: type == 1)
    let body: Body
    switch type {
    case 1:
      body = try .request(Request(session: reader.read(16), publicKey: reader.read(32), name: reader.string(), createdMs: reader.integer(8), expiresMs: reader.integer(8), nameCommitment: reader.read(32), commitment: reader.read(32)))
    case 2:
      body = try .offer(Offer(requestHash: reader.read(32), session: reader.read(16), publicKey: reader.read(32), name: reader.string(), createdMs: reader.integer(8), expiresMs: reader.integer(8), nameCommitment: reader.read(32), commitment: reader.read(32)))
    case 3:
      body = try .select(requestHash: reader.read(32), offerHash: reader.read(32), random: reader.read(32))
    case 4:
      body = try .reveal(selectHash: reader.read(32), random: reader.read(32), confirmation: reader.read(32))
    case 5:
      body = try .confirm(transcript: reader.read(32), confirmation: reader.read(32))
    case 6, 10, 11:
      body = try .encrypted(type: type, transcript: reader.read(32), nonce: reader.read(12), ciphertext: reader.read(type == 6 ? 1040 : 256), tag: reader.read(16))
    case 7:
      body = try .receipt(transcript: reader.read(32), approvalHash: reader.read(32), mac: reader.read(32))
    case 8, 9:
      body = try .terminal(role: type == 8 ? .joining : .trusted, transcript: reader.read(32), reason: UInt8(reader.integer(1)), mac: reader.read(32))
    default:
      throw Failure.format
    }
    try reader.finish()
    let message = Message(cid: cid, rid: rid, aid: aid, body: body)
    _ = try encode(message)
    return message
  }

  static func core(_ message: Message) throws -> Data {
    let wire = try encode(message)
    let (type, bytes) = try body(message)
    guard type == 1 || type == 2 else { throw Failure.format }
    return try header(Header(type: type, bodyLength: bytes.count - 32, cid: message.cid, rid: message.rid, aid: message.aid)) + wire.dropFirst(60).dropLast(32)
  }

  static func cid(_ tag: String) throws -> Data {
    guard tag.utf8.count == 26 else { throw Failure.format }
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var result = Data(), buffer = 0, bits = 0
    for char in tag.utf8 {
      guard let index = alphabet.firstIndex(of: char) else { throw Failure.format }
      buffer = buffer << 5 | index
      bits += 5
      if bits >= 8 {
        bits -= 8
        result.append(UInt8((buffer >> bits) & 255))
      }
      buffer &= (1 << bits) - 1
    }
    guard result.count == 16, buffer == 0, Base32.encode(result) == tag else { throw Failure.format }
    return result
  }

  static func validatePath(_ message: Message, namespace: String, cid: String, rid: String, filename: String) throws {
    let (type, _) = try body(message)
    _ = try encode(message)
    let suffixes: [UInt8: String] = [2: "offer", 3: "select", 4: "reveal", 5: "confirm", 6: "approval", 7: "receipt", 8: "j-terminal", 9: "t-terminal", 10: "j-name", 11: "t-name"]
    let aid = message.aid.map { String(format: "%02x", $0) }.joined()
    let expected: String
    if type == 1 { expected = "request.spj" }
    else {
      guard let suffix = suffixes[type] else { throw Failure.format }
      expected = aid + "." + suffix + ".spj"
    }
    guard namespace == "Solara Pairing v2", try Self.cid(cid) == message.cid, rid == message.rid.map({ String(format: "%02x", $0) }).joined(), filename == expected else { throw Failure.format }
  }
}
