import Foundation
import Testing

@testable import AFMBridgeCore

// MARK: - Fakes

actor CollectingSink: MessageSink {
  private(set) var messages: [JSON] = []

  func send(_ message: JSON) async { messages.append(message) }

  /// Waits until a response (or error) for `id` arrives.
  func response(_ id: Int, timeout: Duration = .seconds(5)) async throws -> JSON {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let m = messages.first(where: { $0["id"] == .int(id) }) { return m }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw TestTimeout(what: "response \(id)")
  }

  func notifications(_ method: String) -> [JSON] {
    messages.filter { $0["method"] == .string(method) }
  }

  func index(where predicate: (JSON) -> Bool) -> Int? { messages.firstIndex(where: predicate) }
}

struct TestTimeout: Error { var what: String }

final class ExitRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _codes: [Int32] = []
  var codes: [Int32] { lock.withLock { _codes } }
  func record(_ c: Int32) { lock.withLock { _codes.append(c) } }
}

struct FakeSession: EngineSession {
  enum Behavior: Sendable {
    case snapshots([String])
    /// Streams these partial values and returns the last one as structured content.
    case partials([JSON])
    case hangUntilCancelled
    case fail(RPCError)
    /// Calls the named tool with the arguments and answers "tool said: <output>".
    case callTool(String, JSON)
  }

  var behavior: Behavior
  var toolHandler: any ToolHandler
  var model: ModelId { .onDevice }
  var contextSize: Int { 4096 }

  func respond(
    _ request: GenerationRequest, onSnapshot: (@Sendable (EngineSnapshot) async -> Void)?
  ) async throws -> GenerationResult {
    let usage = Usage(inputTokens: 5, cachedInputTokens: 0, outputTokens: 3, reasoningTokens: 0)
    switch behavior {
    case .snapshots(let snaps):
      for s in snaps { await onSnapshot?(EngineSnapshot(text: s)) }
      return GenerationResult(text: snaps.last ?? "", usage: usage)
    case .partials(let values):
      for v in values { await onSnapshot?(EngineSnapshot(text: v.serialized, partial: v)) }
      let content = request.schema.map { $0.normalize(values.last ?? .null) } ?? values.last
      return GenerationResult(text: content?.serialized ?? "", content: content, usage: usage)
    case .hangUntilCancelled:
      while true { try await Task.sleep(for: .milliseconds(10)) }
    case .fail(let e):
      throw e
    case .callTool(let name, let arguments):
      let output = try await toolHandler.callTool(name: name, arguments: arguments)
      return GenerationResult(text: "tool said: \(output)")
    }
  }

  func prewarm(promptPrefix: String?) {}
  func info() async -> SessionInfo { SessionInfo(contextSize: 4096, historyTokenCount: 12) }
}

actor ToolRecorder {
  private(set) var tools: [[ToolSpec]] = []
  func record(_ t: [ToolSpec]) { tools.append(t) }
}

struct FakeEngine: ModelEngine {
  var behavior: FakeSession.Behavior = .snapshots(["Hel", "Hello", "Hello!"])
  var available = true
  var recorder = ToolRecorder()

  func status(model: ModelId) async -> ModelStatus {
    model == .onDevice && available
      ? .available(contextSize: 4096, variant: "Fake", capabilities: ["toolCalling"], supportedLanguages: ["en"])
      : .unavailable(reason: .appleIntelligenceNotEnabled, message: "off")
  }

  func tokenCount(model: ModelId, text: String) async throws -> Int { text.split(separator: " ").count }

  func makeSession(config: SessionConfig, tools: [ToolSpec], toolHandler: any ToolHandler) async throws
    -> any EngineSession
  {
    guard available else {
      throw RPCError.modelUnavailable(model: .onDevice, reason: .appleIntelligenceNotEnabled, message: "off")
    }
    await recorder.record(tools)
    return FakeSession(behavior: behavior, toolHandler: toolHandler)
  }
}

// MARK: - Helpers

struct Harness {
  let server: Server
  let sink = CollectingSink()
  let exits = ExitRecorder()

  init(engine: FakeEngine = FakeEngine()) {
    let exits = self.exits
    server = Server(engine: engine, sink: sink, onExit: { exits.record($0) })
  }

  func send(_ id: Int?, _ method: String, _ params: JSON = [:]) async {
    var m: JSONObject = ["jsonrpc": "2.0", "method": .string(method), "params": params]
    if let id { m["id"] = .int(id) }
    await server.handle(line: MessageEncoder.line(.object(m)))
  }

