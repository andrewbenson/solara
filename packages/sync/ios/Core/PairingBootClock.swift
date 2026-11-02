import Foundation
import Darwin

struct PairingBootClock {
  struct Sample { var milliseconds: UInt64; var epoch: Data }
  enum Failure: Error { case unavailable, overflow }

  static func sample() throws -> Sample {
    var length = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1, length <= 64 else { throw Failure.unavailable }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0, bytes.last == 0 else { throw Failure.unavailable }
    let boot = try epoch(String(cString: bytes))
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS else { throw Failure.unavailable }
    return Sample(milliseconds: try milliseconds(ticks: mach_continuous_time(), numerator: timebase.numer, denominator: timebase.denom), epoch: boot)
  }

  static func milliseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) throws -> UInt64 {
    guard numerator > 0, denominator > 0 else { throw Failure.unavailable }
    let divisor = UInt64(denominator) * 1000000
    let whole = ticks / divisor
    let remainder = ticks % divisor
    let product = whole.multipliedReportingOverflow(by: UInt64(numerator))
    let fractional = remainder.multipliedFullWidth(by: UInt64(numerator))
    guard !product.overflow, fractional.high < divisor else { throw Failure.overflow }
    let tail = divisor.dividingFullWidth(fractional).quotient
    let total = product.partialValue.addingReportingOverflow(tail)
    guard !total.overflow else { throw Failure.overflow }
    return total.partialValue
  }

  static func epoch(_ text: String) throws -> Data {
    guard text.count == 36, let value = UUID(uuidString: text), value.uuidString.lowercased() == text.lowercased() else { throw Failure.unavailable }
    var raw = value.uuid
    let data = withUnsafeBytes(of: &raw) { Data($0) }
    guard data.contains(where: { $0 != 0 }) else { throw Failure.unavailable }
    return data
  }
}
