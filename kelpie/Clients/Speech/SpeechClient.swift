import AVFoundation
import ComposableArchitecture

/// Speaks text in the best installed voice for the user's language.
nonisolated struct SpeechClient: Sendable {
  /// Returns when the speech ends; cancelling the calling task stops it.
  var speak: @MainActor @Sendable (_ text: String) async -> Void
}

extension SpeechClient: DependencyKey {
  static let liveValue = SpeechClient(speak: { text in await SpeechUtterancePlayer().speak(text) })

  static let testValue = SpeechClient(speak: { _ in })
}

/// One utterance on its own synthesizer, so a stopped utterance's late
/// delegate callback can never end the next one.
@MainActor
private final class SpeechUtterancePlayer: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var finished: CheckedContinuation<Void, Never>?

  func speak(_ text: String) async {
    guard !text.isEmpty, !Task.isCancelled else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.bestVoice()
    synthesizer.delegate = self
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        finished = continuation
        synthesizer.speak(utterance)
      }
    } onCancel: {
      Task { @MainActor in self.synthesizer.stopSpeaking(at: .immediate) }
    }
  }

  private func finish() {
    finished?.resume()
    finished = nil
  }

  /// Highest quality first (a downloaded Premium voice beats the stock one),
  /// then an exact locale match, among the user's language's voices.
  private static func bestVoice() -> AVSpeechSynthesisVoice? {
    let locale = AVSpeechSynthesisVoice.currentLanguageCode()
    let language = String(locale.prefix { $0 != "-" })
    return AVSpeechSynthesisVoice.speechVoices()
      .filter {
        $0.language.hasPrefix(language) && $0.voiceTraits.isDisjoint(with: [.isNoveltyVoice, .isPersonalVoice])
      }
      .max { rank($0, locale: locale) < rank($1, locale: locale) }
  }

  private static func rank(_ voice: AVSpeechSynthesisVoice, locale: String) -> (Int, Int) {
    (voice.quality.rawValue, voice.language == locale ? 1 : 0)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finish() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finish() }
  }
}
