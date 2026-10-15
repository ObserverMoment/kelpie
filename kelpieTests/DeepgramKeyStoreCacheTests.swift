import ComposableArchitecture
import Foundation
import Testing

@testable import KelpieSettingsShared

struct DeepgramKeyStoreCacheTests {
  private struct Fake {
    let keychain: LockIsolated<String?>
    let reads = LockIsolated(0)
    let failing = LockIsolated(false)
    let store: DeepgramKeyStore

    init(stored: String?) {
      let keychain = LockIsolated(stored)
      let reads = self.reads
      let failing = self.failing
      self.keychain = keychain
      store = .caching(
        DeepgramKeyStore(
          read: {
            reads.withValue { $0 += 1 }
            if failing.value { throw KeychainError(status: errSecIO) }
            return keychain.value
          },
          write: { keychain.setValue($0) },
          delete: { keychain.setValue(nil) }
        ))
    }
  }

  @Test func secondReadIsAnsweredFromMemory() throws {
    let fake = Fake(stored: "dg_key")
    #expect(try fake.store.read() == "dg_key")
    fake.keychain.setValue("changed behind the cache")
    #expect(try fake.store.read() == "dg_key")
    #expect(fake.reads.value == 1)
  }

  @Test func aMissingKeyIsCachedToo() throws {
    let fake = Fake(stored: nil)
    #expect(try fake.store.read() == nil)
    #expect(try fake.store.read() == nil)
    #expect(fake.reads.value == 1)
  }

  @Test func writeUpdatesTheCacheWithoutAnotherRead() throws {
    let fake = Fake(stored: nil)
    try fake.store.write("dg_new")
    #expect(try fake.store.read() == "dg_new")
    #expect(fake.keychain.value == "dg_new")
    #expect(fake.reads.value == 0)
  }

  @Test func deleteUpdatesTheCache() throws {
    let fake = Fake(stored: "dg_key")
    #expect(try fake.store.read() == "dg_key")
    try fake.store.delete()
    #expect(try fake.store.read() == nil)
    #expect(fake.reads.value == 1)
  }

  @Test func aFailedReadIsNotCached() throws {
    let fake = Fake(stored: "dg_key")
    fake.failing.setValue(true)
    #expect(throws: KeychainError.self) { try fake.store.read() }
    fake.failing.setValue(false)
    #expect(try fake.store.read() == "dg_key")
    #expect(fake.reads.value == 2)
  }
}
