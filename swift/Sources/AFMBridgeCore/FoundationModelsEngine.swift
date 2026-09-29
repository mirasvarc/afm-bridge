import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

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

  public func makeSession(config: SessionConfig, tools: [ToolSpec], toolHandler: any ToolHandler) async throws
    -> any EngineSession
  {
    try Self.requireOnDevice(config.model ?? .onDevice)
    let systemModel = SystemLanguageModel(
      useCase: config.useCase == .contentTagging ? .contentTagging : .general,
      guardrails: config.guardrails == .permissiveContentTransformations ? .permissiveContentTransformations : .default)
    if case .unavailable(let reason, let message) = Self.status(of: systemModel) {
      throw RPCError.modelUnavailable(model: .onDevice, reason: reason, message: message)
    }
    let dynamicTools: [any Tool] = tools.map { DynamicTool(spec: $0, handler: toolHandler) }
    let session = LanguageModelSession(model: systemModel, tools: dynamicTools, instructions: config.instructions)
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

/// A tool whose arguments and execution live on the client.
struct DynamicTool: Tool {
  typealias Arguments = GeneratedContent
  typealias Output = String

  let spec: ToolSpec
  let handler: any ToolHandler

  var name: String { spec.name }
  var description: String { spec.description }
  var parameters: GenerationSchema { spec.parameters.schema }
  var includesSchemaInInstructions: Bool { spec.includeSchemaInInstructions }

  func call(arguments: GeneratedContent) async throws -> String {
    try await handler.callTool(name: spec.name, arguments: spec.parameters.normalize(JSON(arguments)))
  }
}

struct FoundationModelsSession: EngineSession {
  let systemModel: SystemLanguageModel
  let session: LanguageModelSession

  var model: ModelId { .onDevice }
  var contextSize: Int { systemModel.contextSize }

  func respond(
    _ request: GenerationRequest, onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
  ) async throws -> GenerationResult {
    do {
      let prompt = try Self.buildPrompt(request.prompt)
      let options = try Self.buildOptions(request.options)
      let result =
        if let schema = request.schema {
          try await structured(prompt, options, schema, request, onSnapshot)
        } else {
          try await text(prompt, options, request, onSnapshot)
        }
      // The framework may finish a generation even though our task was cancelled.
      try Task.checkCancellation()
      return result
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

  private func text(
    _ prompt: Prompt, _ options: GenerationOptions, _ request: GenerationRequest,
    _ onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
  ) async throws -> GenerationResult {
    if #available(macOS 27, *) {
      let context = Self.buildContextOptions(request.options, includeSchemaInPrompt: nil)
      if let onSnapshot {
        var last: LanguageModelSession.ResponseStream<String>.Snapshot?
        for try await snapshot in session.streamResponse(to: prompt, options: options, contextOptions: context) {
          try Task.checkCancellation()
          await onSnapshot(EngineSnapshot(text: snapshot.content))
          last = snapshot
        }
        return GenerationResult(text: last?.content ?? "", usage: last.map { Self.usage($0.usage) })
      }
      let response = try await session.respond(to: prompt, options: options, contextOptions: context)
      return GenerationResult(text: response.content, usage: Self.usage(response.usage))
    }
    try Self.rejectMacOS27Options(request.options)
    if let onSnapshot {
      var text = ""
      for try await snapshot in session.streamResponse(to: prompt, options: options) {
        try Task.checkCancellation()
        await onSnapshot(EngineSnapshot(text: snapshot.content))
        text = snapshot.content
      }
      return GenerationResult(text: text)
    }
    return GenerationResult(text: try await session.respond(to: prompt, options: options).content)
  }

  private func structured(
    _ prompt: Prompt, _ options: GenerationOptions, _ schema: ConvertedSchema, _ request: GenerationRequest,
    _ onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
  ) async throws -> GenerationResult {
    func result(_ raw: GeneratedContent, _ usage: Usage?) -> GenerationResult {
      let content = schema.normalize(JSON(raw))
      return GenerationResult(text: content.serialized, content: content, usage: usage)
    }
    func snapshot(_ raw: GeneratedContent) -> EngineSnapshot {
      let partial = JSON(raw)
      return EngineSnapshot(text: partial.serialized, partial: partial)
    }

    if #available(macOS 27, *) {
      let context = Self.buildContextOptions(request.options, includeSchemaInPrompt: request.includeSchemaInPrompt)
      if let onSnapshot {
        var last: LanguageModelSession.ResponseStream<GeneratedContent>.Snapshot?
        for try await s in session.streamResponse(
          to: prompt, schema: schema.schema, options: options, contextOptions: context)
        {
          try Task.checkCancellation()
          await onSnapshot(snapshot(s.rawContent))
          last = s
        }
        guard let last else { throw RPCError.internalError("The model produced no output") }
        return result(last.rawContent, Self.usage(last.usage))
      }
      let response = try await session.respond(
        to: prompt, schema: schema.schema, options: options, contextOptions: context)
      return result(response.rawContent, Self.usage(response.usage))
    }
    try Self.rejectMacOS27Options(request.options)
    if let onSnapshot {
      var last: GeneratedContent?
      for try await s in session.streamResponse(
        to: prompt, schema: schema.schema, includeSchemaInPrompt: request.includeSchemaInPrompt, options: options)
      {
        try Task.checkCancellation()
        await onSnapshot(snapshot(s.rawContent))
        last = s.rawContent
      }
      guard let last else { throw RPCError.internalError("The model produced no output") }
      return result(last, nil)
    }
    let response = try await session.respond(
      to: prompt, schema: schema.schema, includeSchemaInPrompt: request.includeSchemaInPrompt, options: options)
    return result(response.rawContent, nil)
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
    let texts = input.parts.compactMap { part -> String? in
      if case .text(let t) = part { return t }
      return nil
    }
    guard texts.count < input.parts.count else { return Prompt(texts.joined(separator: "\n\n")) }
    guard #available(macOS 27, *) else {
      throw RPCError.unsupportedOS(feature: "Image input", requiredVersion: "27.0")
    }
    var prompts: [Prompt] = []
    for (index, part) in input.parts.enumerated() {
      switch part {
      case .text(let t):
        prompts.append(Prompt(t))
      case .imagePath(let path):
        guard FileManager.default.isReadableFile(atPath: path) else {
          throw RPCError.invalidParams("Image file not found or not readable: \(path)", path: "prompt/\(index)/path")
        }
        prompts.append(Prompt(Attachment(imageURL: URL(fileURLWithPath: path))))
      case .imageData(let base64, _):
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
          throw RPCError.invalidParams("Image data is not a decodable base64 image", path: "prompt/\(index)/data")
        }
        prompts.append(Prompt(Attachment(image)))
      }
    }
    return Prompt(prompts)
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

  static func rejectMacOS27Options(_ input: GenerationOptionsInput) throws {
    if input.reasoningLevel != nil {
      throw RPCError.unsupportedOS(feature: "reasoningLevel", requiredVersion: "27.0")
    }
  }

  @available(macOS 27, *)
  static func buildContextOptions(_ input: GenerationOptionsInput, includeSchemaInPrompt: Bool?) -> ContextOptions {
    let level: ContextOptions.ReasoningLevel? =
      switch input.reasoningLevel {
      case .none: nil
      case .light: .light
      case .moderate: .moderate
      case .deep: .deep
      }
    return ContextOptions(includeSchemaInPrompt: includeSchemaInPrompt, reasoningLevel: level)
  }

  @available(macOS 27, *)
  static func usage(_ u: LanguageModelSession.Usage) -> Usage {
    Usage(
      inputTokens: u.input.totalTokenCount, cachedInputTokens: u.input.cachedTokenCount,
      outputTokens: u.output.totalTokenCount, reasoningTokens: u.output.reasoningTokenCount)
  }
}
