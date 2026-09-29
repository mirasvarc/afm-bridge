import Foundation
import FoundationModels

/// The real engine backed by Apple's FoundationModels framework.
public struct FoundationModelsEngine: ModelEngine {
  public init() {}

  public func status(model: ModelId) async -> ModelStatus {
    switch model {
    case .onDevice: Self.status(of: SystemLanguageModel.default)
    case .privateCloud: .unavailable(reason: .requiresEntitlement, message: Self.privateCloudMessage)
    }
  }

  public func tokenCount(model: ModelId, text: String) async throws -> Int {
    try Self.requireOnDevice(model)
    guard #available(macOS 26.4, *) else {
      throw RPCError.unsupportedOS(feature: "Token counting", requiredVersion: "26.4")
    }
    return try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
  }

  public func makeSession(config: SessionConfig) async throws -> any EngineSession {
    try Self.requireOnDevice(config.model ?? .onDevice)
    if let tools = config.tools, !tools.isEmpty {
      throw RPCError.invalidParams(
        "Tool calling is not implemented in this version of afm-bridge-server yet", path: "tools")
    }
    let systemModel = SystemLanguageModel(
      useCase: config.useCase == .contentTagging ? .contentTagging : .general,
      guardrails: config.guardrails == .permissiveContentTransformations ? .permissiveContentTransformations : .default)
    if case .unavailable(let reason, let message) = Self.status(of: systemModel) {
      throw RPCError.modelUnavailable(model: .onDevice, reason: reason, message: message)
    }
    let session = LanguageModelSession(model: systemModel, tools: [], instructions: config.instructions)
    return FoundationModelsSession(systemModel: systemModel, session: session)
  }

  // MARK: - Availability

  static let privateCloudMessage =
    "Private Cloud Compute needs the restricted entitlement com.apple.developer.private-cloud-compute and is not supported by afm-bridge yet"

  static func status(of m: SystemLanguageModel) -> ModelStatus {
    switch m.availability {
    case .available:
      var capabilities: [String] = []
      var variant: String?
      if #available(macOS 27, *) {
        let all: [LanguageModelCapabilities.Capability] = [.vision, .guidedGeneration, .reasoning, .toolCalling]
        capabilities = all.filter { m.capabilities.contains($0) }.compactMap(ErrorMapper.capabilityName)
        variant = m.variant.displayName
      }
      return .available(
        contextSize: m.contextSize, variant: variant, capabilities: capabilities,
        supportedLanguages: m.supportedLanguages.map(\.minimalIdentifier).sorted())
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible:
        return .unavailable(
          reason: .deviceNotEligible, message: "This Mac cannot run Apple Intelligence (Apple silicon is required)")
      case .appleIntelligenceNotEnabled:
        return .unavailable(
          reason: .appleIntelligenceNotEnabled,
          message: "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri")
      case .modelNotReady:
        return .unavailable(
          reason: .modelNotReady, message: "The on-device model is not ready yet (it may still be downloading)")
      @unknown default:
        return .unavailable(reason: .unknown, message: "The on-device model is unavailable: \(reason)")
      }
    }
  }

  static func requireOnDevice(_ model: ModelId) throws {
    if model == .privateCloud {
      throw RPCError.modelUnavailable(model: .privateCloud, reason: .requiresEntitlement, message: privateCloudMessage)
    }
  }
}

struct FoundationModelsSession: EngineSession {
  let systemModel: SystemLanguageModel
  let session: LanguageModelSession

  var model: ModelId { .onDevice }
  var contextSize: Int { systemModel.contextSize }

  func respond(
    _ request: GenerationRequest, onSnapshot: (@Sendable (String) async -> Void)?
  ) async throws -> GenerationResult {
    do {
      return try await generate(request, onSnapshot: onSnapshot)
    } catch {
      var mapped = ErrorMapper.map(error)
      // macOS 27.0 still throws the legacy GenerationError for context overflow,
      // which carries no numbers. The context size is known here, so add it.
      if mapped.type == "contextWindowExceeded", mapped.data["contextSize"] == nil {
        mapped.data["contextSize"] = .int(contextSize)
      }
      throw mapped
    }
  }

