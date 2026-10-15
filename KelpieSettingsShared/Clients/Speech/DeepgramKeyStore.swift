import ComposableArchitecture
import Foundation
import Security

/// The user's Deepgram API key in the login Keychain. `read` returns `nil`
/// when no key is stored; any other Keychain failure throws `KeychainError`.
public nonisolated struct DeepgramKeyStore: Sendable {
  public var read: @Sendable () throws -> String?
  public var write: @Sendable (_ key: String) throws -> Void
  public var delete: @Sendable () throws -> Void

  public init(
    read: @escaping @Sendable () throws -> String?,
    write: @escaping @Sendable (_ key: String) throws -> Void,
    delete: @escaping @Sendable () throws -> Void
  ) {
    self.read = read
    self.write = write
    self.delete = delete
  }
}

/// A Security framework call that returned something other than success or
/// "not found", kept with its `OSStatus` so the failure is diagnosable.
public nonisolated struct KeychainError: LocalizedError, Equatable {
  public let status: OSStatus

  public init(status: OSStatus) {
    self.status = status
  }

  public var errorDescription: String? {
    let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    return "Keychain error: \(detail)"
  }
}

extension DeepgramKeyStore: DependencyKey {
  public static let liveValue = DeepgramKeyStore.caching(
    DeepgramKeyStore(
      read: { try DeepgramKeychainItem.read() },
      write: { key in try DeepgramKeychainItem.write(key) },
      delete: { try DeepgramKeychainItem.delete() }
    )
  )

  /// Reads `base` once and answers from memory after that, so a locked
  /// Keychain can only ever delay the first read, never a Read Aloud click.
  /// The base read runs outside the lock: it can block on the unlock prompt,
  /// and a save or removal meanwhile must not wait behind it.
  static func caching(_ base: DeepgramKeyStore) -> DeepgramKeyStore {
    let cache = LockIsolated(CachedKey.unread)
    return DeepgramKeyStore(
      read: {
        if case .known(let key) = cache.value { return key }
        let key = try base.read()
        cache.withValue { cached in
          if case .unread = cached { cached = .known(key) }
        }
        return key
      },
      write: { key in
        try base.write(key)
        cache.setValue(.known(key))
      },
      delete: {
        try base.delete()
        cache.setValue(.known(nil))
      }
    )
  }

  private enum CachedKey {
    case unread
    case known(String?)
  }

  public static let testValue = DeepgramKeyStore(read: { nil }, write: { _ in }, delete: {})
}

/// One generic-password item in the login Keychain, addressed by a fixed
/// service and account so there is never more than one Deepgram key.
private nonisolated enum DeepgramKeychainItem {
  private static var query: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.observermoment.kelpie.deepgram",
      kSecAttrAccount: "api-key",
    ]
  }

  static func read() throws -> String? {
    let lookup = query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { _, new in new }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError(status: status)
    }
  }

  static func write(_ key: String) throws {
    let value: [CFString: Any] = [kSecValueData: Data(key.utf8)]
    let updated = SecItemUpdate(query as CFDictionary, value as CFDictionary)
    guard updated != errSecSuccess else { return }
    guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
    let added = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }

  static func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }
}
