import Darwin

public enum JS {
  public static let negativeInfinity = Int.min / 4
  public static let positiveInfinity = Int.max / 4

  public static func max(_ values: [Int]) -> Int {
    values.max() ?? negativeInfinity
  }

  public static func min(_ values: [Int]) -> Int {
    values.min() ?? positiveInfinity
  }

  public static func isWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    case 0x2000...0x200A: true
    default: false
    }
  }
}

public extension String {
  var jsLength: Int { utf16.count }

  init(utf16Units units: some Collection<UInt16>) {
    self = String(decoding: Array(units), as: UTF16.self)
  }

  func jsTrim() -> String {
    let units = Array(utf16)
    var start = 0
    var end = units.count
    while start < end, JS.isWhitespace(units[start]) { start += 1 }
    while end > start, JS.isWhitespace(units[end - 1]) { end -= 1 }
    if start == 0, end == units.count { return self }
    return String(utf16Units: units[start..<end])
  }

  func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
    let units = Array(utf16)
    let count = units.count
    func clamp(_ i: Int) -> Int { i < 0 ? Swift.max(count + i, 0) : Swift.min(i, count) }
    let from = clamp(start)
    let to = clamp(end ?? count)
    if from >= to { return "" }
    return String(utf16Units: units[from..<to])
  }

  func jsIndexOf(_ needle: String, from: Int = 0) -> Int {
    let hay = Array(utf16)
    let pin = Array(needle.utf16)
    let start = Swift.max(from, 0)
    if pin.isEmpty { return Swift.min(start, hay.count) }
    if pin.count > hay.count { return -1 }
    var i = start
    while i + pin.count <= hay.count {
      if hay[i] == pin[0], Array(hay[i..<(i + pin.count)]) == pin { return i }
      i += 1
    }
    return -1
  }

  func jsLastIndexOf(_ needle: String) -> Int {
    let hay = Array(utf16)
    let pin = Array(needle.utf16)
    if pin.count > hay.count { return -1 }
    var i = hay.count - pin.count
    while i >= 0 {
      if Array(hay[i..<(i + pin.count)]) == pin { return i }
      i -= 1
    }
    return -1
  }

  func jsStartsWith(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }

  func jsEndsWith(_ suffix: String) -> Bool { utf16.reversed().starts(with: suffix.utf16.reversed()) }

  func jsEquals(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }

  func jsSplit(_ separator: String) -> [String] {
    let units = Array(utf16)
    let pin = Array(separator.utf16)
    if pin.isEmpty { return units.map { String(utf16Units: [$0]) } }
    var parts: [String] = []
    var start = 0
    var i = 0
    while i + pin.count <= units.count {
      if Array(units[i..<(i + pin.count)]) == pin {
        parts.append(String(utf16Units: units[start..<i]))
        i += pin.count
        start = i
      } else {
        i += 1
      }
    }
    parts.append(String(utf16Units: units[start...]))
    return parts
  }

  func jsLowercased() -> String { lowercased() }

  func jsBeforeFirst(_ unit: Character) -> String {
    guard let at = firstIndex(of: unit) else { return self }
    return String(self[..<at])
  }
}

public extension Array where Element: Equatable {
  func jsIndexOf(_ element: Element) -> Int {
    firstIndex(of: element) ?? -1
  }

  func jsIndexOf(_ element: Element?) -> Int {
    element.flatMap { firstIndex(of: $0) } ?? -1
  }

  func jsLastIndexOf(_ element: Element) -> Int {
    lastIndex(of: element) ?? -1
  }
}

public extension Array {
  func jsAt(_ index: Int) -> Element? {
    let i = index < 0 ? count + index : index
    return i >= 0 && i < count ? self[i] : nil
  }

  func jsSliced(_ start: Int, _ end: Int? = nil) -> [Element] {
    func clamp(_ i: Int) -> Int { i < 0 ? Swift.max(count + i, 0) : Swift.min(i, count) }
    let from = clamp(start)
    let to = clamp(end ?? count)
    return from < to ? Array(self[from..<to]) : []
  }

