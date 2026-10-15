import Testing

@testable import kelpie

struct SpeakableTextChunkTests {
  @Test func emptyTextHasNoChunks() {
    #expect(SpeakableText.chunks("", maxLength: 10) == [])
    #expect(SpeakableText.chunks(" \n ", maxLength: 10) == [])
  }

  @Test func shortTextIsOneChunk() {
    #expect(SpeakableText.chunks("Hello there.", maxLength: 50) == ["Hello there."])
  }

  @Test func packsWholeSentencesUpToTheLimit() {
    #expect(SpeakableText.chunks("One. Two. Three.", maxLength: 9) == ["One. Two.", "Three."])
  }

  @Test func lineBreaksAreSentenceBoundaries() {
    #expect(SpeakableText.chunks("first line\nsecond line", maxLength: 12) == ["first line", "second line"])
  }

  @Test func longSentenceSplitsAtWords() {
    #expect(
      SpeakableText.chunks("alpha beta gamma delta", maxLength: 11) == ["alpha beta", "gamma delta"]
    )
  }

  @Test func longWordSplitsByCharacters() {
    #expect(SpeakableText.chunks("aaaaaaaaaaaa", maxLength: 5) == ["aaaaa", "aaaaa", "aa"])
  }

  @Test func noChunkExceedsTheLimit() {
    let text = Array(repeating: "The build finished with warnings in module Foo. Check the log.", count: 40)
      .joined(separator: "\n")
    let chunks = SpeakableText.chunks(text, maxLength: 120)
    #expect(chunks.allSatisfy { $0.count <= 120 })
    #expect(
      chunks.joined(separator: " ").split(separator: " ").count == text.split(whereSeparator: \.isWhitespace).count)
  }

  @Test func firstChunkHonoursItsOwnShorterLimit() {
    let chunks = SpeakableText.chunks("One. Two. Three. Four.", firstMaxLength: 4, maxLength: 20)
    #expect(chunks == ["One.", "Two. Three. Four."])
  }

  @Test func anOverlongOpeningSentenceSplitsAtWordsAndTheRestRepacks() {
    let chunks = SpeakableText.chunks("alpha beta gamma delta. Two. Three.", firstMaxLength: 10, maxLength: 30)
    #expect(chunks == ["alpha beta", "gamma delta. Two. Three."])
  }

  @Test func firstChunkLimitWithEmptyTextGivesNoChunks() {
    #expect(SpeakableText.chunks("", firstMaxLength: 4, maxLength: 20) == [])
  }

  @Test func firstChunkIsOnlyTheOpeningSentenceEvenWhenMoreWouldFit() {
    #expect(SpeakableText.chunks("One. Two.", firstMaxLength: 20, maxLength: 20) == ["One.", "Two."])
  }
}
