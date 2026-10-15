import ComposableArchitecture
import Foundation

/// Deepgram's text-to-speech REST API. `validate` proves a key works by
/// synthesising a few words; `synthesize` streams 16-bit little-endian mono
/// PCM at `sampleRate` for `text`, raw or WAV-wrapped, in byte pieces that
/// need not align to samples, as Deepgram produces it so playback can start
/// before synthesis finishes. `text` must be at most `maxTextLength` characters.
public nonisolated struct DeepgramClient: Sendable {
  public var validate: @Sendable (_ key: String) async throws -> Void
  public var synthesize: @Sendable (_ text: String, _ key: String) async throws -> AsyncThrowingStream<Data, any Error>

  public init(
    validate: @escaping @Sendable (_ key: String) async throws -> Void,
    synthesize: @escaping @Sendable (_ text: String, _ key: String) async throws -> AsyncThrowingStream<Data, any Error>
  ) {
    self.validate = validate
    self.synthesize = synthesize
  }

  /// Deepgram's documented per-request limit; callers chunk well under it.
  public static let maxTextLength = 2000
  public static let voice = "flux-tanner-en"
  public static let sampleRate = 24_000
  public static let consoleURL = URL(string: "https://console.deepgram.com")!
}

public nonisolated enum DeepgramError: LocalizedError, Equatable {
  case invalidKey
  case textTooLong
  case server(status: Int)
  case transport(String)
  case undecodableAudio

  public var errorDescription: String? {
    switch self {
    case .invalidKey: "Deepgram rejected this API key."
    case .textTooLong: "Deepgram refused the text as too long."
    case .server(let status): "Deepgram returned HTTP \(status)."
    case .transport(let detail): "Could not reach Deepgram: \(detail)"
    case .undecodableAudio: "Deepgram's audio could not be played."
    }
  }
}

extension DeepgramClient: DependencyKey {
  public static let liveValue = DeepgramClient(
    validate: { key in _ = try await DeepgramAPI.speak("Deepgram is ready.", key: key) },
    synthesize: { text, key in try await DeepgramAPI.speak(text, key: key) }
  )

  public static let testValue = DeepgramClient(
    validate: { _ in },
    synthesize: { _, _ in AsyncThrowingStream { $0.finish() } }
  )
}

private nonisolated enum DeepgramAPI {
  private static let speakURL = URL(string: "https://api.deepgram.com/v2/speak")!
  private static let requestTimeout: TimeInterval = 15
  /// 100 ms of audio per yielded piece: small enough that the first sound is
  /// not held back, large enough that scheduling is not per-byte.
  private static let pieceLength = DeepgramClient.sampleRate * 2 / 10

  /// Responses are audio for one message, never worth caching, and a stalled
  /// request should fail fast enough for the macOS voice to take over.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    return URLSession(configuration: configuration)
  }()

  /// Returns once Deepgram has accepted the request, so a bad key or
  /// oversized text throws here rather than part-way through the stream.
  static func speak(_ text: String, key: String) async throws -> AsyncThrowingStream<Data, any Error> {
    var components = URLComponents(url: speakURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "model", value: DeepgramClient.voice),
      URLQueryItem(name: "encoding", value: "linear16"),
      URLQueryItem(name: "sample_rate", value: String(DeepgramClient.sampleRate)),
      // Flux's defaults, pinned so the voice stays the same if Deepgram changes them.
      URLQueryItem(name: "speed", value: "1"),
      URLQueryItem(name: "expressivity", value: "0"),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["text": text])
    return pieces(of: try await send(request))
  }

  private static func send(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw clientError(from: error)
    }
    guard let http = response as? HTTPURLResponse else { throw DeepgramError.transport("no HTTP response") }
    switch http.statusCode {
    case 200..<300: return bytes
    case 401, 403: throw DeepgramError.invalidKey
    case 413: throw DeepgramError.textTooLong
    default: throw DeepgramError.server(status: http.statusCode)
    }
  }

  /// Regroups the body into `pieceLength`-byte pieces as they arrive; the
  /// last piece is whatever remains.
  private static func pieces(of bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var piece = Data(capacity: pieceLength)
        do {
          for try await byte in bytes {
            piece.append(byte)
            guard piece.count == pieceLength else { continue }
            continuation.yield(piece)
            piece = Data(capacity: pieceLength)
          }
          if !piece.isEmpty { continuation.yield(piece) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: clientError(from: error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// A cancelled request surfaces as cancellation, anything else as transport.
  private static func clientError(from error: any Error) -> any Error {
    switch error {
    case let urlError as URLError where urlError.code == .cancelled: CancellationError()
    case is CancellationError: error
    default: DeepgramError.transport(error.localizedDescription)
    }
  }
}
