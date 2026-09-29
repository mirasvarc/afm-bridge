/// Abstraction over the language model so the server logic can be tested
/// without FoundationModels. `FoundationModelsEngine` is the real implementation.
public protocol ModelEngine: Sendable {
  func status(model: ModelId) async -> ModelStatus
  func tokenCount(model: ModelId, text: String) async throws -> Int
  func makeSession(config: SessionConfig, tools: [ToolSpec], toolHandler: any ToolHandler) async throws
    -> any EngineSession
}

/// A tool defined by the client. Calls go back to the client through `ToolHandler`.
public struct ToolSpec: Sendable {
  public var name: String
  public var description: String
  public var parameters: ConvertedSchema
  public var includeSchemaInInstructions: Bool

  public init(name: String, description: String, parameters: ConvertedSchema, includeSchemaInInstructions: Bool = true)
  {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.includeSchemaInInstructions = includeSchemaInInstructions
  }
}

/// Executes a tool call on the client (`tool/call`) and returns its output.
public protocol ToolHandler: Sendable {
  func callTool(name: String, arguments: JSON) async throws -> String
}

public struct GenerationRequest: Sendable {
  public var prompt: PromptInput
  public var options: GenerationOptionsInput
  /// Structured output; `nil` generates plain text.
  public var schema: ConvertedSchema?
  public var includeSchemaInPrompt: Bool

  public init(
    prompt: PromptInput, options: GenerationOptionsInput = .init(), schema: ConvertedSchema? = nil,
    includeSchemaInPrompt: Bool = true
  ) {
    self.prompt = prompt
    self.options = options
    self.schema = schema
    self.includeSchemaInPrompt = includeSchemaInPrompt
  }
}

/// One streaming snapshot: cumulative text, and the partial value for structured output.
public struct EngineSnapshot: Sendable, Equatable {
  public var text: String
  public var partial: JSON?

  public init(text: String, partial: JSON? = nil) {
    self.text = text
    self.partial = partial
  }
}

public struct GenerationResult: Sendable, Equatable {
  public var text: String
  /// Parsed value when a schema was given.
  public var content: JSON?
  public var usage: Usage?

  public init(text: String, content: JSON? = nil, usage: Usage? = nil) {
    self.text = text
    self.content = content
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
  /// and calls it with every cumulative snapshot.
  func respond(
    _ request: GenerationRequest, onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
  ) async throws -> GenerationResult
  func prewarm(promptPrefix: String?)
  func info() async -> SessionInfo
}
