import Foundation
import SolaraModel

public typealias HLC = String

let wallDigits = 9
let counterDigits = 4

func jsRadix36(_ value: Double) -> String {
  if value.isNaN { return "NaN" }
  if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
  if abs(value) < 9.0e15 { return String(Int64(value), radix: 36) }
  var digits: [Character] = []
  var rest = abs(value).rounded(.down)
  let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
  while rest > 0 {
    let digit = rest.truncatingRemainder(dividingBy: 36)
    digits.append(alphabet[Int(digit)])
    rest = (rest / 36).rounded(.down)
  }
  return (value < 0 ? "-" : "") + String(digits.reversed())
}

func padStart(_ text: String, _ length: Int) -> String {
  let count = text.utf16.count
  return count >= length ? text : String(repeating: "0", count: length - count) + text
}

public func jsParseInt36(_ text: Substring) -> Double {
  var scalars = text.unicodeScalars.drop { $0.properties.isWhitespace }
  var sign = 1.0
  if let first = scalars.first, first == "-" || first == "+" {
    if first == "-" { sign = -1 }
    scalars = scalars.dropFirst()
  }
  var value = 0.0
  var any = false
  for scalar in scalars {
    let digit: Int
    switch scalar.value {
    case 48...57: digit = Int(scalar.value) - 48
    case 97...122: digit = Int(scalar.value) - 87
    case 65...90: digit = Int(scalar.value) - 55
    default: digit = 36
    }
    if digit >= 36 { break }
    value = value * 36 + Double(digit)
    any = true
  }
  return any ? sign * value : .nan
}

func formatHLC(_ wall: Double, _ counter: Double, _ device: String) -> HLC {
  let floored = max(0, wall.rounded(.down))
  let clamped = wall.isNaN ? Double.nan : floored
  return "\(padStart(jsRadix36(clamped), wallDigits)).\(padStart(jsRadix36(counter), counterDigits)).\(device)"
}

func parseHLC(_ h: HLC) -> (wall: Double, counter: Double, device: String) {
  let parts = h.jsSplit(".")
  let wall = parts.count > 0 ? parts[0] : "0"
  let counter = parts.count > 1 ? parts[1] : "0"
  return (jsParseInt36(Substring(wall)), jsParseInt36(Substring(counter)), parts.dropFirst(2).joined(separator: "."))
}

public func hlcAfter(_ h: HLC, _ device: String) -> HLC {
  let (wall, counter, _) = parseHLC(h)
  return counter + 1 >= pow(36, Double(counterDigits)) ? formatHLC(wall + 1, 0, device) : formatHLC(wall, counter + 1, device)
}

public func hlcDevice(_ h: HLC) -> String { parseHLC(h).device }

public func editHLC(_ stamped: Stamped, _ device: String) -> HLC {
  let at = formatHLC(stamped.at, 0, device)
  let after = stamped.after.flatMap { $0.isEmpty ? nil : hlcAfter($0, device) }
  return if let after, jsKeyPrecedes(at, after) { after } else { at }
}

public func hlcWall(_ h: HLC) -> Double {
  jsParseInt36(Substring(String(h.utf16.prefix(wallDigits)) ?? ""))
}

public final class Clock: @unchecked Sendable {
  var wall: Double = 0
  var counter: Double = 0
  public let device: String
  let now: () -> Double

  public init(device: String, last: HLC? = nil, now: @escaping () -> Double) {
    self.device = device
    self.now = now
    if let last, !last.isEmpty { observe(last) }
  }

  public func tick() -> HLC {
    let t = now()
    if t > wall {
      wall = t
      counter = 0
    } else {
      counter += 1
    }
    return formatHLC(wall, counter, device)
  }

  public func at(_ time: Double) -> HLC {
    formatHLC(jsMin(time, now()), 0, device)
  }

  public func observe(_ h: HLC) {
    let parsed = parseHLC(h)
    if parsed.wall > wall || (parsed.wall == wall && parsed.counter > counter) {
      wall = parsed.wall
      counter = parsed.counter
    }
  }

  public var last: HLC { formatHLC(wall, counter, device) }
}

func jsMin(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  return min(a, b)
}
