import Testing

@testable import AFMBridgeCore

@Suite struct ProtocolTypesTests {
  @Test func decodesSamplingModes() throws {
    #expect(try JSONCoding.fromJSON(Sampling.self, ["mode": "greedy"]) == .greedy)
    #expect(try JSONCoding.fromJSON(Sampling.self, ["mode": "topK", "k": 40, "seed": 7]) == .topK(k: 40, seed: 7))
    #expect(
      try JSONCoding.fromJSON(Sampling.self, ["mode": "topP", "threshold": .double(0.9)])
        == .topP(threshold: 0.9, seed: nil))
    #expect(throws: DecodingError.self) { try JSONCoding.fromJSON(Sampling.self, ["mode": "beam"]) }
  }

  @Test func decodesPromptStringAndParts() throws {
    #expect(try JSONCoding.fromJSON(PromptInput.self, "Hi") == PromptInput("Hi"))
    let parts = try JSONCoding.fromJSON(
      PromptInput.self,
      [
        ["type": "text", "text": "Describe"], ["type": "image", "path": "/tmp/a.png"],
        ["type": "image", "data": "AAA="],
      ])
    #expect(parts.parts == [.text("Describe"), .imagePath("/tmp/a.png"), .imageData(base64: "AAA=", mimeType: nil)])
  }

  @Test func encodesModelStatus() {
    let available = ModelStatus.available(
      contextSize: 8192, variant: nil, capabilities: ["toolCalling"], supportedLanguages: ["en"])
    #expect(available.json["available"] == true)
    #expect(available.json["variant"] == nil)
    let unavailable = ModelStatus.unavailable(reason: .appleIntelligenceNotEnabled, message: "off")
    #expect(unavailable.json["reason"] == "appleIntelligenceNotEnabled")
  }
}
