import Testing

@testable import AFMBridgeCore

@Suite struct DeltaTrackerTests {
  @Test func emitsAppendedSuffix() {
    var t = DeltaTracker()
    #expect(t.update("He") == .delta("He"))
    #expect(t.update("Hello") == .delta("llo"))
    #expect(t.update("Hello, world") == .delta(", world"))
    #expect(t.text == "Hello, world")
  }

  @Test func skipsUnchangedSnapshots() {
    var t = DeltaTracker()
    _ = t.update("abc")
    #expect(t.update("abc") == nil)
  }

  @Test func resetsWhenTextIsRewritten() {
    var t = DeltaTracker()
    _ = t.update("The cat")
    #expect(t.update("A dog") == .reset("A dog"))
    #expect(t.update("A dog runs") == .delta(" runs"))
  }

  @Test func handlesMultiByteCharacters() {
    var t = DeltaTracker()
    _ = t.update("Příliš ")
    #expect(t.update("Příliš žluťoučký 🐎") == .delta("žluťoučký 🐎"))
  }

  @Test func deltasReassembleToFinalText() {
    let snapshots = ["", "W", "Wa", "Wave", "Waves ", "Waves crash", "New", "New text"]
    var t = DeltaTracker()
    var assembled = ""
    for s in snapshots {
      switch t.update(s) {
      case .delta(let d): assembled += d
      case .reset(let full): assembled = full
      case nil: break
      }
    }
    #expect(assembled == "New text")
  }
}
