import Testing

@testable import SolaraUI

@MainActor
@Suite struct PageRequestTests {
  @Test func decodesPictureForNativeCallers() throws {
    let value = PageValue.object(["data": .string("jpeg"), "frame": .array([.number(1), .number(2), .number(3), .number(4)])])
    let decoded = try PageRequest<PagePicture?>.capturePicture(0.5).decode(value)
    let picture = try #require(decoded)
    #expect(picture.data == "jpeg")
    #expect(picture.frame == [1, 2, 3, 4])
    #expect(try PageRequest<PagePicture?>.capturePicture(0.5).decode(.null) == nil)
    #expect(throws: PageRegistryError.invalidValue) {
      try PageRequest<PagePicture?>.capturePicture(0.5).decode(.object(["data": .string("jpeg"), "frame": .array([])]))
    }
  }

  @Test func evaluationDecodesThePostedJSONValue() throws {
    #expect(try PageRequest<PageValue>.evaluate("code").decode(.string("{\"value\":42}")) == .object(["value": .number(42)]))
    #expect(try PageRequest<PageValue>.evaluate("code").decode(.string("false")) == .bool(false))
    #expect(try PageRequest<PageValue>.evaluate("code").decode(.null) == .null)
    #expect(throws: PageRegistryError.invalidValue) { try PageRequest<PageValue>.evaluate("code").decode(.string("invalid")) }
  }

  @Test func navigationEntriesHaveTypedFields() throws {
    let request = PageRequest<[PageNavigationEntry]>.navigationEntries
    let entries = try request.decode(.array([.object(["url": .string("https://a/"), "title": .string("A"), "current": .bool(true)])]))
    #expect(entries == [PageNavigationEntry(url: "https://a/", title: "A", current: true)])
    #expect(throws: PageRegistryError.invalidValue) { try request.decode(.array([.object(["url": .number(1)])])) }
  }

  @Test func siteDataDistinguishesCountsFromFailure() throws {
    let request = PageRequest<PageSiteDataResult>.clearSiteData
    #expect(try request.decode(.object(["cookies": .number(4), "storage": .bool(true)])).cookies == .count(4))
    #expect(try request.decode(.object(["cookies": .bool(false), "storage": .bool(false)])).cookies == .failed)
    #expect(throws: PageRegistryError.invalidValue) { try request.decode(.object(["cookies": .bool(true), "storage": .bool(false)])) }
  }

  @Test func extensionActionHasNamedOutcomes() throws {
    let request = PageRequest<PageExtensionAction?>.executeExtensionAction("id")
    #expect(try request.decode(.string("popup")) == .popup)
    #expect(try request.decode(.null) == nil)
    #expect(throws: PageRegistryError.invalidValue) { try request.decode(.string("unknown")) }
  }

  @Test func voidRequestsRejectValues() throws {
    #expect(throws: PageRegistryError.invalidValue) { try PageRequest<Void>.reload.decode(.bool(true)) }
    try PageRequest<Void>.reload.decode(.null)
  }
}
