import Foundation

/// What Read Aloud says for a message's markdown: inline markup stripped, each
/// block on its own line so sentences don't run together, and code blocks
/// named rather than read.
nonisolated enum SpeakableText {
  static let codeBlockPlaceholder = "Code block."

  static func plainText(fromMarkdown markdown: String) -> String {
    guard
      let attributed = try? AttributedString(
        markdown: markdown, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return markdown }
    return attributed.runs[\.presentationIntent]
      .map { intent, range in
        intent?.components.contains(where: \.isCodeBlock) == true
          ? codeBlockPlaceholder : String(attributed[range].characters)
      }
      .joined(separator: "\n")
  }

  /// Pieces of `text` no longer than `maxLength`, each a run of whole
  /// sentences where possible so every piece reads naturally on its own. A
  /// sentence over the limit breaks at words, and a word over it at characters.
  static func chunks(_ text: String, maxLength: Int) -> [String] {
    chunks(sentences: sentences(in: text), maxLength: maxLength)
  }

  /// Like `chunks(_:maxLength:)`, but the first piece is the opening sentence,
  /// split if longer than `firstMaxLength`: the first request to a speech
  /// service is the one the user waits for, and a shorter one is answered sooner.
  static func chunks(_ text: String, firstMaxLength: Int, maxLength: Int) -> [String] {
    let units = sentences(in: text)
    guard let opening = units.first else { return [] }
    let openingPieces = chunks(sentences: [opening], maxLength: firstMaxLength)
    let rest = Array(openingPieces.dropFirst()) + units.dropFirst()
    return Array(openingPieces.prefix(1)) + chunks(sentences: rest, maxLength: maxLength)
  }

  private static func chunks(sentences: [String], maxLength: Int) -> [String] {
    pack(sentences, maxLength: maxLength) { sentence in
      pack(sentence.split(separator: " ").map(String.init), maxLength: maxLength) { word in
        slices(of: word, maxLength: maxLength)
      }
    }
  }

  /// Greedily joins `units` with spaces into pieces of at most `maxLength`,
  /// replacing any unit that alone exceeds the limit with `split(unit)`.
  private static func pack(_ units: [String], maxLength: Int, split: (String) -> [String]) -> [String] {
    units
      .flatMap { $0.count <= maxLength ? [$0] : split($0) }
      .reduce(into: []) { packed, unit in
        if let last = packed.last, last.count + 1 + unit.count <= maxLength {
          packed[packed.count - 1] = "\(last) \(unit)"
        } else {
          packed.append(unit)
        }
      }
  }

  private static func slices(of word: String, maxLength: Int) -> [String] {
    stride(from: 0, to: word.count, by: maxLength).map { offset in
      let start = word.index(word.startIndex, offsetBy: offset)
      let end = word.index(start, offsetBy: maxLength, limitedBy: word.endIndex) ?? word.endIndex
      return String(word[start..<end])
    }
  }

  /// Sentences as Foundation tokenises them, which also breaks at line ends.
  private static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
      let trimmed = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { sentences.append(trimmed) }
    }
    return sentences
  }
}

extension PresentationIntent.IntentType {
  fileprivate nonisolated var isCodeBlock: Bool {
    if case .codeBlock = kind { true } else { false }
  }
}
