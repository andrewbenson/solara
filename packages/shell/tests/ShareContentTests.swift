import XCTest
@testable import SolaraShellCore

final class ShareContentTests: XCTestCase {
  let page = "https://news.example/story?id=7&utm_source=x"

  func testALinkWinsOverTheWordARightClickSelects() {
    let context = ShareContext(selection: "tracked", link: "https://a.example/?utm_source=x", page: page)
    XCTAssertEqual(ShareContent.choose(context), .link(URL(string: "https://a.example/")!, title: nil))
  }

  func testSelectedTextIsSharedAsItIs() {
    let context = ShareContext(selection: "  a quote  ", page: page)
    XCTAssertEqual(ShareContent.choose(context), .text("  a quote  "))
    XCTAssertEqual(ShareContent.menuItem(for: context)?.title, "Share Selection…")
  }

  func testTextInAFieldIsNotOfferedButThePageIsNeither() {
    let context = ShareContext(selection: "typed", page: page, editable: true)
    XCTAssertNil(ShareContent.choose(context))
    XCTAssertNil(ShareContent.menuItem(for: context))
  }

  func testAnImageIsSharedEvenWhenItsSourceIsNotAWebAddress() {
    XCTAssertEqual(ShareContent.choose(ShareContext(source: "https://cdn.example/a.png?utm_medium=y", mediaType: "image", page: page)),
      .image(source: URL(string: "https://cdn.example/a.png"), title: nil))
    XCTAssertEqual(ShareContent.choose(ShareContext(source: "data:image/png;base64,AAAA", mediaType: "image", page: page)),
      .image(source: nil, title: nil))
    XCTAssertEqual(ShareContent.menuItem(for: ShareContext(mediaType: "image", page: page))?.id, "share:image")
  }

  func testMediaSharesItsSourceOrFallsBackToThePage() {
    XCTAssertEqual(ShareContent.choose(ShareContext(source: "https://v.example/clip.mp4?fbclid=1", mediaType: "video", page: page, title: "Clip")),
      .media(URL(string: "https://v.example/clip.mp4")!, title: "Clip"))
    XCTAssertEqual(ShareContent.choose(ShareContext(source: "blob:https://v.example/1", mediaType: "video", page: page, title: "Clip")),
      .link(URL(string: "https://news.example/story?id=7")!, title: "Clip"))
    XCTAssertEqual(ShareContent.menuItem(for: ShareContext(source: "https://a.example/s.mp3", mediaType: "audio", page: page))?.title, "Share Audio…")
    XCTAssertEqual(ShareContent.menuItem(for: ShareContext(source: "https://a.example/s.mp4", mediaType: "video", page: page))?.title, "Share Video…")
  }

  func testALinkIsSharedWithoutItsTrackers() {
    let context = ShareContext(link: "https://shop.example/item?id=42&gclid=abc", page: page)
    XCTAssertEqual(ShareContent.choose(context), .link(URL(string: "https://shop.example/item?id=42")!, title: nil))
    XCTAssertEqual(ShareContent.menuItem(for: context)?.title, "Share Link…")
  }

  func testOtherwiseThePageIsShared() {
    let context = ShareContext(page: page, title: "Story")
    XCTAssertEqual(ShareContent.choose(context), .link(URL(string: "https://news.example/story?id=7")!, title: "Story"))
    XCTAssertEqual(ShareContent.menuItem(for: context)?.title, "Share Page…")
    XCTAssertNil(ShareContent.choose(ShareContext(link: "mailto:a@b.example", page: "solara://history")))
  }

  func testALinkThatIsNotAWebAddressOffersThePageUnderThePagesName() {
    let context = ShareContext(link: "mailto:a@b.example", page: page, title: "Story")
    XCTAssertEqual(ShareContent.choose(context), .link(URL(string: "https://news.example/story?id=7")!, title: "Story"))
    XCTAssertEqual(ShareContent.menuItem(for: context)?.id, "share:page")
    XCTAssertEqual(ShareContent.menuItem(for: context)?.title, "Share Page…")
  }

  func testTheEngineFieldsDecode() {
    let context = ShareContext(["selection": "s", "link": "l", "source": "src", "mediaType": "image", "page": "p", "title": "t", "editable": true])
    XCTAssertEqual(context, ShareContext(selection: "s", link: "l", source: "src", mediaType: "image", page: "p", title: "t", editable: true))
  }
}
