import Foundation

enum PairingBridgeFailure {
  static func perform<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch { throw NSError(domain: "SolaraPairing", code: 1, userInfo: [:]) }
  }
}
