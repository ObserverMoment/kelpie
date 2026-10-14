import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

public struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Form {
      Section {
        Toggle(
          isOn: $store.systemNotificationsEnabled
        ) {
          Text("System notifications")
        }
        Picker(selection: $store.notificationSound) {
          Text(NotificationSound.never.displayName).tag(NotificationSound.never)
          Divider()
          ForEach(NotificationSound.systemCases) { sound in
            NotificationSoundLabel(sound: sound).tag(sound)
          }
          Divider()
          Text(NotificationSound.kelpieClassic.displayName).tag(NotificationSound.kelpieClassic)
        } label: {
          Text("Play notification sound")
          Text(
            "Ignored when system notifications are enabled, as they play sounds"
              + " according to your settings."
          )
        }
        .disabled(store.systemNotificationsEnabled)
        Toggle(
          isOn: $store.muteNotificationsForActiveSurface
        ) {
          Text("Mute notifications for active surface")
          Text("Skip the notification and sound when the terminal that sent it is focused and visible.")
        }
        .disabled(!store.hasActiveNotificationChannel)
      }
      Section {
        Picker(selection: $store.notificationRetentionLimit) {
          ForEach(NotificationRetentionLimit.allCases, id: \.self) { limit in
            RetentionLimitLabel(limit: limit).tag(limit)
          }
        } label: {
          Text("Keep notifications")
          Text("Older notifications beyond this count are discarded per worktree.")
        }
      }
      Section("Worktrees") {
        Toggle(
          isOn: $store.inAppNotificationsEnabled
        ) {
          Text("Notification badge")
          Text("Display an orange dot next to worktrees with unread notifications.")
        }
        Toggle(
          isOn: $store.moveNotifiedWorktreeToTop
        ) {
          Text("Prioritize unread in Active and Pinned sections")
          Text("Worktrees with unread notifications will be shown first.")
        }
      }
      Section("Read aloud") {
        switch store.deepgramKeyIsSet {
        case nil:
          ProgressView().controlSize(.small)
        case true?:
          deepgramEnabledRow
        case false?:
          deepgramKeyEntryRows
        }
        if let error = store.deepgramKeyError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      Section("Threads") {
        Picker(selection: $store.threadSummaryModel) {
          ForEach(ThreadSummaryModel.allCases, id: \.self) { model in
            DefaultTaggedLabel(label: model.label, isDefault: model == GlobalSettings.default.threadSummaryModel)
              .tag(model)
          }
        } label: {
          Text("Summary model")
          Text("Writes each thread's rolling summary through your Claude Code login. Off keeps threads unsummarised.")
        }
        Picker(selection: $store.threadSummaryEffort) {
          ForEach(ThreadSummaryEffort.allCases, id: \.self) { effort in
            DefaultTaggedLabel(label: effort.label, isDefault: effort == GlobalSettings.default.threadSummaryEffort)
              .tag(effort)
          }
        } label: {
          Text("Summary effort")
          Text("How much the model thinks before writing. Low is enough for a few lines.")
        }
      }
    }
    .task { store.send(.checkDeepgramKey) }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Notifications")
  }

  private var deepgramEnabledRow: some View {
    LabeledContent {
      Button("Remove Key", role: .destructive) {
        store.send(.removeDeepgramKeyTapped)
      }
      .help("Forget the stored Deepgram API key and go back to the built-in macOS voice")
    } label: {
      Text("Deepgram Aura-2 voice")
      Text("Enabled. Read Aloud sends message text to Deepgram and plays its voice.")
    }
  }

  @ViewBuilder
  private var deepgramKeyEntryRows: some View {
    SecureField(text: $store.deepgramKeyDraft, prompt: Text("Paste your Deepgram API key")) {
      Text("Deepgram Aura-2 voice")
      Text("Without a key, Read Aloud uses the built-in macOS voice.")
    }
    .onSubmit { store.send(.saveDeepgramKeyTapped) }
    .disabled(store.isSavingDeepgramKey)
    LabeledContent {
      Button {
        store.send(.saveDeepgramKeyTapped)
      } label: {
        if store.isSavingDeepgramKey {
          ProgressView().controlSize(.small)
        } else {
          Text("Save Key")
        }
      }
      .disabled(store.isSavingDeepgramKey || store.deepgramKeyDraft.allSatisfy(\.isWhitespace))
      .help("Check the key with Deepgram and store it in your Keychain")
    } label: {
      Link("Get an API key at console.deepgram.com", destination: DeepgramClient.consoleURL)
    }
  }
}

private struct NotificationSoundLabel: View {
  let sound: NotificationSound

  var body: some View {
    DefaultTaggedLabel(
      label: sound.displayName,
      isDefault: sound == GlobalSettings.default.notificationSound
    )
  }
}

private struct RetentionLimitLabel: View {
  let limit: NotificationRetentionLimit

  var body: some View {
    DefaultTaggedLabel(label: limit.label, isDefault: limit == .defaultValue)
  }
}
