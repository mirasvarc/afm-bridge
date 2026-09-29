import Foundation

/// A dynamically typed JSON value. Objects keep their key order (JSON Schema property
/// order decides the order in which the model generates fields) and integers are kept
/// separate from doubles so IDs and token counts round-trip without turning into `1.0`.
public enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSON])
  case object(JSONObject)

  public subscript(key: String) -> JSON? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var objectValue: JSONObject? {
    if case .object(let o) = self { return o }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}

/// An insertion-ordered JSON object. Equality ignores key order.
public struct JSONObject: Sendable, Equatable, Sequence, ExpressibleByDictionaryLiteral {
  public private(set) var keys: [String] = []
  private var values: [String: JSON] = [:]

  public init() {}

  public init(dictionaryLiteral elements: (String, JSON)...) {
    for (k, v) in elements { self[k] = v }
  }

  public init(_ dictionary: [String: JSON]) {
    for k in dictionary.keys.sorted() { self[k] = dictionary[k] }
  }

  public subscript(key: String) -> JSON? {
    get { values[key] }
    set {
      if let newValue {
        if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
      } else if values.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  @discardableResult
  public mutating func removeValue(forKey key: String) -> JSON? {
    let old = values[key]
    self[key] = nil
    return old
  }

  public var count: Int { keys.count }
  public var isEmpty: Bool { keys.isEmpty }
  public var dictionary: [String: JSON] { values }

  public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
    var index = 0
    return AnyIterator {
      guard index < keys.count else { return nil }
      defer { index += 1 }
      let k = keys[index]
      return (k, values[k]!)
    }
  }

  public static func == (a: JSONObject, b: JSONObject) -> Bool { a.values == b.values }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    var o = JSONObject()
    for (k, v) in elements { o[k] = v }
    self = .object(o)
  }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(nilLiteral: ()) { self = .null }
}

// MARK: - Parsing

public struct JSONParseError: Error, Sendable, CustomStringConvertible {
  public var offset: Int
  public var reason: String
  public var description: String { "\(reason) at offset \(offset)" }
}

extension JSON {
  /// Parses JSON text, keeping object key order.
  public static func parse(_ text: String) throws -> JSON {
    var parser = Parser(bytes: Array(text.utf8))
    parser.skipWhitespace()
    let value = try parser.value(depth: 0)
    parser.skipWhitespace()
    guard parser.index == parser.bytes.count else { throw parser.error("Unexpected trailing characters") }
    return value
  }

  public static func parse(_ data: Data) throws -> JSON {
    try parse(String(decoding: data, as: UTF8.self))
  }
}

private struct Parser {
  let bytes: [UInt8]
  var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

  mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  mutating func value(depth: Int) throws -> JSON {
    guard depth < 512 else { throw error("Nesting too deep") }
    guard index < bytes.count else { throw error("Unexpected end of input") }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try object(depth: depth)
    case UInt8(ascii: "["): return try array(depth: depth)
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "t"): try literal("true"); return .bool(true)
    case UInt8(ascii: "f"): try literal("false"); return .bool(false)
    case UInt8(ascii: "n"): try literal("null"); return .null
    default: return try number()
    }
  }

  mutating func literal(_ word: String) throws {
    for b in word.utf8 {
      guard index < bytes.count, bytes[index] == b else { throw error("Invalid literal") }
      index += 1
    }
  }

  mutating func object(depth: Int) throws -> JSON {
    index += 1
    var o = JSONObject()
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      return .object(o)
    }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected object key") }
      let key = try string()
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
      index += 1
      skipWhitespace()
      o[key] = try value(depth: depth + 1)
      skipWhitespace()
      guard index < bytes.count else { throw error("Unterminated object") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
      } else if bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(o)
      } else {
        throw error("Expected ',' or '}'")
      }
    }
  }

  mutating func array(depth: Int) throws -> JSON {
    index += 1
    var a: [JSON] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      return .array(a)
    }
    while true {
      skipWhitespace()
      a.append(try value(depth: depth + 1))
      skipWhitespace()
      guard index < bytes.count else { throw error("Unterminated array") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
      } else if bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(a)
      } else {
        throw error("Expected ',' or ']'")
      }
    }
  }

  mutating func string() throws -> String {
    index += 1
    var out: [UInt8] = []
    while true {
      guard index < bytes.count else { throw error("Unterminated string") }
      let b = bytes[index]
      index += 1
      switch b {
      case UInt8(ascii: "\""):
        return String(decoding: out, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard index < bytes.count else { throw error("Unterminated escape") }
        let e = bytes[index]
        index += 1
        switch e {
        case UInt8(ascii: "\""): out.append(0x22)
        case UInt8(ascii: "\\"): out.append(0x5C)
        case UInt8(ascii: "/"): out.append(0x2F)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if (0xD800...0xDBFF).contains(scalar) {
            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
            else { throw error("Unpaired surrogate") }
            index += 2
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid surrogate pair") }
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
          } else if (0xDC00...0xDFFF).contains(scalar) {
            throw error("Unpaired surrogate")
          }
          guard let u = Unicode.Scalar(scalar) else { throw error("Invalid unicode escape") }
          out.append(contentsOf: Array(String(Character(u)).utf8))
        default:
          throw error("Invalid escape")
        }
      case 0x00..<0x20:
        throw error("Control character in string")
      default:
        out.append(b)
      }
    }
  }

  mutating func hex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw error("Short unicode escape") }
    var v: UInt32 = 0
    for _ in 0..<4 {
      let c = bytes[index]
      index += 1
      let d: UInt32
      switch c {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
      default: throw error("Invalid hex digit")
      }
      v = v * 16 + d
    }
    return v
  }

  mutating func number() throws -> JSON {
    let start = index
    var isInteger = true
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
    guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
      throw error("Invalid value")
    }
    while index < bytes.count {
      let c = bytes[index]
      if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) {
        index += 1
      } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+")
        || c == UInt8(ascii: "-")
      {
        isInteger = false
        index += 1
      } else {
        break
      }
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    if isInteger, let i = Int(text) { return .int(i) }
    guard let d = Double(text), d.isFinite else { throw JSONParseError(offset: start, reason: "Invalid number") }
    return .double(d)
  }
}

// MARK: - Serialization

extension JSON {
  /// Compact single-line JSON text in key order.
  public var serialized: String {
    var out = ""
    write(to: &out)
    return out
  }

  private func write(to out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .int(let i): out += String(i)
    case .double(let d):
      if !d.isFinite {
        out += "null"
      } else if d == d.rounded(), abs(d) < 1e15 {
        out += String(Int(d))
      } else {
        out += "\(d)"
      }
    case .string(let s): JSON.writeString(s, to: &out)
    case .array(let a):
      out += "["
      for (i, v) in a.enumerated() {
        if i > 0 { out += "," }
        v.write(to: &out)
      }
      out += "]"
    case .object(let o):
      out += "{"
      for (i, (k, v)) in o.enumerated() {
        if i > 0 { out += "," }
        JSON.writeString(k, to: &out)
        out += ":"
        v.write(to: &out)
      }
      out += "}"
    }
  }

  private static func writeString(_ s: String, to out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case let c where c.value < 0x20:
        out += "\\u" + String(format: "%04x", c.value)
      default: out.unicodeScalars.append(u)
      }
    }
    out += "\""
  }
}

// MARK: - Codable bridge (typed params)

extension JSON: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int.self) {
      self = .int(i)
    } else if let d = try? c.decode(Double.self) {
      self = .double(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSON].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSON].self) {
      // Codable loses key order; order-sensitive data (schemas) is read from the parsed tree instead.
      self = .object(JSONObject(o))
    } else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o.dictionary)
    }
  }
}

enum JSONCoding {
  /// Decodes a typed value from a `JSON` tree (used for request params).
  static func fromJSON<T: Decodable>(_ type: T.Type, _ json: JSON) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.serialized.utf8))
  }
}
