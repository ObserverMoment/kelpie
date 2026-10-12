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
}

extension PresentationIntent.IntentType {
  fileprivate nonisolated var isCodeBlock: Bool {
    if case .codeBlock = kind { true } else { false }
  }
}