  func call(_ id: Int, _ method: String, _ params: JSON = [:]) async throws -> JSON {
    await send(id, method, params)
    return try await sink.response(id)
  }

  func initialize() async throws {
    _ = try await call(0, "initialize", ["protocolVersion": 1, "client": ["name": "test", "version": "0"]])
  }

  func createSession(_ id: Int = 1) async throws -> String {
    let r = try await call(id, "session/create", ["instructions": "Be brief."])
    return try #require(r["result"]?["sessionId"]?.stringValue)
  }
}

// MARK: - Tests

@Suite struct ServerTests {
  @Test func rejectsRequestsBeforeInitialize() async throws {
    let h = Harness()
    let r = try await h.call(1, "session/create")
    #expect(r["error"]?["data"]?["type"] == "notInitialized")
  }

  @Test func initializeReportsVersionAndModels() async throws {
    let h = Harness()
    let r = try await h.call(0, "initialize", ["protocolVersion": 1])
    let result = try #require(r["result"])
    #expect(result["protocolVersion"] == 1)
    #expect(result["server"]?["name"] == "afm-bridge-server")
    #expect(result["models"]?["on-device"]?["available"] == true)
    #expect(result["models"]?["private-cloud"]?["available"] == false)
    #expect(result["os"]?["version"]?.stringValue != nil)
  }

  @Test func rejectsUnsupportedProtocolVersion() async throws {
    let h = Harness()
    let r = try await h.call(0, "initialize", ["protocolVersion": 99])
    #expect(r["error"]?["code"] == .int(-32001))
    #expect(r["error"]?["data"]?["supported"] == [1])
    #expect(try await h.call(1, "model/status")["error"]?["data"]?["type"] == "notInitialized")
  }

  @Test func respondReturnsTextAndUsage() async throws {
    let h = Harness()
    try await h.initialize()
    let sid = try await h.createSession()
    let r = try await h.call(2, "session/respond", ["sessionId": .string(sid), "prompt": "Hi"])
    #expect(r["result"]?["text"] == "Hello!")
    #expect(r["result"]?["usage"]?["outputTokens"] == 3)
    #expect(await h.sink.notifications("session/delta").isEmpty)
  }

