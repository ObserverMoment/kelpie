import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct SettingsFeatureDeepgramTests {
  private static func makeStore(
    stored: String? = nil,
    state: SettingsFeature.State = SettingsFeature.State(),
    validate: @escaping @Sendable (String) async throws -> Void = { _ in },
    read: (@Sendable () throws -> String?)? = nil,
    write: (@Sendable (String) throws -> Void)? = nil,
    delete: (@Sendable () throws -> Void)? = nil
  ) -> (store: TestStoreOf<SettingsFeature>, keychain: LockIsolated<String?>) {
    let keychain = LockIsolated(stored)
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[DeepgramKeyStore.self] = DeepgramKeyStore(
        read: read ?? { keychain.value },
        write: write ?? { key in keychain.setValue(key) },
        delete: delete ?? { keychain.setValue(nil) }
      )
      $0[DeepgramClient.self] = DeepgramClient(validate: validate, synthesize: { _, _ in Data() })
    }
    return (store, keychain)
  }

  @Test(.dependencies) func checkReportsStoredKey() async {
    let (store, _) = Self.makeStore(stored: "dg_key")
    await store.send(.checkDeepgramKey)
    await store.receive(\.deepgramKeyChecked, true) { $0.deepgramKeyIsSet = true }
  }

  @Test(.dependencies) func checkReportsMissingKey() async {
    let (store, _) = Self.makeStore()
    await store.send(.checkDeepgramKey)
    await store.receive(\.deepgramKeyChecked, false) { $0.deepgramKeyIsSet = false }
  }

  @Test(.dependencies) func checkTreatsAReadFailureAsNoKey() async {
    let (store, _) = Self.makeStore(read: { throw KeychainError(status: errSecIO) })
    await store.send(.checkDeepgramKey)
    await store.receive(\.deepgramKeyChecked, false) { $0.deepgramKeyIsSet = false }
  }

  @Test(.dependencies) func saveValidatesTrimmedKeyThenStoresIt() async {
    let validated = LockIsolated<[String]>([])
    let (store, keychain) = Self.makeStore(validate: { key in validated.withValue { $0.append(key) } })
    await store.send(.binding(.set(\.deepgramKeyDraft, "  dg_key "))) { $0.deepgramKeyDraft = "  dg_key " }
    await store.send(.saveDeepgramKeyTapped) { $0.isSavingDeepgramKey = true }
    await store.receive(\.deepgramKeySaved) {
      $0.isSavingDeepgramKey = false
      $0.deepgramKeyIsSet = true
      $0.deepgramKeyDraft = ""
    }
    #expect(validated.value == ["dg_key"])
    #expect(keychain.value == "dg_key")
  }

  @Test(.dependencies) func saveRejectsAKeyDeepgramRefuses() async {
    let (store, keychain) = Self.makeStore(validate: { _ in throw DeepgramError.invalidKey })
    await store.send(.binding(.set(\.deepgramKeyDraft, "bad"))) { $0.deepgramKeyDraft = "bad" }
    await store.send(.saveDeepgramKeyTapped) { $0.isSavingDeepgramKey = true }
    await store.receive(\.deepgramKeyFailed, DeepgramError.invalidKey.localizedDescription) {
      $0.isSavingDeepgramKey = false
      $0.deepgramKeyError = DeepgramError.invalidKey.localizedDescription
    }
    #expect(keychain.value == nil)
  }

  @Test(.dependencies) func saveReportsAKeychainWriteFailure() async {
    let failure = KeychainError(status: errSecIO)
    let (store, keychain) = Self.makeStore(write: { _ in throw failure })
    await store.send(.binding(.set(\.deepgramKeyDraft, "dg_key"))) { $0.deepgramKeyDraft = "dg_key" }
    await store.send(.saveDeepgramKeyTapped) { $0.isSavingDeepgramKey = true }
    await store.receive(\.deepgramKeyFailed, failure.localizedDescription) {
      $0.isSavingDeepgramKey = false
      $0.deepgramKeyError = failure.localizedDescription
    }
    #expect(store.state.deepgramKeyIsSet == nil)
    #expect(store.state.deepgramKeyDraft == "dg_key")
    #expect(keychain.value == nil)
  }

  @Test(.dependencies) func saveIgnoresATapWhileSaving() async {
    let validated = LockIsolated(0)
    var state = SettingsFeature.State()
    state.deepgramKeyDraft = "dg_key"
    state.isSavingDeepgramKey = true
    let (store, keychain) = Self.makeStore(state: state, validate: { _ in validated.withValue { $0 += 1 } })
    await store.send(.saveDeepgramKeyTapped)
    #expect(validated.value == 0)
    #expect(keychain.value == nil)
  }

  @Test(.dependencies) func saveClearsThePreviousError() async {
    var state = SettingsFeature.State()
    state.deepgramKeyDraft = "dg_key"
    state.deepgramKeyError = "Deepgram rejected this API key."
    let (store, _) = Self.makeStore(state: state)
    await store.send(.saveDeepgramKeyTapped) {
      $0.isSavingDeepgramKey = true
      $0.deepgramKeyError = nil
    }
    await store.receive(\.deepgramKeySaved) {
      $0.isSavingDeepgramKey = false
      $0.deepgramKeyIsSet = true
      $0.deepgramKeyDraft = ""
    }
  }

  @Test(.dependencies) func saveIgnoresABlankDraft() async {
    let (store, keychain) = Self.makeStore()
    await store.send(.binding(.set(\.deepgramKeyDraft, "   "))) { $0.deepgramKeyDraft = "   " }
    await store.send(.saveDeepgramKeyTapped)
    #expect(keychain.value == nil)
  }

  @Test(.dependencies) func editingTheDraftClearsTheError() async {
    var state = SettingsFeature.State()
    state.deepgramKeyError = "Invalid key"
    let (store, _) = Self.makeStore(state: state)
    await store.send(.binding(.set(\.deepgramKeyDraft, "x"))) {
      $0.deepgramKeyDraft = "x"
      $0.deepgramKeyError = nil
    }
  }

  @Test(.dependencies) func removeDeletesTheKey() async {
    var state = SettingsFeature.State()
    state.deepgramKeyIsSet = true
    let (store, keychain) = Self.makeStore(stored: "dg_key", state: state)
    await store.send(.removeDeepgramKeyTapped)
    await store.receive(\.deepgramKeyRemoved) { $0.deepgramKeyIsSet = false }
    #expect(keychain.value == nil)
  }

  @Test(.dependencies) func removeReportsAKeychainFailure() async {
    var state = SettingsFeature.State()
    state.deepgramKeyIsSet = true
    let failure = KeychainError(status: errSecIO)
    let (store, _) = Self.makeStore(stored: "dg_key", state: state, delete: { throw failure })
    await store.send(.removeDeepgramKeyTapped)
    await store.receive(\.deepgramKeyFailed, failure.localizedDescription) {
      $0.deepgramKeyError = failure.localizedDescription
    }
  }
}
