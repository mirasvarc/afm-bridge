import Foundation

/// Where outgoing messages go. `StdoutSink` in production, a collector in tests.
public protocol MessageSink: Sendable {
  func send(_ message: JSON) async
}

/// Writes one JSON message per line to stdout. If the parent closed the pipe,
/// there is nobody to talk to, so the process exits.
public actor StdoutSink: MessageSink {
  public init() {}

  public func send(_ message: JSON) async {
    let line = MessageEncoder.line(message) + "\n"
    do {
      try FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    } catch {
      Log.info("stdout closed (\(error)), exiting")
      exit(0)
    }
  }
}

/// Protocol logic: routing, session bookkeeping, concurrency and cancellation.
/// Lines are fed in order by `handle(line:)`; every request runs in its own task.
public actor Server {
  private struct SessionEntry {
    var session: any EngineSession
    var activeRequest: RequestID?
  }

  private let engine: any ModelEngine
  private let sink: any MessageSink
  private let onExit: @Sendable (Int32) -> Void
  private var initialized = false
  private var sessions: [String: SessionEntry] = [:]
  private var tasks: [RequestID: Task<Void, Never>] = [:]
  /// Requests sent to the client (`tool/call`) that wait for an answer.
  private var outgoing: [RequestID: PendingCall] = [:]
  private var nextOutgoingId = 1

  public init(engine: any ModelEngine, sink: any MessageSink, onExit: @escaping @Sendable (Int32) -> Void) {
    self.engine = engine
    self.sink = sink
    self.onExit = onExit
  }

  /// Number of requests currently running (used by tests).
  public var runningRequestCount: Int { tasks.count }

  public func handle(line: String) async {
    if line.allSatisfy(\.isWhitespace) { return }
    switch MessageParser.parse(line) {
    case .failure(let failure):
      Log.warn("rejecting message: \(failure.error.message)")
      await sink.send(MessageEncoder.error(id: failure.id, failure.error))
    case .success(.notification(let method, let params)):
      handleNotification(method: method, params: params)
    case .success(.response(let id, let result)):
      resolveOutgoing(id, result)
    case .success(.request(let id, let method, let params)):
      await handleRequest(id: id, method: method, params: params)
    }
  }

  /// stdin closed: the parent is gone or done. Cancel everything and exit.
  public func handleEOF() {
    Log.info("stdin closed, shutting down")
    cancelAll()
    onExit(0)
  }

  // MARK: - Dispatch

  private func handleNotification(method: String, params: JSON) {
    switch method {
    case "cancel":
      guard let p = try? JSONCoding.fromJSON(CancelParams.self, params) else {
        Log.warn("invalid cancel notification")
        return
      }
      Log.debug("cancel request \(p.id)")
      tasks[p.id]?.cancel()
      cancelOutgoing(parent: p.id)
    default:
      Log.debug("ignoring unknown notification \(method)")
    }
  }

  private func handleRequest(id: RequestID, method: String, params: JSON) async {
    if tasks[id] != nil {
      await sink.send(MessageEncoder.error(id: id, .invalidRequest("Request id \(id) is already in use")))
      return
    }
    // Validation that must happen in arrival order runs synchronously here;
    // the work itself runs in a task so long generations never block the reader.
    let work: @Sendable () async throws -> JSON
    do {
      if method == "initialize" {
        let p = try decode(InitializeParams.self, params)
        guard supportedProtocolVersions.contains(p.protocolVersion) else {
          throw RPCError.protocolVersionMismatch(requested: p.protocolVersion, supported: supportedProtocolVersions)
        }
        initialized = true
        if let client = p.client { Log.info("client \(client.name) \(client.version)") }
        work = { [engine] in try await Self.initializeResult(engine: engine) }
      } else {
        guard initialized else { throw RPCError.notInitialized }
        if method == "shutdown" {
          cancelAll()
          await sink.send(MessageEncoder.response(id: id, result: [:]))
          onExit(0)
          return
        }
        work = try route(id: id, method: method, params: params)
      }
    } catch {
      await sink.send(MessageEncoder.error(id: id, ErrorMapper.map(error)))
      return
    }

    let sink = self.sink
    tasks[id] = Task {
      let message: JSON
      do {
        let result = try await work()
        message =
          Task.isCancelled ? MessageEncoder.error(id: id, .cancelled) : MessageEncoder.response(id: id, result: result)
      } catch {
        message = MessageEncoder.error(id: id, Task.isCancelled ? .cancelled : ErrorMapper.map(error))
      }
      self.finish(id)
      await sink.send(message)
    }
  }

  private func finish(_ id: RequestID) {
    tasks[id] = nil
    for (sessionId, entry) in sessions where entry.activeRequest == id {
      sessions[sessionId]?.activeRequest = nil
    }
  }

  private func cancelAll() {
    for task in tasks.values { task.cancel() }
    for id in outgoing.keys { cancelOutgoing(id, notifyClient: false) }
  }

  // MARK: - Requests to the client

  /// Asks the client to run a tool on behalf of the running `session/respond` of `sessionId`.
  func callTool(sessionId: String, name: String, arguments: JSON) async throws -> String {
    let parent = sessions[sessionId]?.activeRequest
    let callId = "c\(nextOutgoingId)"
    let result = try await callClient(
      method: "tool/call", parent: parent,
      params: [
        "sessionId": .string(sessionId), "requestId": parent?.json ?? .null, "callId": .string(callId),
        "name": .string(name), "arguments": arguments,
      ])
    guard let output = result["output"]?.stringValue else {
      throw ToolFailure(message: "Tool '\(name)' returned no 'output' string")
    }
    return output
  }

  private func callClient(method: String, parent: RequestID?, params: JSON) async throws -> JSON {
    let id = RequestID.string("s:\(nextOutgoingId)")
    nextOutgoingId += 1
    let pending = PendingCall(parent: parent)
    outgoing[id] = pending
    // The answer may be handled while we are suspended in `send`; PendingCall buffers it.
    await sink.send(MessageEncoder.request(id: id, method: method, params: params))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let result = pending.result {
          continuation.resume(with: result)
        } else {
          pending.continuation = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelOutgoing(id) }
    }
  }

  private func resolveOutgoing(_ id: RequestID, _ result: Result<JSON, RPCError>) {
    guard let pending = outgoing.removeValue(forKey: id) else {
      Log.debug("ignoring response to unknown server request \(id)")
      return
    }
    pending.complete(result.mapError { ToolFailure(message: $0.message) as any Error })
  }

  private func cancelOutgoing(_ id: RequestID, notifyClient: Bool = true) {
    guard let pending = outgoing.removeValue(forKey: id) else { return }
    if notifyClient {
      let sink = self.sink
      Task { await sink.send(MessageEncoder.notification(method: "cancel", params: ["id": id.json])) }
    }
    pending.complete(.failure(CancellationError()))
  }

  private func cancelOutgoing(parent: RequestID) {
    for (id, pending) in outgoing where pending.parent == parent { cancelOutgoing(id) }
  }

  private func decode<T: Decodable>(_ type: T.Type, _ params: JSON) throws -> T {
    do {
      return try JSONCoding.fromJSON(type, params)
    } catch let error as DecodingError {
      throw RPCError.invalidParams(Self.describe(error), path: Self.path(of: error))
    }
  }

  private func session(_ id: String) throws -> SessionEntry {
    guard let entry = sessions[id] else { throw RPCError.sessionNotFound(id) }
    return entry
  }

  private func route(id: RequestID, method: String, params: JSON) throws -> @Sendable () async throws -> JSON {
    let engine = self.engine
    switch method {
    case "model/status":
      let p = try decode(ModelParams.self, params)
      return { await engine.status(model: p.model ?? .onDevice).json }

    case "model/tokenCount":
      let p = try decode(TokenCountParams.self, params)
      return { ["tokenCount": .int(try await engine.tokenCount(model: p.model ?? .onDevice, text: p.text))] }

    case "session/create":
      let p = try decode(SessionConfig.self, params)
      let tools = try Self.parseTools(params["tools"])
      let sessionId = UUID().uuidString.lowercased()
      let handler = SessionToolHandler(server: self, sessionId: sessionId)
      return {
        let session = try await engine.makeSession(config: p, tools: tools, toolHandler: handler)
        await self.register(sessionId, session)
        return ["sessionId": .string(sessionId), "contextSize": .int(session.contextSize)]
      }

    case "session/respond":
      let p = try decode(RespondParams.self, params)
      let schema = try params["schema"].map { try JSONSchemaConverter.convert($0) }
      var entry = try session(p.sessionId)
      guard entry.activeRequest == nil else { throw RPCError.sessionBusy(p.sessionId) }
      entry.activeRequest = id
      sessions[p.sessionId] = entry
      let session = entry.session
      let request = GenerationRequest(
        prompt: p.prompt, options: p.options ?? .init(), schema: schema,
        includeSchemaInPrompt: p.includeSchemaInPrompt ?? true)
      let sink = self.sink
      return {
        let onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
        if p.stream == true {
          let tracker = TrackerBox()
          onSnapshot = { snapshot in
            guard let params = await tracker.update(snapshot, requestId: id) else { return }
            await sink.send(MessageEncoder.notification(method: "session/delta", params: params))
          }
        } else {
          onSnapshot = nil
        }
        let result = try await session.respond(request, onSnapshot: onSnapshot)
        var o: JSONObject = ["text": .string(result.text)]
        if let content = result.content { o["content"] = content }
        if let usage = result.usage { o["usage"] = usage.json }
        return .object(o)
      }

    case "session/prewarm":
      let p = try decode(PrewarmParams.self, params)
      let session = try session(p.sessionId).session
      return {
        session.prewarm(promptPrefix: p.promptPrefix)
        return [:]
      }

    case "session/info":
      let p = try decode(SessionIdParams.self, params)
      let entry = try session(p.sessionId)
      let session = entry.session
      let isResponding = entry.activeRequest != nil
      return {
        let info = await session.info()
        var o: JSONObject = [
          "model": .string(session.model.rawValue), "contextSize": .int(info.contextSize),
          "isResponding": .bool(isResponding),
        ]
        if let count = info.historyTokenCount { o["historyTokenCount"] = .int(count) }
        if let usage = info.usage { o["usage"] = usage.json }
        return .object(o)
      }

    case "session/dispose":
      let p = try decode(SessionIdParams.self, params)
      if let active = sessions[p.sessionId]?.activeRequest {
        tasks[active]?.cancel()
        cancelOutgoing(parent: active)
      }
      sessions[p.sessionId] = nil
      return { [:] }

    default:
      throw RPCError.methodNotFound(method)
    }
  }

  private func register(_ id: String, _ session: any EngineSession) {
    sessions[id] = SessionEntry(session: session)
  }

  /// `^[a-zA-Z_][a-zA-Z0-9_]{0,63}$`
  static func isValidToolName(_ name: String) -> Bool {
    let isASCIILetter: (Character) -> Bool = { $0.isASCII && $0.isLetter }
    guard let first = name.first, name.count <= 64, isASCIILetter(first) || first == "_" else { return false }
    return name.allSatisfy { isASCIILetter($0) || ($0.isASCII && $0.isNumber) || $0 == "_" }
  }

  /// Reads `session/create` tools from the ordered JSON tree and converts their schemas.
  static func parseTools(_ json: JSON?) throws -> [ToolSpec] {
    guard let json else { return [] }
    guard case .array(let list) = json else { throw RPCError.invalidParams("'tools' must be an array", path: "tools") }
    var specs: [ToolSpec] = []
    for (i, tool) in list.enumerated() {
      let path = "tools/\(i)"
      guard let name = tool["name"]?.stringValue, isValidToolName(name) else {
        throw RPCError.invalidParams(
          "Tool name must match ^[a-zA-Z_][a-zA-Z0-9_]{0,63}$", path: "\(path)/name")
      }
      guard !specs.contains(where: { $0.name == name }) else {
        throw RPCError.invalidParams("Duplicate tool name '\(name)'", path: "\(path)/name")
      }
      guard let description = tool["description"]?.stringValue else {
        throw RPCError.invalidParams("Tool '\(name)' needs a 'description' string", path: "\(path)/description")
      }
      guard let parameters = tool["parameters"] else {
        throw RPCError.invalidParams("Tool '\(name)' needs 'parameters'", path: "\(path)/parameters")
      }
      let converted: ConvertedSchema
      do {
        converted = try JSONSchemaConverter.convert(parameters, rootName: "\(name)_arguments", requireObject: true)
      } catch var error as RPCError {
        let inner = error.data["path"]?.stringValue ?? "#"
        let pointer = "\(path)/parameters" + (inner == "#" ? "" : inner)
        error.data["path"] = .string(pointer)
        error.message = "Tool '\(name)': \(error.message)"
        throw error
      }
      var include = true
      if let flag = tool["includeSchemaInInstructions"] {
        guard case .bool(let b) = flag else {
          throw RPCError.invalidParams(
            "'includeSchemaInInstructions' must be a boolean", path: "\(path)/includeSchemaInInstructions")
        }
        include = b
      }
      specs.append(
        ToolSpec(name: name, description: description, parameters: converted, includeSchemaInInstructions: include))
    }
    return specs
  }

  private static func initializeResult(engine: any ModelEngine) async throws -> JSON {
    var models = JSONObject()
    for model in ModelId.allCases {
      models[model.rawValue] = await engine.status(model: model).json
    }
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let os =
      v.patchVersion == 0
      ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    return [
      "protocolVersion": .int(supportedProtocolVersions.max() ?? 1),
      "server": ["name": .string(serverName), "version": .string(serverVersion)],
      "os": ["version": .string(os)],
      "models": .object(models),
    ]
  }

  // MARK: - Decoding error messages

  private static func path(of error: DecodingError) -> String {
    let context: DecodingError.Context? =
      switch error {
      case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): c
      case .keyNotFound(let key, let c): DecodingError.Context(codingPath: c.codingPath + [key], debugDescription: "")
      @unknown default: nil
      }
    return (context?.codingPath ?? []).map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "/")
  }

  private static func describe(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, _): "Missing required parameter '\(key.stringValue)'"
    case .typeMismatch(let type, _): "Parameter '\(path(of: error))' has the wrong type, expected \(type)"
    case .valueNotFound(let type, _): "Parameter '\(path(of: error))' must not be null, expected \(type)"
    case .dataCorrupted(let c): "Invalid parameter '\(path(of: error))': \(c.debugDescription)"
    @unknown default: "Invalid params"
    }
  }
}

