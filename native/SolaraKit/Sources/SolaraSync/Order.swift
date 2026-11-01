let orderDigits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf16)
let orderBase = orderDigits.count

func orderDigit(_ c: UInt16?) -> Int {
  guard let c else { return 0 }
  return orderDigits.firstIndex(of: c) ?? -1
}

func orderDigitText(_ index: Int) -> [UInt16] {
  index >= 0 && index < orderBase ? [orderDigits[index]] : Array("undefined".utf16)
}

func jsLess(_ a: [UInt16], _ b: [UInt16]) -> Bool { a.lexicographicallyPrecedes(b) }

struct PositionError: Error, CustomStringConvertible {
  let description: String
}

func positionBetween(_ a: [UInt16], _ b: [UInt16]?) throws -> [UInt16] {
  if let b, !jsLess(a, b) { throw PositionError(description: "positionBetween: \(String(decoding: a, as: UTF16.self)) >= \(String(decoding: b, as: UTF16.self))") }
  if let b {
    var n = 0
    let zero = UInt16(UInt8(ascii: "0"))
    while n < b.count, (n < a.count ? a[n] : zero) == b[n] { n += 1 }
    if n > 0 { return Array(b.prefix(n)) + (try positionBetween(Array(a.dropFirst(n)), Array(b.dropFirst(n)))) }
  }
  let da = orderDigit(a.first)
  let db = b.map { orderDigit($0.first) } ?? orderBase
  if db - da > 1 {
    let middle = (Double(da + db) / 2 + 0.5).rounded(.down)
    return orderDigitText(middle == 0 ? 0 : Int(middle))
  }
  if let b, b.count > 1 { return Array(b.prefix(1)) }
  return orderDigitText(da) + (try positionBetween(Array(a.dropFirst()), nil))
}

public func assignPositions(_ existing: [String?]) throws -> [String] {
  let units = existing.map { $0.map { Array($0.utf16) } }
  var tails: [Int] = []
  var previous = [Int](repeating: -1, count: units.count)
  let zero = UInt16(UInt8(ascii: "0"))
  for (i, p) in units.enumerated() {
    guard let p, !p.isEmpty, p.last != zero, p.allSatisfy(orderDigits.contains) else { continue }
    var lo = 0
    var hi = tails.count
    while lo < hi {
      let mid = (lo + hi) >> 1
      if jsLess(units[tails[mid]]!, p) { lo = mid + 1 } else { hi = mid }
    }
    if lo > 0 { previous[i] = tails[lo - 1] }
    if lo == tails.count { tails.append(i) } else { tails[lo] = i }
  }
  var keep = Set<Int>()
  var i = tails.last ?? -1
  while i >= 0 {
    keep.insert(i)
    i = previous[i]
  }
  var out = [[UInt16]](repeating: [], count: units.count)
  for k in keep { out[k] = units[k]! }
  var before: [UInt16] = []
  for i in 0..<units.count {
    if keep.contains(i) {
      before = out[i]
      continue
    }
    var next: [UInt16]? = nil
    for j in (i + 1)..<max(i + 1, units.count) where keep.contains(j) {
      next = out[j]
      break
    }
    out[i] = try positionBetween(before, next)
    before = out[i]
  }
  return out.map { String(decoding: $0, as: UTF16.self) }
}
