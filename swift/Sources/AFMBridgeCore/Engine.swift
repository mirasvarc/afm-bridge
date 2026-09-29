/// Abstraction over the language model so the server logic can be tested
/// without FoundationModels. `FoundationModelsEngine` is the real implementation.
public protocol ModelEngine: Sendable {
  func status(model: ModelId) async -> ModelStatus
  func tokenCount(model: ModelId, text: String) async throws -> Int
  func makeSession(config: SessionConfig) async throws -> any EngineSession
}

public struct GenerationRequest: Sendable {
  public var prompt: PromptInput
  public var options: GenerationOptionsInput

  public init(prompt: PromptInput, options: GenerationOptionsInput = .init()) {
    self.prompt = prompt
    self.options = options
  }
}

public struct GenerationResult: Sendable, Equatable {
  public var text: String
  public var usage: Usage?

  public init(text: String, usage: Usage? = nil) {
    self.text = text
    self.usage = usage
  }
}

public struct SessionInfo: Sendable, Equatable {
  public var contextSize: Int
  public var historyTokenCount: Int?
  public var usage: Usage?

  public init(contextSize: Int, historyTokenCount: Int? = nil, usage: Usage? = nil) {
    self.contextSize = contextSize
    self.historyTokenCount = historyTokenCount
    self.usage = usage
  }
}

public protocol EngineSession: Sendable {
  var model: ModelId { get }
  var contextSize: Int { get }
  /// Generates a response. When `onSnapshot` is non-nil the implementation streams
  /// and calls it with every cumulative snapshot of the text.
  func respond(
    _ request: GenerationRequest, onSnapshot: (@Sendable (String) async -> Void)?
  ) async throws -> GenerationResult
  func prewarm(promptPrefix: String?)
  func info() async -> SessionInfo
}