  private func generate(
    _ request: GenerationRequest, onSnapshot: (@Sendable (String) async -> Void)?
  ) async throws -> GenerationResult {
    let prompt = try Self.buildPrompt(request.prompt)
    let options = try Self.buildOptions(request.options)
    let result: GenerationResult
    if #available(macOS 27, *) {
      let context = Self.buildContextOptions(request.options)
      if let onSnapshot {
        var last: LanguageModelSession.ResponseStream<String>.Snapshot?
        for try await snapshot in session.streamResponse(to: prompt, options: options, contextOptions: context) {
          try Task.checkCancellation()
          await onSnapshot(snapshot.content)
          last = snapshot
        }
        result = GenerationResult(text: last?.content ?? "", usage: last.map { Self.usage($0.usage) })
      } else {
        let response = try await session.respond(to: prompt, options: options, contextOptions: context)
        result = GenerationResult(text: response.content, usage: Self.usage(response.usage))
      }
    } else {
      if request.options.reasoningLevel != nil {
        throw RPCError.unsupportedOS(feature: "reasoningLevel", requiredVersion: "27.0")
      }
      if let onSnapshot {
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
          try Task.checkCancellation()
          await onSnapshot(snapshot.content)
          text = snapshot.content
        }
        result = GenerationResult(text: text)
      } else {
        result = GenerationResult(text: try await session.respond(to: prompt, options: options).content)
      }
    }
    // The framework may finish a generation even though our task was cancelled.
    try Task.checkCancellation()
    return result
  }

  func prewarm(promptPrefix: String?) {
    session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) })
  }

  func info() async -> SessionInfo {
    var info = SessionInfo(contextSize: contextSize)
    if #available(macOS 26.4, *) {
      info.historyTokenCount = try? await systemModel.tokenCount(for: session.transcript)
    }
    if #available(macOS 27, *) {
      info.usage = Self.usage(session.usage)
    }
    return info
  }

  // MARK: - Conversions

  static func buildPrompt(_ input: PromptInput) throws -> Prompt {
    var texts: [String] = []
    for (index, part) in input.parts.enumerated() {
      switch part {
      case .text(let t): texts.append(t)
      case .imagePath, .imageData:
        throw RPCError.invalidParams(
          "Image input is not implemented in this version of afm-bridge-server yet", path: "prompt/\(index)")
      }
    }
    return Prompt(texts.joined(separator: "\n\n"))
  }

  static func buildOptions(_ input: GenerationOptionsInput) throws -> GenerationOptions {
    var o = GenerationOptions()
    o.temperature = input.temperature
    o.maximumResponseTokens = input.maximumResponseTokens
    switch input.sampling {
    case .none: break
    case .greedy: o.samplingMode = .greedy
    case .topK(let k, let seed): o.samplingMode = .random(top: k, seed: seed)
    case .topP(let threshold, let seed): o.samplingMode = .random(probabilityThreshold: threshold, seed: seed)
    }
    if let mode = input.toolCalling {
      guard #available(macOS 27, *) else {
        throw RPCError.unsupportedOS(feature: "toolCalling option", requiredVersion: "27.0")
      }
      o.toolCallingMode =
        switch mode {
        case .allowed: .allowed
        case .required: .required
        case .disallowed: .disallowed
        }
    }
    return o
  }

  @available(macOS 27, *)
  static func buildContextOptions(_ input: GenerationOptionsInput) -> ContextOptions {
    let level: ContextOptions.ReasoningLevel? =
      switch input.reasoningLevel {
      case .none: nil
      case .light: .light
      case .moderate: .moderate
      case .deep: .deep
      }
    return ContextOptions(reasoningLevel: level)
  }

  @available(macOS 27, *)
  static func usage(_ u: LanguageModelSession.Usage) -> Usage {
    Usage(
      inputTokens: u.input.totalTokenCount, cachedInputTokens: u.input.cachedTokenCount,
      outputTokens: u.output.totalTokenCount, reasoningTokens: u.output.reasoningTokenCount)
  }
}
