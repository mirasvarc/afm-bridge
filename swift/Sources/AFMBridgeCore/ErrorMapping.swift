import Foundation
import FoundationModels

/// Maps Swift errors (FoundationModels on macOS 26 and 27, cancellation, our own)
/// to protocol errors. The table lives in PROTOCOL.md section 7.
public enum ErrorMapper {
  public static func map(_ error: any Error) -> RPCError {
    if let e = error as? RPCError { return e }
    if error is CancellationError { return .cancelled }
    if #available(macOS 27, *), let mapped = mapMacOS27(error) { return mapped }
    if let e = error as? LanguageModelSession.GenerationError { return mapLegacy(e) }
    if let e = error as? LanguageModelSession.ToolCallError {
      return RPCError(
        code: -32040, type: "toolExecution",
        message: "Tool '\(e.tool.name)' failed: \(describe(e.underlyingError))",
        data: ["toolName": .string(e.tool.name), "message": .string(describe(e.underlyingError))])
    }
    let ns = error as NSError
    return RPCError(
      code: -32099, type: "generationFailed", message: describe(error),
      data: ["domain": .string(ns.domain), "code": .int(ns.code), "debug": .string(String(describing: error))])
  }

  @available(macOS 27, *)
  private static func mapMacOS27(_ error: any Error) -> RPCError? {
    if let e = error as? LanguageModelError {
      let message = describe(e)
      switch e {
      case .contextSizeExceeded(let c):
        return RPCError(
          code: -32030, type: "contextWindowExceeded", message: message,
          data: ["contextSize": .int(c.contextSize), "tokenCount": .int(c.tokenCount)])
      case .rateLimited(let c):
        var data: [String: JSON] = [:]
        if let date = c.resetDate { data["resetDate"] = .string(iso8601(date)) }
        return RPCError(code: -32037, type: "rateLimited", message: message, data: data)
      case .guardrailViolation:
        return RPCError(code: -32031, type: "guardrailViolation", message: message)
      case .refusal:
        return RPCError(code: -32032, type: "refusal", message: message)
      case .unsupportedCapability(let c):
        return RPCError(
          code: -32034, type: "unsupportedCapability", message: message,
          data: ["capability": .string(capabilityName(c.capability) ?? "unknown")])
      case .unsupportedTranscriptContent:
        return RPCError(
          code: -32034, type: "unsupportedCapability", message: message, data: ["capability": "transcriptContent"])
      case .unsupportedGenerationGuide(let c):
        var data: [String: JSON] = ["reason": .string(message), "path": ""]
        if let name = c.schemaName { data["path"] = .string(name) }
        return RPCError(code: -32035, type: "unsupportedSchema", message: message, data: data)
      case .unsupportedLanguageOrLocale(let c):
        return RPCError(
          code: -32033, type: "unsupportedLanguage", message: message,
          data: ["languageCode": .string(c.languageCode.identifier)])
      case .timeout:
        return RPCError(code: -32038, type: "timeout", message: message)
      @unknown default:
        return nil
      }
    }
    if let e = error as? LanguageModelSession.Error {
      switch e {
      case .concurrentRequests:
        return RPCError(code: -32021, type: "sessionBusy", message: describe(e))
      case .transcriptMutationWhileResponding:
        return RPCError(code: -32021, type: "sessionBusy", message: describe(e))
      @unknown default:
        return nil
      }
    }
    if let e = error as? SystemLanguageModel.Error {
      return RPCError(code: -32012, type: "assetsUnavailable", message: describe(e))
    }
    if let e = error as? GeneratedContent.ParsingError {
      return RPCError(
        code: -32036, type: "decodingFailure", message: describe(e), data: ["rawContent": .string(e.rawContent)])
    }
    if let e = error as? PrivateCloudComputeLanguageModel.Error {
      switch e {
      case .quotaLimitReached(let c):
        var data: [String: JSON] = [:]
        if let date = c.resetDate { data["resetDate"] = .string(iso8601(date)) }
        return RPCError(code: -32050, type: "quotaExceeded", message: describe(e), data: data)
      case .networkFailure:
        return RPCError(code: -32051, type: "networkFailure", message: describe(e))
      case .serviceUnavailable:
        return RPCError(code: -32052, type: "serviceUnavailable", message: describe(e))
      @unknown default:
        return nil
      }
    }
    return nil
  }

  private static func mapLegacy(_ e: LanguageModelSession.GenerationError) -> RPCError {
    let message = describe(e)
    switch e {
    case .exceededContextWindowSize:
      return RPCError(code: -32030, type: "contextWindowExceeded", message: message)
    case .assetsUnavailable:
      return RPCError(code: -32012, type: "assetsUnavailable", message: message)
    case .guardrailViolation:
      return RPCError(code: -32031, type: "guardrailViolation", message: message)
    case .unsupportedGuide:
      return RPCError(
        code: -32035, type: "unsupportedSchema", message: message, data: ["path": "", "reason": .string(message)])
    case .unsupportedLanguageOrLocale:
      return RPCError(code: -32033, type: "unsupportedLanguage", message: message)
    case .decodingFailure:
      return RPCError(code: -32036, type: "decodingFailure", message: message)
    case .rateLimited:
      return RPCError(code: -32037, type: "rateLimited", message: message)
    case .concurrentRequests:
      return RPCError(code: -32021, type: "sessionBusy", message: message)
    case .refusal:
      return RPCError(code: -32032, type: "refusal", message: message)
    @unknown default:
      return RPCError(code: -32099, type: "generationFailed", message: message)
    }
  }

  @available(macOS 27, *)
  static func capabilityName(_ c: LanguageModelCapabilities.Capability) -> String? {
    switch c {
    case .vision: "vision"
    case .guidedGeneration: "guidedGeneration"
    case .reasoning: "reasoning"
    case .toolCalling: "toolCalling"
    default: nil
    }
  }

  static func describe(_ error: any Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
    return String(describing: error)
  }

  private static func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}
