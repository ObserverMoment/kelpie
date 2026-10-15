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

/// Plays a message through Deepgram, scheduling audio for playback as it
/// streams in so the first sound lands after one short round trip, with the
/// next chunk's request already in flight while the current one plays.
@MainActor
private final class DeepgramSpeechPlayer {
  /// The opening sentence, split if longer: the first request is the one the
  /// user waits for, and a shorter one is answered sooner.
  private static let firstChunkLength = 150
  /// A quarter of what Deepgram accepts, so no single request runs long.
  private static let chunkLength = DeepgramClient.maxTextLength / 4

  private let client: DeepgramClient
  private let key: String
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: Double(DeepgramClient.sampleRate), channels: 1)!
  private var hasScheduledAudio = false
  private var hasCompletedFirstChunk = false
  /// Set by `stop()`, which the output-device observer can call while the
  /// chunk loop is still running; the loop treats it like cancellation.
  private var isStopped = false
  private var playbackContinuation: CheckedContinuation<Void, Never>?
  /// Held only so `stop()` can cancel it; `speak` awaits it through its own handle.
  private var inFlightFetch: Task<AsyncThrowingStream<Data, any Error>, any Error>?
  private var configurationChangeObserver: (any NSObjectProtocol)?

  init(client: DeepgramClient, key: String) {
    self.client = client
    self.key = key
  }

  /// Throws only while the first chunk is still arriving, so the macOS voice
  /// can take the whole message; a failure after that is logged and ends the
  /// reading, since restarting it in another voice would repeat what was heard.
  func speak(_ text: String) async throws {
    let chunks = SpeakableText.chunks(text, firstMaxLength: Self.firstChunkLength, maxLength: Self.chunkLength)
    guard let first = chunks.first else { return }
    try await withTaskCancellationHandler {
      defer { stop() }
      var pending = fetch(first)
      try startEngine()
      for index in chunks.indices {
        do {
          try checkStillSpeaking()
          let stream = try await pending.value
          if chunks.indices.contains(index + 1) {
            pending = fetch(chunks[index + 1])
          }
          try await schedule(stream)
          hasCompletedFirstChunk = true
        } catch let cancellation as CancellationError {
          throw cancellation
        } catch  where hasCompletedFirstChunk {
          speechLogger.warning("Deepgram read aloud stopped early: \(error.localizedDescription)")
          break
        }
      }
      try checkStillSpeaking()
      await drain()
    } onCancel: {
      Task { @MainActor in self.stop() }
    }
  }

  /// Sends the request for `chunk` straight away; the audio buffers inside the
  /// stream until `schedule` consumes it.
  private func fetch(_ chunk: String) -> Task<AsyncThrowingStream<Data, any Error>, any Error> {
    let task = Task { [client, key] in try await client.synthesize(chunk, key) }
    inFlightFetch = task
    return task
  }

  /// The engine stops itself when the output device changes and does not play
  /// what is queued, so the reading ends there rather than hanging in `drain`.
  private func startEngine() throws {
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      speechLogger.info("Audio output changed, Deepgram read aloud stopped")
      Task { @MainActor in self?.stop() }
    }
    try engine.start()
    node.play()
  }

  /// Queues one chunk's audio behind whatever is already playing.
  private func schedule(_ stream: AsyncThrowingStream<Data, any Error>) async throws {
    var pcm = StreamedPCM()
    var hasScheduledChunk = false
    for try await piece in stream {
      let samples = pcm.samples(appending: piece)
      guard !samples.isEmpty else { continue }
      node.scheduleBuffer(try buffer(for: samples), completionHandler: nil)
      hasScheduledAudio = true
      hasScheduledChunk = true
    }
    // A cancelled stream ends without throwing, so check before judging it empty.
    try checkStillSpeaking()
    guard hasScheduledChunk else { throw DeepgramError.undecodableAudio }
  }

  private func checkStillSpeaking() throws {
    try Task.checkCancellation()
    guard !isStopped else { throw CancellationError() }
  }

  private func buffer(for samples: [Float]) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(samples.count)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let channel = buffer.floatChannelData?[0]
    else { throw DeepgramError.undecodableAudio }
    buffer.frameLength = frameCount
    _ = UnsafeMutableBufferPointer(start: channel, count: samples.count).update(fromContentsOf: samples)
    return buffer
  }

  /// Waits for everything queued so far to play out: a one-frame silent
  /// buffer at the tail reports when the data before it has been heard.
  private func drain() async {
    guard hasScheduledAudio, engine.isRunning, let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
      return
    }
    tail.frameLength = 1
    await withCheckedContinuation { continuation in
      playbackContinuation = continuation
      node.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in
        Task { @MainActor in self.finish() }
      }
    }
  }

  private func stop() {
    isStopped = true
    inFlightFetch?.cancel()
    configurationChangeObserver.map(NotificationCenter.default.removeObserver)
    configurationChangeObserver = nil
    node.stop()
    engine.stop()
    finish()
  }

  private func finish() {
    playbackContinuation?.resume()
    playbackContinuation = nil
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
