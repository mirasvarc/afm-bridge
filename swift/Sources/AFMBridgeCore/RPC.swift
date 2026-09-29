import Foundation

/// JSON-RPC request ID. The client uses integers, the server uses `s:`-prefixed strings.
public enum RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
  case int(Int)
  case string(String)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let i = try? c.decode(Int.self) {
      self = .int(i)
    } else {
      self = .string(try c.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .int(let i): try c.encode(i)
    case .string(let s): try c.encode(s)
    }
  }

  public var json: JSON {
    switch self {
    case .int(let i): .int(i)
    case .string(let s): .string(s)
    }
  }

  init?(json: JSON) {
    switch json {
    case .int(let i): self = .int(i)
    case .string(let s): self = .string(s)
    default: return nil
    }
  }

  public var description: String {
    switch self {
    case .int(let i): String(i)
    case .string(let s): s
    }
  }
}

/// An error that goes on the wire. `type` is the stable discriminator from PROTOCOL.md section 7.
public struct RPCError: Error, Sendable, Equatable {
  public var code: Int
  public var type: String
  public var message: String
  public var data: [String: JSON]

  public init(code: Int, type: String, message: String, data: [String: JSON] = [:]) {
    self.code = code
    self.type = type
    self.message = message
    self.data = data
  }

  public var json: JSON {
    var d = data
    d["type"] = .string(type)
    return ["code": .int(code), "message": .string(message), "data": .object(d)]
  }
}

extension RPCError {
  public static func parseError(_ message: String) -> RPCError {
    RPCError(code: -32700, type: "parseError", message: message)
  }
  public static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: -32600, type: "invalidRequest", message: message)
  }
  public static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: -32601, type: "methodNotFound", message: "Method not found: \(method)")
  }
  public static func invalidParams(_ message: String, path: String? = nil) -> RPCError {
    RPCError(
      code: -32602, type: "invalidParams", message: message,
      data: path.map { ["path": .string($0)] } ?? [:])
  }
  public static func internalError(_ message: String) -> RPCError {
    RPCError(code: -32603, type: "internal", message: message)
  }
  public static let cancelled = RPCError(code: -32800, type: "cancelled", message: "Request was cancelled")
  public static func protocolVersionMismatch(requested: Int, supported: [Int]) -> RPCError {
    RPCError(
      code: -32001, type: "protocolVersionMismatch",
      message:
        "Client speaks protocol version \(requested), server supports \(supported.map(String.init).joined(separator: ", "))",
      data: ["supported": .array(supported.map { .int($0) })])
  }
  public static let notInitialized = RPCError(
    code: -32002, type: "notInitialized", message: "The first request must be 'initialize'")
  public static func modelUnavailable(model: ModelId, reason: UnavailableReason, message: String) -> RPCError {
    RPCError(
      code: -32010, type: "modelUnavailable", message: message,
      data: ["model": .string(model.rawValue), "reason": .string(reason.rawValue)])
  }
  public static func unsupportedOS(feature: String, requiredVersion: String) -> RPCError {
    RPCError(
      code: -32011, type: "unsupportedOS",
      message: "\(feature) requires macOS \(requiredVersion) or newer",
      data: ["feature": .string(feature), "requiredVersion": .string(requiredVersion)])
  }
  public static func sessionNotFound(_ id: String) -> RPCError {
    RPCError(
      code: -32020, type: "sessionNotFound", message: "Session not found: \(id)",
      data: ["sessionId": .string(id)])
  }
  public static func sessionBusy(_ id: String) -> RPCError {
    RPCError(
      code: -32021, type: "sessionBusy",
      message: "Session \(id) is already generating a response; wait for it or cancel it first",
      data: ["sessionId": .string(id)])
  }
}

/// A parsed incoming line.
public enum IncomingMessage: Sendable, Equatable {
  case request(id: RequestID, method: String, params: JSON)
  case notification(method: String, params: JSON)
  case response(id: RequestID, result: Result<JSON, RPCError>)
}

/// A message that could not be parsed, with the request ID when it was recoverable.
public struct ParseFailure: Error, Sendable, Equatable {
  public var id: RequestID?
  public var error: RPCError
  init(_ id: RequestID?, _ error: RPCError) {
    self.id = id
    self.error = error
  }
}

public enum MessageParser {
  /// Parses one NDJSON line. On failure returns the error to send back, with the
  /// request ID when it could be recovered.
  public static func parse(_ line: String) -> Result<IncomingMessage, ParseFailure> {
    guard let data = line.data(using: .utf8),
      let json = try? JSONDecoder().decode(JSON.self, from: data)
    else {
      return .failure(ParseFailure(nil, .parseError("Invalid JSON")))
    }
    guard case .object(let obj) = json else {
      return .failure(ParseFailure(nil, .invalidRequest("Message must be a JSON object")))
    }
    let id = obj["id"].flatMap(RequestID.init(json:))
    guard obj["jsonrpc"] == .string("2.0") else {
      return .failure(ParseFailure(id, .invalidRequest("Missing or wrong 'jsonrpc' field, expected \"2.0\"")))
    }
    if let method = obj["method"] {
      guard let name = method.stringValue else {
        return .failure(ParseFailure(id, .invalidRequest("'method' must be a string")))
      }
      let params = obj["params"] ?? .object([:])
      if let id {
        return .success(.request(id: id, method: name, params: params))
      }
      if obj["id"] != nil {
        return .failure(ParseFailure(nil, .invalidRequest("'id' must be an integer or a string")))
      }
      return .success(.notification(method: name, params: params))
    }
    guard let id else {
      return .failure(ParseFailure(nil, .invalidRequest("Message has neither 'method' nor a valid 'id'")))
    }
    if let error = obj["error"] {
      let code: Int = if case .int(let c) = error["code"] { c } else { -32603 }
      let message = error["message"]?.stringValue ?? "Unknown error"
      var data: [String: JSON] = [:]
      if case .object(let d) = error["data"] { data = d }
      let type = data.removeValue(forKey: "type")?.stringValue ?? "unknown"
      return .success(
        .response(id: id, result: .failure(RPCError(code: code, type: type, message: message, data: data))))
    }
    return .success(.response(id: id, result: .success(obj["result"] ?? .null)))
  }
}

public enum MessageEncoder {
  public static func response(id: RequestID?, result: JSON) -> JSON {
    ["jsonrpc": "2.0", "id": id?.json ?? .null, "result": result]
  }

  public static func error(id: RequestID?, _ error: RPCError) -> JSON {
    ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": error.json]
  }

  public static func notification(method: String, params: JSON) -> JSON {
    ["jsonrpc": "2.0", "method": .string(method), "params": params]
  }

  public static func request(id: RequestID, method: String, params: JSON) -> JSON {
    ["jsonrpc": "2.0", "id": id.json, "method": .string(method), "params": params]
  }

  /// Serializes a message to a single line (without the trailing newline).
  public static func line(_ message: JSON) -> String {
    // JSONEncoder never emits literal newlines without `.prettyPrinted`.
    let data = (try? JSONCoding.encoder().encode(message)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}
