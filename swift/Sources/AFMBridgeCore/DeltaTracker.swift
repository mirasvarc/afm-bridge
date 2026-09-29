/// Turns the cumulative snapshots produced by FoundationModels into deltas.
///
/// Normally every snapshot extends the previous one and only the appended
/// suffix is emitted. If a snapshot does not start with the previous text
/// (the framework rewrote earlier output), a reset carrying the full text is
/// emitted instead. See PROTOCOL.md, `session/delta`.
public struct DeltaTracker: Sendable {
  public enum Event: Sendable, Equatable {
    case delta(String)
    case reset(String)
  }

  public private(set) var text = ""

  public init() {}

  /// Returns `nil` when the snapshot brings no change.
  public mutating func update(_ snapshot: String) -> Event? {
    if snapshot == text { return nil }
    defer { text = snapshot }
    if snapshot.hasPrefix(text) {
      return .delta(String(snapshot.dropFirst(text.count)))
    }
    return .reset(snapshot)
  }
}