  @Test func streamSendsDeltasBeforeResponse() async throws {
    let h = Harness(engine: FakeEngine(behavior: .snapshots(["", "Hel", "Hello", "Bye", "Bye now"])))
    try await h.initialize()
    let sid = try await h.createSession()
    let r = try await h.call(2, "session/respond", ["sessionId": .string(sid), "prompt": "Hi", "stream": true])
    #expect(r["result"]?["text"] == "Bye now")
    let params = await h.sink.notifications("session/delta").compactMap { $0["params"] }
    #expect(
      params == [
        ["requestId": 2, "delta": "Hel"],
        ["requestId": 2, "delta": "lo"],
        ["requestId": 2, "reset": true, "text": "Bye"],
        ["requestId": 2, "delta": " now"],
      ])
    let lastDelta = try #require(
      await h.sink.index { $0["method"] == "session/delta" && $0["params"]?["delta"] == " now" })
    let response = try #require(await h.sink.index { $0["id"] == 2 })
    #expect(lastDelta < response)
  }

  @Test func secondRequestOnBusySessionIsRejected() async throws {
    let h = Harness(engine: FakeEngine(behavior: .hangUntilCancelled))
    try await h.initialize()
    let sid = try await h.createSession()
    await h.send(2, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    let busy = try await h.call(3, "session/respond", ["sessionId": .string(sid), "prompt": "b"])
    #expect(busy["error"]?["data"]?["type"] == "sessionBusy")
    await h.send(nil, "cancel", ["id": 2])
    #expect(try await h.sink.response(2)["error"]?["data"]?["type"] == "cancelled")
  }

  @Test func cancelStopsGenerationAndFreesSession() async throws {
    let h = Harness(engine: FakeEngine(behavior: .hangUntilCancelled))
    try await h.initialize()
    let sid = try await h.createSession()
    await h.send(2, "session/respond", ["sessionId": .string(sid), "prompt": "a", "stream": true])
    try await Task.sleep(for: .milliseconds(30))
    await h.send(nil, "cancel", ["id": 2])
    let r = try await h.sink.response(2)
    #expect(r["error"]?["code"] == .int(-32800))
    let info = try await h.call(3, "session/info", ["sessionId": .string(sid)])
    #expect(info["result"]?["isResponding"] == false)
    #expect(await h.server.runningRequestCount == 0)
  }

  @Test func cancelOfUnknownRequestIsIgnored() async throws {
    let h = Harness()
    try await h.initialize()
    await h.send(nil, "cancel", ["id": 12345])
    #expect(try await h.call(1, "model/status")["result"]?["available"] == true)
  }

  @Test func disposeCancelsRunningGeneration() async throws {
    let h = Harness(engine: FakeEngine(behavior: .hangUntilCancelled))
    try await h.initialize()
    let sid = try await h.createSession()
    await h.send(2, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    try await Task.sleep(for: .milliseconds(20))
    #expect(try await h.call(3, "session/dispose", ["sessionId": .string(sid)])["result"] == [:])
    #expect(try await h.sink.response(2)["error"]?["data"]?["type"] == "cancelled")
    let gone = try await h.call(4, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    #expect(gone["error"]?["data"]?["type"] == "sessionNotFound")
  }

  @Test func engineErrorsAreForwarded() async throws {
    let h = Harness(
      engine: FakeEngine(
        behavior: .fail(
          RPCError(code: -32030, type: "contextWindowExceeded", message: "too long", data: ["contextSize": 4096]))))
    try await h.initialize()
    let sid = try await h.createSession()
    let r = try await h.call(2, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    #expect(r["error"]?["code"] == .int(-32030))
    #expect(r["error"]?["data"]?["contextSize"] == 4096)
    // The session is usable again after an error.
    #expect(try await h.call(3, "session/info", ["sessionId": .string(sid)])["result"]?["isResponding"] == false)
  }

  @Test func unavailableModelIsTypedError() async throws {
    let h = Harness(engine: FakeEngine(available: false))
    try await h.initialize()
    let r = try await h.call(1, "session/create")
    #expect(r["error"]?["data"]?["type"] == "modelUnavailable")
    #expect(r["error"]?["data"]?["reason"] == "appleIntelligenceNotEnabled")
  }

  @Test func invalidParamsReportPath() async throws {
    let h = Harness()
    try await h.initialize()
    let r = try await h.call(1, "session/respond", ["sessionId": "x"])
    #expect(r["error"]?["code"] == .int(-32602))
    #expect(r["error"]?["data"]?["path"] == "prompt")
    let bad = try await h.call(2, "session/create", ["model": "gpt"])
    #expect(bad["error"]?["data"]?["type"] == "invalidParams")
  }

  @Test func unknownMethod() async throws {
    let h = Harness()
    try await h.initialize()
    #expect(try await h.call(1, "nope")["error"]?["code"] == .int(-32601))
  }

  @Test func duplicateInFlightIdIsRejected() async throws {
    let h = Harness(engine: FakeEngine(behavior: .hangUntilCancelled))
    try await h.initialize()
    let sid = try await h.createSession()
    await h.send(2, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    await h.send(2, "model/status")
    let first = try await h.sink.response(2)
    #expect(first["error"]?["data"]?["type"] == "invalidRequest")
    await h.send(nil, "cancel", ["id": 2])
  }

  @Test func tokenCountAndInfo() async throws {
    let h = Harness()
    try await h.initialize()
    #expect(try await h.call(1, "model/tokenCount", ["text": "a b c"])["result"]?["tokenCount"] == 3)
    let sid = try await h.createSession(2)
    let info = try await h.call(3, "session/info", ["sessionId": .string(sid)])
    #expect(info["result"]?["historyTokenCount"] == 12)
    #expect(info["result"]?["model"] == "on-device")
  }

  @Test func shutdownRepliesThenExits() async throws {
    let h = Harness(engine: FakeEngine(behavior: .hangUntilCancelled))
    try await h.initialize()
    let sid = try await h.createSession()
    await h.send(2, "session/respond", ["sessionId": .string(sid), "prompt": "a"])
    #expect(try await h.call(3, "shutdown")["result"] == [:])
    #expect(h.exits.codes == [0])
  }

  @Test func eofExits() async throws {
    let h = Harness()
    await h.server.handleEOF()
    #expect(h.exits.codes == [0])
  }

  @Test func parseErrorGetsNullId() async throws {
    let h = Harness()
    await h.server.handle(line: "{oops")
    await h.server.handle(line: "   ")
    let messages = await h.sink.messages
    #expect(messages.count == 1)
    #expect(messages[0]["id"] == .null)
    #expect(messages[0]["error"]?["code"] == .int(-32700))
  }
}
