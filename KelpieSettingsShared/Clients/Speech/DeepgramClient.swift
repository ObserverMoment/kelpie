import ComposableArchitecture
import Foundation

/// Deepgram's text-to-speech REST API. `validate` proves a key works by
/// synthesising a few words; `synthesize` returns MP3 audio for `text`, which
/// must be at most `maxTextLength` characters.
public nonisolated struct DeepgramClient: Sendable {
  public var validate: @Sendable (_ key: String) async throws -> Void
  public var synthesize: @Sendable (_ text: String, _ key: String) async throws -> Data

  public init(
    validate: @escaping @Sendable (_ key: String) async throws -> Void,
    synthesize: @escaping @Sendable (_ text: String, _ key: String) async throws -> Data
  ) {
    self.validate = validate
    self.synthesize = synthesize
  }

  /// Deepgram answers 413 above this for Aura models.
  public static let maxTextLength = 2000
  public static let voice = "aura-2-thalia-en"
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
    case .undecodableAudio: "Deepgram returned audio that could not be decoded."
    }
  }
}

extension DeepgramClient: DependencyKey {
  public static let liveValue = DeepgramClient(
    validate: { key in _ = try await DeepgramAPI.speak("Deepgram is ready.", key: key) },
    synthesize: { text, key in try await DeepgramAPI.speak(text, key: key) }
  )

  public static let testValue = DeepgramClient(validate: { _ in }, synthesize: { _, _ in Data() })
}

private nonisolated enum DeepgramAPI {
  private static let speakURL = URL(string: "https://api.deepgram.com/v1/speak")!
  private static let requestTimeout: TimeInterval = 15

  /// Responses are audio for one message, never worth caching, and a stalled
  /// request should fail fast enough for the macOS voice to take over.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    return URLSession(configuration: configuration)
  }()

  static func speak(_ text: String, key: String) async throws -> Data {
    var components = URLComponents(url: speakURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "model", value: DeepgramClient.voice),
      URLQueryItem(name: "encoding", value: "mp3"),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["text": text])
    return try await send(request)
  }

  private static func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw DeepgramError.transport(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw DeepgramError.transport("no HTTP response") }
    switch http.statusCode {
    case 200..<300: return data
    case 401, 403: throw DeepgramError.invalidKey
    case 413: throw DeepgramError.textTooLong
    default: throw DeepgramError.server(status: http.statusCode)
    }
  }
}
