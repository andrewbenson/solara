import Foundation

public typealias JSONObject = JSMap<JSONValue>

public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var number: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var int: Int? {
    if case .number(let value) = self, value.rounded() == value, abs(value) < 9.0e15 { return Int(value) }
    return nil
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var object: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var truthy: Bool {
    switch self {
    case .null: false
    case .bool(let value): value
    case .number(let value): value != 0 && !value.isNaN
    case .string(let value): !value.isEmpty
    case .array, .object: true
    }
  }

  public subscript(key: String) -> JSONValue? {
    object?[key]
  }

  public static func == (a: JSONValue, b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): true
    case (.bool(let x), .bool(let y)): x == y
    case (.number(let x), .number(let y)): x == y
    case (.string(let x), .string(let y)): JSKey(x) == JSKey(y)
    case (.array(let x), .array(let y)): x == y
    case (.object(let x), .object(let y)): x == y
    default: false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case .null: hasher.combine(0)
    case .bool(let x): hasher.combine(x)
    case .number(let x): hasher.combine(x)
    case .string(let x): hasher.combine(JSKey(x))
    case .array(let x): hasher.combine(x)
    case .object(let x): hasher.combine(x)
    }
  }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

public extension JSONValue {
  init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
  init(_ value: Double) { self = .number(value) }
  init(_ value: Int) { self = .number(Double(value)) }
  init(_ value: Bool) { self = .bool(value) }
  init(_ values: [String]) { self = .array(values.map(JSONValue.string)) }
}
