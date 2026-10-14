import AVFoundation
import ComposableArchitecture
import KelpieSettingsShared

private nonisolated let speechLogger = KelpieLogger("Speech")

/// Speaks text with Deepgram's voice when the user has stored an API key,
/// otherwise in the best installed macOS voice for the user's language.
nonisolated struct SpeechClient: Sendable {
  /// Returns when the speech ends; cancelling the calling task stops it.
  var speak: @MainActor @Sendable (_ text: String) async -> Void
}

extension SpeechClient: DependencyKey {
  static let liveValue = SpeechClient(speak: { text in
    @Dependency(DeepgramKeyStore.self) var deepgramKeyStore
    @Dependency(DeepgramClient.self) var deepgramClient
    if let key = await Self.storedDeepgramKey(deepgramKeyStore) {
      do {
        try await DeepgramSpeechPlayer(client: deepgramClient, key: key).speak(text)
        return
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        // Nothing has played yet, so the macOS voice can take the whole message.
        speechLogger.warning("Deepgram read aloud failed, using the macOS voice: \(error.localizedDescription)")
      }
    }
    await SpeechUtterancePlayer().speak(text)
  })

  static let testValue = SpeechClient(speak: { _ in })

  /// Off the main actor: a locked keychain blocks the read until the user
  /// answers its prompt.
  private static func storedDeepgramKey(_ store: DeepgramKeyStore) async -> String? {
    do {
      return try await Task.detached(priority: .userInitiated) { try store.read() }.value
    } catch {
      speechLogger.warning("Could not read the Deepgram key, using the macOS voice: \(error.localizedDescription)")
      return nil
    }
  }
}

/// Plays a message through Deepgram one chunk at a time, fetching the next
/// chunk while the current one plays so there is one request in flight and
/// first audio lands after a single short round trip.
@MainActor
private final class DeepgramSpeechPlayer: NSObject, AVAudioPlayerDelegate {
  /// A quarter of what Deepgram accepts: a shorter first chunk means a faster
  /// first sound, and each later fetch hides behind the chunk before it.
  private static let chunkLength = DeepgramClient.maxTextLength / 4

  private let client: DeepgramClient
  private let key: String
  private var player: AVAudioPlayer?
  private var playbackContinuation: CheckedContinuation<Void, Never>?
  /// Held only so `stop()` can cancel it; `speak` awaits it through its own handle.
  private var inFlightFetch: Task<Data, any Error>?

  init(client: DeepgramClient, key: String) {
    self.client = client
    self.key = key
  }

  /// Throws only before the first chunk has played; a failure after that is
  /// logged and ends the reading, since restarting it in another voice would
  /// repeat what was already heard.
  func speak(_ text: String) async throws {
    let chunks = SpeakableText.chunks(text, maxLength: Self.chunkLength)
    guard let first = chunks.first else { return }
    try await withTaskCancellationHandler {
      defer { inFlightFetch?.cancel() }
      var pending = fetch(first)
      for index in chunks.indices {
        do {
          let audio = try await pending.value
          try Task.checkCancellation()
          if chunks.indices.contains(index + 1) {
            pending = fetch(chunks[index + 1])
          }
          try await play(audio)
        } catch let cancellation as CancellationError {
          throw cancellation
        } catch  where index > 0 {
          speechLogger.warning("Deepgram read aloud stopped early: \(error.localizedDescription)")
          return
        }
      }
    } onCancel: {
      Task { @MainActor in self.stop() }
    }
  }

  private func fetch(_ chunk: String) -> Task<Data, any Error> {
    let task = Task { [client, key] in try await client.synthesize(chunk, key) }
    inFlightFetch = task
    return task
  }

  private func play(_ audio: Data) async throws {
    guard let player = try? AVAudioPlayer(data: audio), player.prepareToPlay() else {
      throw DeepgramError.undecodableAudio
    }
    player.delegate = self
    self.player = player
    await withCheckedContinuation { continuation in
      playbackContinuation = continuation
      if !player.play() { finish() }
    }
  }

  private func stop() {
    inFlightFetch?.cancel()
    player?.stop()
    finish()
  }

  private func finish() {
    playbackContinuation?.resume()
    playbackContinuation = nil
  }

  /// A late callback from an earlier chunk's player must not end the current one.
  private func finish(ifCurrent playerID: ObjectIdentifier) {
    guard player.map(ObjectIdentifier.init) == playerID else { return }
    finish()
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let playerID = ObjectIdentifier(player)
    Task { @MainActor in self.finish(ifCurrent: playerID) }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
    let playerID = ObjectIdentifier(player)
    Task { @MainActor in self.finish(ifCurrent: playerID) }
  }
}

/// One utterance on its own synthesizer, so a stopped utterance's late
/// delegate callback can never end the next one.
@MainActor
private final class SpeechUtterancePlayer: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var speechEndContinuation: CheckedContinuation<Void, Never>?

  func speak(_ text: String) async {
    guard !text.isEmpty, !Task.isCancelled else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.bestVoice()
    synthesizer.delegate = self
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        speechEndContinuation = continuation
        synthesizer.speak(utterance)
      }
    } onCancel: {
      Task { @MainActor in self.synthesizer.stopSpeaking(at: .immediate) }
    }
  }

  private func finish() {
    speechEndContinuation?.resume()
    speechEndContinuation = nil
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
