import Foundation

/// Logs go to stderr only; stdout is reserved for protocol messages.
public enum Log {
  public enum Level: Int, Sendable, Comparable {
    case error = 0, warn, info, debug
    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
  }

  public static let level: Level = {
    switch ProcessInfo.processInfo.environment["AFM_BRIDGE_LOG"]?.lowercased() {
    case "error": .error
    case "info": .info
    case "debug": .debug
    default: .warn
    }
  }()

  public static func write(_ l: Level, _ message: @autoclosure () -> String) {
    guard l <= level else { return }
    let line = "[afm-bridge-server] \(l) \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
  }

  public static func error(_ m: @autoclosure () -> String) { write(.error, m()) }
  public static func warn(_ m: @autoclosure () -> String) { write(.warn, m()) }
  public static func info(_ m: @autoclosure () -> String) { write(.info, m()) }
  public static func debug(_ m: @autoclosure () -> String) { write(.debug, m()) }
}
