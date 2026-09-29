import Foundation

/// A dynamically typed JSON value. Integers are kept separate from doubles so
/// request IDs and token counts round-trip without turning into `1.0`.
public enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public subscript(key: String) -> JSON? {
    if case .object(let dict) = self { return dict[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}

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
      self = .object(o)
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
    case .object(let o): try c.encode(o)
    }
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(nilLiteral: ()) { self = .null }
}

enum JSONCoding {
  static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }

  /// Converts any `Encodable` value into a `JSON` tree.
  static func toJSON(_ value: some Encodable) throws -> JSON {
    let data = try encoder().encode(value)
    return try JSONDecoder().decode(JSON.self, from: data)
  }

  /// Decodes a typed value from a `JSON` tree (used for request params).
  static func fromJSON<T: Decodable>(_ type: T.Type, _ json: JSON) throws -> T {
    let data = try encoder().encode(json)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
