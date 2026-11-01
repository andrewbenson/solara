import SolaraModel
import Testing
@testable import SolaraUI

@Suite struct PageExecutionMemoryTests {
  private func request(_ seq: Int, _ url: String = "https://page.example/", userInitiated: Bool = true) -> TabNavigationRequest {
    TabNavigationRequest(seq: seq, url: url, userInitiated: userInitiated)
  }

  @Test func constructorAKeepsAWhenSameURLBWasIgnored() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.finishStaging()
    memory.constructorCaptured(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: true) == 1)
  }

  @Test func acceptedBOverridesTheConstructorCandidate() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.accepted(url: "https://page.example/")
    memory.finishStaging()
    memory.constructorCaptured(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: true) == 2)
    #expect(memory.executed(url: "https://page.example/", constructor: false) == 2)
  }

  @Test func arbitraryRawLoadClearsKnownExecution() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.accepted(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: false) == 2)
    memory.stage(navigation: request(2), url: "https://raw.example/", userInitiated: true)
    memory.accepted(url: "https://raw.example/")
    #expect(memory.executed(url: "https://raw.example/", constructor: false) == nil)
    #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
  }

  @Test func stagingCannotLeakPastItsInvocation() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.finishStaging()
    memory.accepted(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: false) == nil)
    #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
  }

  @Test func acceptedDifferentURLNeverBorrowsStagedSequence() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.accepted(url: "https://different.example/")
    memory.constructorCaptured(url: "https://different.example/")
    #expect(memory.executed(url: "https://different.example/", constructor: true) == nil)
    #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
    memory.stage(navigation: request(3, "https://different.example/"), url: "https://different.example/", userInitiated: true)
    memory.accepted(url: "https://different.example/")
    #expect(memory.executed(url: "https://different.example/", constructor: false) == 3)
  }

  @Test func differentInitiationCannotClaimWorkspaceNavigation() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: false)
    memory.accepted(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: false) == nil)
  }

  @Test func unknownExecutionAndNonconstructorCannotClaimInitialRequest() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.constructorCaptured(url: "https://page.example/")
    #expect(memory.executed(url: "https://other.example/", constructor: true) == nil)
    #expect(memory.executed(url: "https://page.example/", constructor: false) == nil)
    memory.constructorCaptured(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: true) == 1)
  }

  @Test func capturedConstructorACannotBeRelabeledByAcceptedBThenSameURLC() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.constructorCaptured(url: "https://page.example/")
    memory.stage(navigation: request(2, "https://other.example/"), url: "https://other.example/", userInitiated: true)
    memory.accepted(url: "https://other.example/")
    memory.stage(navigation: request(3), url: "https://page.example/", userInitiated: true)
    memory.accepted(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: true) == 1)
    #expect(memory.executed(url: "https://page.example/", constructor: false) == 3)
  }

  @Test func unknownConstructorCaptureCannotBorrowLaterAcceptedSequence() {
    var memory = PageExecutionMemory(initial: request(1))
    memory.constructorCaptured(url: "https://unknown.example/")
    memory.stage(navigation: request(2, "https://unknown.example/"), url: "https://unknown.example/", userInitiated: true)
    memory.accepted(url: "https://unknown.example/")
    #expect(memory.executed(url: "https://unknown.example/", constructor: true) == nil)
    #expect(memory.executed(url: "https://unknown.example/", constructor: false) == 2)
  }

  @Test func constructorWithoutCaptureNeverBorrowsInitialOrLatestRequest() {
    var memory = PageExecutionMemory(initial: request(1))
    #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
    memory.stage(navigation: request(2), url: "https://page.example/", userInitiated: true)
    memory.accepted(url: "https://page.example/")
    #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
    #expect(memory.executed(url: "https://page.example/", constructor: false) == 2)
  }

  @Test func unsafeSequencesNeverBecomeExecutionAuthority() {
    for seq in [-1, 9_007_199_254_740_992] {
      var memory = PageExecutionMemory(initial: request(seq))
      memory.constructorCaptured(url: "https://page.example/")
      #expect(memory.executed(url: "https://page.example/", constructor: true) == nil)
      memory.stage(navigation: request(seq), url: "https://page.example/", userInitiated: true)
      memory.accepted(url: "https://page.example/")
      #expect(memory.executed(url: "https://page.example/", constructor: false) == nil)
    }
  }
}
