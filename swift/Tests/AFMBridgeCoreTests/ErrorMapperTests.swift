import Foundation
import FoundationModels
import Testing

@testable import AFMBridgeCore

@Suite struct ErrorMapperTests {
  @Test func passesThroughRPCErrors() {
    #expect(ErrorMapper.map(RPCError.sessionNotFound("x")) == .sessionNotFound("x"))
  }

  @Test func mapsCancellation() {
    #expect(ErrorMapper.map(CancellationError()).type == "cancelled")
    #expect(ErrorMapper.map(CancellationError()).code == -32800)
  }

  @Test func mapsLegacyGenerationErrors() {
    let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "d")
    let cases: [(LanguageModelSession.GenerationError, String, Int)] = [
      (.exceededContextWindowSize(ctx), "contextWindowExceeded", -32030),
      (.guardrailViolation(ctx), "guardrailViolation", -32031),
      (.unsupportedLanguageOrLocale(ctx), "unsupportedLanguage", -32033),
      (.assetsUnavailable(ctx), "assetsUnavailable", -32012),
      (.decodingFailure(ctx), "decodingFailure", -32036),
      (.rateLimited(ctx), "rateLimited", -32037),
      (.concurrentRequests(ctx), "sessionBusy", -32021),
      (.unsupportedGuide(ctx), "unsupportedSchema", -32035),
    ]
    for (error, type, code) in cases {
      let mapped = ErrorMapper.map(error)
      #expect(mapped.type == type)
      #expect(mapped.code == code)
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0))))
  func mapsLanguageModelErrors() throws {
    guard #available(macOS 27, *) else { return }
    let overflow = ErrorMapper.map(
      LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long")))
    #expect(overflow.type == "contextWindowExceeded")
    #expect(overflow.data["contextSize"] == 8192)
    #expect(overflow.data["tokenCount"] == 9000)

    let language = ErrorMapper.map(
      LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("cs"), debugDescription: "no")))
    #expect(language.type == "unsupportedLanguage")
    #expect(language.data["languageCode"] == "cs")

    let capability = ErrorMapper.map(
      LanguageModelError.unsupportedCapability(.init(capability: .reasoning, debugDescription: "no")))
    #expect(capability.data["capability"] == "reasoning")

    let limited = ErrorMapper.map(
      LanguageModelError.rateLimited(.init(resetDate: Date(timeIntervalSince1970: 0), debugDescription: "slow down")))
    #expect(limited.data["resetDate"] == "1970-01-01T00:00:00Z")

    #expect(ErrorMapper.map(LanguageModelError.timeout(.init(debugDescription: "t"))).type == "timeout")
    #expect(ErrorMapper.map(LanguageModelSession.Error.concurrentRequests).type == "sessionBusy")
    #expect(
      ErrorMapper.map(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "q"))).type
        == "quotaExceeded")
  }

  @Test func fallsBackToGenerationFailed() {
    let mapped = ErrorMapper.map(NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "odd"]))
    #expect(mapped.type == "generationFailed")
    #expect(mapped.code == -32099)
    #expect(mapped.data["domain"] == "Test")
    #expect(mapped.data["code"] == 42)
  }
}
