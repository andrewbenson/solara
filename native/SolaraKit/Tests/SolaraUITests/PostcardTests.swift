import Foundation
import Testing
@testable import SolaraUI

struct PostcardTests {
  @Test func geometryKeepsTheOriginalCardOverhangAndPageSplit() {
    #expect(PostcardLayout.card(CGSize(width: 800, height: 600)) == CGRect(x: 520, y: -30, width: 320, height: 200))
    #expect(PostcardLayout.page(CGSize(width: 800, height: 600)) == CGRect(x: 32, y: 71.84, width: 736, height: 456.32))
    #expect(!PostcardLayout.visible(CGSize(width: 559, height: 600)))
    #expect(!PostcardLayout.visible(CGSize(width: 800, height: 419)))
    #expect(PostcardLayout.visible(CGSize(width: 560, height: 420)))
  }

  @Test func artworkKeepsRNsRoundedRgbMidpointUnderTheShader() {
    #expect(PostcardLayout.artworkFill(["#98beab", "#2a4d40"]) == CSSColor("#618676"))
    #expect(PostcardLayout.artworkFill(["#000000", "#ffffff"]) == CSSColor("#808080"))
    #expect(PostcardLayout.artworkFill(["#010101", "#202020"]) == CSSColor("#111111"))
    #expect(PostcardLayout.artworkFill(["invalid", "#ffffff"]) == nil)
  }

  @Test func malformedAndIncompleteStateIsRejected() {
    #expect(PostcardState.decode("invalid") == nil)
    #expect(PostcardState.decode("{}") == nil)
    #expect(PostcardState.decode("{\"notes\":{\"version\":\"1.0\",\"date\":\"September 2026\",\"title\":\"Hello\",\"summary\":\"Summary\",\"items\":[]},\"profileId\":\"p\",\"dark\":false,\"tokens\":{},\"colors\":[\"#ffffff\",\"#000000\"],\"iconUri\":\"\",\"product\":\"Solara\",\"presentationId\":\"receipt\"}")?.notes.version == "1.0")
  }
}
