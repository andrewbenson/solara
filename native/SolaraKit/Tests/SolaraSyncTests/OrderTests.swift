@testable import SolaraSync
import Testing

struct OrderTests {
  @Test func anAnchorThatIsNotBase62IsReplacedAsOrderTsReplacesIt() throws {
    let cases: [([String?], [String])] = [
      (["a0", "b", "z", "\u{1F600}", nil, nil], ["J", "b", "z", "zV", "zl", "zt"]),
      (["\u{FFFD}", "m", "\u{e9}", nil], ["O", "m", "t", "x"]),
      ([nil, "a\u{1F600}", "b", "-", "c"], ["J", "S", "b", "bV", "c"]),
      (["V", "\u{1F600}", "V1"], ["V", "V0V", "V1"]),
    ]
    for (existing, expected) in cases {
      #expect(try assignPositions(existing) == expected, "\(existing)")
    }
  }
}