/// Turns snapshots of one request into `session/delta` params (deltas for text,
/// whole partial values for structured output).
private actor TrackerBox {
  private var tracker = DeltaTracker()
  private var lastPartial: JSON?

  func update(_ snapshot: EngineSnapshot, requestId: RequestID) -> JSON? {
    if let partial = snapshot.partial {
      guard partial != lastPartial else { return nil }
      lastPartial = partial
      return ["requestId": requestId.json, "partial": partial]
    }
    switch tracker.update(snapshot.text) {
    case .none: return nil
    case .delta(let d): return ["requestId": requestId.json, "delta": .string(d)]
    case .reset(let t): return ["requestId": requestId.json, "reset": true, "text": .string(t)]
    }
  }
}

/// Routes tool calls of one session to the client.
private struct SessionToolHandler: ToolHandler {
  let server: Server
  let sessionId: String

  func callTool(name: String, arguments: JSON) async throws -> String {
    try await server.callTool(sessionId: sessionId, name: name, arguments: arguments)
  }
}

/// A tool call the client answered with an error; FoundationModels wraps it in `ToolCallError`.
struct ToolFailure: LocalizedError, Sendable {
  var message: String
  var errorDescription: String? { message }
}

/// A request to the client waiting for its answer. Only touched on the server actor.
private final class PendingCall: @unchecked Sendable {
  let parent: RequestID?
  var result: Result<JSON, any Error>?
  var continuation: CheckedContinuation<JSON, any Error>?

  init(parent: RequestID?) { self.parent = parent }

  func complete(_ result: Result<JSON, any Error>) {
    if let continuation {
      self.continuation = nil
      continuation.resume(with: result)
    } else if self.result == nil {
      self.result = result
    }
  }
}
