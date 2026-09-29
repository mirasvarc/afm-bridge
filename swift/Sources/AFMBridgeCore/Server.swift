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
    case .success(.response(let id, _)):
      Log.debug("ignoring response to unknown server request \(id)")
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
      return {
        let session = try await engine.makeSession(config: p)
        let sessionId = UUID().uuidString.lowercased()
        await self.register(sessionId, session)
        return ["sessionId": .string(sessionId), "contextSize": .int(session.contextSize)]
      }

    case "session/respond":
      let p = try decode(RespondParams.self, params)
      if p.schema != nil {
        throw RPCError.invalidParams("Structured output is not implemented in this version yet", path: "schema")
      }
      var entry = try session(p.sessionId)
      guard entry.activeRequest == nil else { throw RPCError.sessionBusy(p.sessionId) }
      entry.activeRequest = id
      sessions[p.sessionId] = entry
      let session = entry.session
      let request = GenerationRequest(prompt: p.prompt, options: p.options ?? .init())
      let sink = self.sink
      return {
        let onSnapshot: (@Sendable (String) async -> Void)?
        if p.stream == true {
          let tracker = TrackerBox()
          onSnapshot = { snapshot in
            guard let event = await tracker.update(snapshot) else { return }
            let params: JSON =
              switch event {
              case .delta(let d): ["requestId": id.json, "delta": .string(d)]
              case .reset(let t): ["requestId": id.json, "reset": true, "text": .string(t)]
              }
            await sink.send(MessageEncoder.notification(method: "session/delta", params: params))
          }
        } else {
          onSnapshot = nil
        }
        let result = try await session.respond(request, onSnapshot: onSnapshot)
        var o: [String: JSON] = ["text": .string(result.text)]
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
        var o: [String: JSON] = [
          "model": .string(session.model.rawValue), "contextSize": .int(info.contextSize),
          "isResponding": .bool(isResponding),
        ]
        if let count = info.historyTokenCount { o["historyTokenCount"] = .int(count) }
        if let usage = info.usage { o["usage"] = usage.json }
        return .object(o)
      }

    case "session/dispose":
      let p = try decode(SessionIdParams.self, params)
      if let active = sessions[p.sessionId]?.activeRequest { tasks[active]?.cancel() }
      sessions[p.sessionId] = nil
      return { [:] }

    default:
      throw RPCError.methodNotFound(method)
    }
  }

  private func register(_ id: String, _ session: any EngineSession) {
    sessions[id] = SessionEntry(session: session)
  }

  private static func initializeResult(engine: any ModelEngine) async throws -> JSON {
    var models: [String: JSON] = [:]
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

/// Holds a `DeltaTracker` across the async snapshot callbacks of one request.
private actor TrackerBox {
  private var tracker = DeltaTracker()
  func update(_ snapshot: String) -> DeltaTracker.Event? { tracker.update(snapshot) }
}
