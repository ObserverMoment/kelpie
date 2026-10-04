import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct MailAssemblerTests {
  /// What the hook puts on the wire: the raw JSON string value (escapes kept),
  /// base64, cut into slices.
  static func chunks(for text: String, id: String = "42", width: Int = 8) -> [AgentPresenceOSC.MailChunk] {
    let json = (try? JSONEncoder().encode(text)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    let raw = String(json.dropFirst().dropLast())
    let base64 = Array(Data(raw.utf8).base64EncodedString())
    let slices = stride(from: 0, to: base64.count, by: width).map { String(base64[$0..<min($0 + width, base64.count)]) }
    return slices.enumerated().map { index, slice in
      AgentPresenceOSC.MailChunk(agent: "claude", messageID: id, index: index + 1, total: slices.count, body: slice)
    }
  }

  @Test func reassemblesChunksInAnyOrder() {
    let text = "Done.\n\n- fixed `a`\n- \"quoted\" and ünïcödé 🎉"
    var assembler = MailAssembler()
    let chunks = Self.chunks(for: text)
    #expect(chunks.count > 3)
    let shuffled = [chunks[0]] + chunks.dropFirst().reversed()
    var completed: MailAssembler.Completed?
    for chunk in shuffled {
      let result = assembler.accept(chunk)
      if result != nil { completed = result }
    }
    #expect(completed == MailAssembler.Completed(agent: .claude, body: text))
  }

  @Test func singleChunkCompletesAtOnce() {
    var assembler = MailAssembler()
    let chunk = Self.chunks(for: "hi", width: 100)
    #expect(chunk.count == 1)
    #expect(assembler.accept(chunk[0])?.body == "hi")
  }

  @Test func continuationWithoutStartIsDropped() {
    var assembler = MailAssembler()
    let chunks = Self.chunks(for: "a longer message body")
    for chunk in chunks.dropFirst() {
      #expect(assembler.accept(chunk) == nil)
    }
  }

  @Test func freshStartReplacesStalePartial() {
    var assembler = MailAssembler()
    let lost = Self.chunks(for: "first message that never finishes")
    #expect(assembler.accept(lost[0]) == nil)
    let next = Self.chunks(for: "second", id: "42", width: 4)
    var completed: MailAssembler.Completed?
    for chunk in next {
      if let result = assembler.accept(chunk) { completed = result }
    }
    #expect(completed?.body == "second")
  }

  @Test func decodeRecoversFromBudgetCutMidEscape() {
    // A budget cut can leave `\u00` dangling; the decoder trims back to the last
    // complete escape rather than dropping the message.
    let raw = #"Hello é world \u00"#
    let base64 = Data(raw.utf8).base64EncodedString()
    #expect(AgentPresenceOSC.decodeMailBody(base64) == "Hello é world ")
  }

  @Test func parsesMailChunkMetadata() {
    let chunk = AgentPresenceOSC.parseMailChunk(id: "claude", metadata: "kind=mail;id=77;seq=2;total=3;body=QUJD")
    #expect(chunk == .init(agent: "claude", messageID: "77", index: 2, total: 3, body: "QUJD"))
    #expect(AgentPresenceOSC.isMailMetadata("kind=mail;id=77;seq=2;total=3;body=QUJD"))
    #expect(!AgentPresenceOSC.isMailMetadata("kind=notify;title=;body=QUJD"))
    #expect(AgentPresenceOSC.parseMailChunk(id: "claude", metadata: "kind=mail;id=77;seq=4;total=3;body=QUJD") == nil)
    #expect(AgentPresenceOSC.parseMailChunk(id: "claude", metadata: "kind=mail;id=77;seq=0;total=3;body=QUJD") == nil)
    #expect(AgentPresenceOSC.parseMailChunk(id: "claude", metadata: "kind=mail;seq=1;total=1;body=QUJD") == nil)
  }
}