  @discardableResult
  mutating func jsSplice(_ start: Int, _ deleteCount: Int? = nil, _ items: [Element] = []) -> [Element] {
    let from = start < 0 ? Swift.max(count + start, 0) : Swift.min(start, count)
    let removing = Swift.max(Swift.min(deleteCount ?? (count - from), count - from), 0)
    let removed = Array(self[from..<(from + removing)])
    replaceSubrange(from..<(from + removing), with: items)
    return removed
  }

  func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
    enumerated().sorted { a, b in
      if less(a.element, b.element) { return true }
      if less(b.element, a.element) { return false }
      return a.offset < b.offset
    }.map(\.element)
  }

  func jsSorted(by compare: (Element, Element) -> Int) -> [Element] {
    stableSorted { compare($0, $1) < 0 }
  }
}

public extension Array where Element == String {
  func jsSortedStrings() -> [String] {
    stableSorted(by: jsKeyPrecedes)
  }
}

public struct JSKey: Hashable, Sendable {
  public let text: String

  public init(_ text: String) { self.text = text }

  public static func == (a: JSKey, b: JSKey) -> Bool {
    var left = a.text
    var right = b.text
    return left.withUTF8 { a in
      right.withUTF8 { b in
        guard a.count == b.count else { return false }
        guard !a.isEmpty else { return true }
        return memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
      }
    }
  }

  public func hash(into hasher: inout Hasher) {
    var text = text
    text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
  }
}

struct Identity<Element: Hashable>: Hashable {
  let element: Element

  init(_ element: Element) { self.element = element }

  static func == (a: Identity, b: Identity) -> Bool {
    if let x = a.element as? String, let y = b.element as? String { return x.utf16.elementsEqual(y.utf16) }
    return a.element == b.element
  }

  func hash(into hasher: inout Hasher) {
    if let text = element as? String {
      for unit in text.utf16 { hasher.combine(unit) }
    } else {
      hasher.combine(element)
    }
  }
}

extension Identity: Sendable where Element: Sendable {}

public struct OrderedSet<Element: Hashable>: Sequence {
  public private(set) var elements: [Element] = []
  private var members: Set<Identity<Element>> = []

  public init() {}

  public init(_ items: some Sequence<Element>) {
    for item in items { insert(item) }
  }

  public var count: Int { elements.count }
  public var isEmpty: Bool { elements.isEmpty }
  public func contains(_ item: Element) -> Bool { members.contains(Identity(item)) }

  @discardableResult
  public mutating func insert(_ item: Element) -> Bool {
    guard members.insert(Identity(item)).inserted else { return false }
    elements.append(item)
    return true
  }

  public mutating func remove(_ item: Element) {
    guard members.remove(Identity(item)) != nil else { return }
    elements.removeAll { Identity($0) == Identity(item) }
  }

  public func makeIterator() -> IndexingIterator<[Element]> { elements.makeIterator() }
}

extension OrderedSet: Sendable where Element: Sendable {}
extension OrderedSet: Equatable {
  public static func == (a: OrderedSet, b: OrderedSet) -> Bool { a.elements.map(Identity.init) == b.elements.map(Identity.init) }
}

public struct OrderedDict<Key: Hashable, Value>: Sequence {
  public private(set) var keys: [Key] = []
  private var storage: [Identity<Key>: Value] = [:]

  public init() {}

  public var count: Int { keys.count }
  public var isEmpty: Bool { keys.isEmpty }
  public var values: [Value] { keys.map { storage[Identity($0)]! } }

  public subscript(key: Key) -> Value? {
    get { storage[Identity(key)] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: Identity(key)) == nil { keys.append(key) }
      } else if storage.removeValue(forKey: Identity(key)) != nil {
        keys.removeAll { Identity($0) == Identity(key) }
      }
    }
  }

  public subscript(key: Key, default value: @autoclosure () -> Value) -> Value {
    get { storage[Identity(key)] ?? value() }
    set { self[key] = newValue }
  }

  public func makeIterator() -> IndexingIterator<[(key: Key, value: Value)]> {
    keys.map { (key: $0, value: storage[Identity($0)]!) }.makeIterator()
  }
}

extension OrderedDict: Sendable where Key: Sendable, Value: Sendable {}
extension OrderedDict: Equatable where Value: Equatable {
  public static func == (a: OrderedDict, b: OrderedDict) -> Bool { a.keys.map(Identity.init) == b.keys.map(Identity.init) && a.storage == b.storage }
}
