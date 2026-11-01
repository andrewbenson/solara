import Testing
import SolaraModel
import SolaraOmnibox
@testable import SolaraUI

struct PageNativeReportTests {
  @Test func navigationCopiesFactsAndConvertsOnlyEngineURLs() throws {
    let payload: JSONValue = ["url": "chrome://version/", "committedUrl": "chrome://version/", "title": "Version",
      "isLoading": true, "canGoBack": false, "canGoForward": true, "themeColor": .null,
      "initialDocumentAccessed": true, "committedInitial": false]
    let report = try #require(PageNativeReport.report(name: "onNavigationChange", payload: payload))
    #expect(report["type"] == "navigation")
    #expect(report["url"]?.string == toAppUrl("chrome://version/"))
    #expect(report["committedUrl"]?.string == toAppUrl("chrome://version/"))
    #expect(report["themeColor"] == .null)
    #expect(report["initialDocumentAccessed"] == true)
    #expect(report["committedInitial"] == false)
    #expect(report["isLoading"] == true)
    #expect(report["generation"] == nil)
  }

  @Test func everyNativeFactUsesTheSameConversion() throws {
    let cases: [(String, JSONValue, String)] = [
      ("onReady", ["browserId": 42, "tabId": 8], "ready"),
      ("onMedia", ["playing": true, "muted": false], "media"),
      ("onDownloadNavigation", ["committedUrl": "chrome://version/", "skipped": false], "download"),
      ("onDiscarded", ["url": "chrome://version/"], "discarded"),
      ("onLoadError", ["url": "https://failed.test/"], "loadError")
    ]
    for (name, payload, type) in cases {
      let report = try #require(PageNativeReport.report(name: name, payload: payload))
      #expect(report["type"]?.string == type)
    }
    #expect(PageNativeReport.report(name: "onStatus", payload: ["text": "a"]) == nil)
    #expect(PageNativeReport.report(name: "onProgress", payload: ["progress": 0.5]) == nil)
  }

  @Test func malformedFactIsPreservedForTheStoreFailurePath() throws {
    let report = try #require(PageNativeReport.report(name: "onMedia", payload: ["playing": "invalid"]))
    #expect(report["playing"] == "invalid")
    #expect(PageNativeReport.report(name: "onMedia", payload: .null) == nil)
  }
}
