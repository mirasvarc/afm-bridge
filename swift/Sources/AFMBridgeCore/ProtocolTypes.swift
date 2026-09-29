import Foundation

/// Protocol versions this server can speak. See PROTOCOL.md section 3.
public let supportedProtocolVersions = [1]
public let serverName = "afm-bridge-server"
public let serverVersion = "0.1.0"

public enum ModelId: String, Sendable, Codable, CaseIterable {
  case onDevice = "on-device"
  case privateCloud = "private-cloud"
}

public enum UnavailableReason: String, Sendable, Codable {
  case deviceNotEligible
  case appleIntelligenceNotEnabled
  case modelNotReady
  case systemNotReady
  case unsupportedOS
  case requiresEntitlement
  case unknown
}

public enum ModelStatus: Sendable, Equatable {
  case available(contextSize: Int, variant: String?, capabilities: [String], supportedLanguages: [String])
  case unavailable(reason: UnavailableReason, message: String)

  public var json: JSON {
    switch self {
    case .available(let contextSize, let variant, let capabilities, let languages):
      var o: [String: JSON] = [
        "available": true,
        "contextSize": .int(contextSize),
        "capabilities": .array(capabilities.map { .string($0) }),
        "supportedLanguages": .array(languages.map { .string($0) }),
      ]
      if let variant { o["variant"] = .string(variant) }
      return .object(o)
    case .unavailable(let reason, let message):
      return ["available": false, "reason": .string(reason.rawValue), "message": .string(message)]
    }
  }
}

public enum Sampling: Sendable, Equatable, Decodable {
  case greedy
  case topK(k: Int, seed: UInt64?)
  case topP(threshold: Double, seed: UInt64?)

  private enum CodingKeys: String, CodingKey { case mode, k, threshold, seed }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .mode) {
    case "greedy": self = .greedy
    case "topK":
      self = .topK(k: try c.decode(Int.self, forKey: .k), seed: try c.decodeIfPresent(UInt64.self, forKey: .seed))
    case "topP":
      self = .topP(
        threshold: try c.decode(Double.self, forKey: .threshold),
        seed: try c.decodeIfPresent(UInt64.self, forKey: .seed))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .mode, in: c, debugDescription: "Unknown sampling mode '\(other)'")
    }
  }
}

public enum ToolCallingMode: String, Sendable, Decodable {
  case allowed, required, disallowed
}

public enum ReasoningLevel: String, Sendable, Decodable {
  case light, moderate, deep
}

public struct GenerationOptionsInput: Sendable, Equatable, Decodable {
  public var temperature: Double?
  public var maximumResponseTokens: Int?
  public var sampling: Sampling?
  public var toolCalling: ToolCallingMode?
  public var reasoningLevel: ReasoningLevel?

  public init(
    temperature: Double? = nil, maximumResponseTokens: Int? = nil, sampling: Sampling? = nil,
    toolCalling: ToolCallingMode? = nil, reasoningLevel: ReasoningLevel? = nil
  ) {
    self.temperature = temperature
    self.maximumResponseTokens = maximumResponseTokens
    self.sampling = sampling
    self.toolCalling = toolCalling
    self.reasoningLevel = reasoningLevel
  }
}

public enum PromptPart: Sendable, Equatable, Decodable {
  case text(String)
  case imagePath(String)
  case imageData(base64: String, mimeType: String?)

  private enum CodingKeys: String, CodingKey { case type, text, path, data, mimeType }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "text": self = .text(try c.decode(String.self, forKey: .text))
    case "image":
      if let path = try c.decodeIfPresent(String.self, forKey: .path) {
        self = .imagePath(path)
      } else {
        self = .imageData(
          base64: try c.decode(String.self, forKey: .data),
          mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType))
      }
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown prompt part type '\(other)'")
    }
  }
}

/// `Prompt = string | PromptPart[]`
public struct PromptInput: Sendable, Equatable, Decodable {
  public var parts: [PromptPart]

  public init(parts: [PromptPart]) { self.parts = parts }
  public init(_ text: String) { self.parts = [.text(text)] }

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) {
      parts = [.text(s)]
    } else {
      parts = try c.decode([PromptPart].self)
    }
  }
}

public struct Usage: Sendable, Equatable {
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var reasoningTokens: Int

  public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningTokens: Int) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
  }

  public var json: JSON {
    [
      "inputTokens": .int(inputTokens), "cachedInputTokens": .int(cachedInputTokens),
      "outputTokens": .int(outputTokens), "reasoningTokens": .int(reasoningTokens),
    ]
  }
}

// MARK: - Method params

struct InitializeParams: Decodable {
  struct ClientInfo: Decodable {
    var name: String
    var version: String
  }
  var protocolVersion: Int
  var client: ClientInfo?
}

struct ModelParams: Decodable {
  var model: ModelId?
}

struct TokenCountParams: Decodable {
  var model: ModelId?
  var text: String
}

public enum Guardrails: String, Sendable, Decodable {
  case `default`
  case permissiveContentTransformations
}

public enum UseCase: String, Sendable, Decodable {
  case general, contentTagging
}

public struct SessionConfig: Sendable, Decodable {
  public var model: ModelId?
  public var instructions: String?
  public var tools: [JSON]?
  public var guardrails: Guardrails?
  public var useCase: UseCase?

  public init(
    model: ModelId? = nil, instructions: String? = nil, tools: [JSON]? = nil, guardrails: Guardrails? = nil,
    useCase: UseCase? = nil
  ) {
    self.model = model
    self.instructions = instructions
    self.tools = tools
    self.guardrails = guardrails
    self.useCase = useCase
  }
}

struct RespondParams: Decodable {
  var sessionId: String
  var prompt: PromptInput
  var options: GenerationOptionsInput?
  var schema: JSON?
  var includeSchemaInPrompt: Bool?
  var stream: Bool?
}

struct SessionIdParams: Decodable {
  var sessionId: String
}

struct PrewarmParams: Decodable {
  var sessionId: String
  var promptPrefix: String?
}

struct CancelParams: Decodable {
  var id: RequestID
}
