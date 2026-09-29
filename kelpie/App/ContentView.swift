//
//  ContentView.swift
//  kelpie
//
//  Created by khoi on 20/1/26.
//

import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
  private nonisolated let contentRenderLogger = KelpieLogger("DetailRender")
#endif

struct ContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @State private var leftSidebarVisibility: NavigationSplitViewVisibility = .all
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    repositoriesStore = store.scope(state: \.repositories, action: \.repositories)
    self.terminalManager = terminalManager
  }

  var body: some View {
    #if DEBUG
      let _ = contentRenderLogger.info("ContentView.body re-rendered")
    #endif
    return NavigationSplitView(columnVisibility: $leftSidebarVisibility) {
      SidebarView(store: repositoriesStore, terminalManager: terminalManager)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SidebarBottomCardView(store: store)
        }
    } detail: {
      WorktreeDetailView(store: store, terminalManager: terminalManager)
    }
    .navigationSplitViewStyle(.automatic)
    .disabled(!repositoriesStore.isInitialLoadComplete)
    // Fleet View covers the split view instead of replacing it so the hosted
    // terminals are never torn down; it slides in from the sidebar's edge.
    .overlay {
      if store.fleetView.isPresented {
        FleetView(
          store: store.scope(state: \.fleetView, action: \.fleetView),
          podsStore: store.scope(state: \.pods, action: \.pods),
          terminalsStore: store.scope(state: \.terminals, action: \.terminals),
          runtime: ContentRuntime.liveValue
        )
        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
      }
    }
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85),
      value: store.fleetView.isPresented
    )
    .focusedSceneAction(\.toggleFleetViewAction, enabled: true) {
      store.send(.fleetView(.toggle))
    }
    .focusedSceneAction(\.togglePodsViewAction, enabled: true) {
      store.send(.fleetView(.togglePods))
    }
    .focusedSceneAction(\.showStandardViewAction, enabled: store.fleetView.isPresented) {
      store.send(.fleetView(.dismiss))
    }
    // Lives here, not inside the overlay: the overlay leaves the tree the moment
    // Fleet View closes, so only a permanently mounted host can deactivate the
    // monitor for the exit transition.
    .background {
      // Off in the pod workspace: its terminals take every keystroke, Escape included.
      FleetViewKeyMonitor(isActive: store.fleetView.isPresented && !store.fleetView.isShowingPodWorkspace) {
        decision in
        switch decision {
        case .move(let direction): store.send(.fleetView(.moveFocus(direction)))
        case .activate: store.send(.fleetView(.activateFocusedCard))
        case .dismiss: store.send(.fleetView(.dismiss))
        case .swallow, .menuShortcut: break
        }
      }
    }
    .onChange(of: scenePhase) { _, newValue in
      store.send(.scenePhaseChanged(newValue))
    }
    .fileImporter(
      isPresented: $repositoriesStore.isOpenPanelPresented.sending(\.setOpenPanelPresented),
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        store.send(.repositories(.openRepositories(urls)))
      case .failure:
        store.send(
          .repositories(
            .presentAlert(
              title: "Unable to open folders",
              message: "Kelpie could not read the selected folders."
            )
          )
        )
      }
    }
    .alert($repositoriesStore.scope(state: \.alert, action: \.alert))
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(
      item: $store.scope(state: \.deeplinkInputConfirmation, action: \.deeplinkInputConfirmation)
    ) { confirmationStore in
      DeeplinkInputConfirmationView(store: confirmationStore)
    }
    .sheet(
      item: $repositoriesStore.scope(state: \.worktreeCreationPrompt, action: \.worktreeCreationPrompt)
    ) { promptStore in
      WorktreeCreationPromptView(store: promptStore)
    }
    .sheet(
      item: $repositoriesStore.scope(
        state: \.repositoryCustomization,
        action: \.repositoryCustomization
      )
    ) { customizationStore in
      RepositoryCustomizationView(store: customizationStore)
    }
    .sheet(
      item: $repositoriesStore.scope(
        state: \.worktreeCustomization,
        action: \.worktreeCustomization
      )
    ) { customizationStore in
      WorktreeCustomizationView(store: customizationStore)
    }
    .sheet(
      item: $repositoriesStore.scope(
        state: \.renameBranchPrompt,
        action: \.renameBranchPrompt
      )
    ) { renameStore in
      RenameBranchView(store: renameStore)
    }
    .focusedSceneAction(\.toggleLeftSidebarAction, enabled: true) {
      withAnimation(.easeOut(duration: 0.2)) {
        leftSidebarVisibility = leftSidebarVisibility == .detailOnly ? .all : .detailOnly
      }
    }
    .focusedSceneAction(
      \.terminateAllTerminalSessionsAction,
      enabled: store.hasAnyTerminalSurface
    ) {
      store.send(.requestTerminateAllTerminalSessions)
    }
    .focusedSceneAction(
      \.revealInSidebarAction,
      enabled: repositoriesStore.selectedWorktreeID != nil
    ) {
      withAnimation(.easeOut(duration: 0.2)) {
        leftSidebarVisibility = .all
      }
      store.send(.repositories(.revealSelectedWorktreeInSidebar))
    }
    .focusedSceneAction(
      \.expandAllSidebarGroupsAction,
      enabled: !repositoriesStore.repositories.isEmpty
    ) {
      store.send(.repositories(.setAllSidebarGroupsExpanded(true)))
    }
    .focusedSceneAction(
      \.collapseAllSidebarGroupsAction,
      enabled: !repositoriesStore.repositories.isEmpty
    ) {
      store.send(.repositories(.setAllSidebarGroupsExpanded(false)))
    }
    .background {
      CommandPaletteOverlayHost(
        store: store,
        repositoriesStore: repositoriesStore,
        ghosttyShortcuts: ghosttyShortcuts
      )
    }
    .background(WindowTabbingDisabler())
    .background(WindowTintBackdrop(runtime: terminalManager.ghosttyRuntime))
    .background(WindowChromeObserver(runtime: terminalManager.ghosttyRuntime))
    .background(
      WindowTitleHost(
        repositoriesStore: repositoriesStore,
        terminalManager: terminalManager
      )
    )
    .background(OpenActionIconWarmHost(store: store))
  }
}

/// Confines the `installedOpenActions` read so a resolved availability sweep
/// warms the icon cache off the main thread without invalidating ContentView.
private struct OpenActionIconWarmHost: View {
  let store: StoreOf<AppFeature>
  @Environment(OpenActionIconStore.self) private var iconStore: OpenActionIconStore?

  var body: some View {
    let installed = store.installedOpenActions
    return Color.clear
      .task(id: installed) {
        await iconStore?.warm(installed)
      }
  }
}

/// Builds the palette items in this view's body instead of `ContentView.body`
/// and drives the floating `CommandPalettePanel`. Per-row sidebar mutations
/// only invalidate this host, leaving ContentView's focused-value closures stable.
private struct CommandPaletteOverlayHost: View {
  let store: StoreOf<AppFeature>
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let ghosttyShortcuts: GhosttyShortcutManager

  var body: some View {
    #if DEBUG
      let _ = contentRenderLogger.info("CommandPaletteOverlayHost.body re-rendered")
    #endif
    let paletteStore = store.scope(state: \.commandPalette, action: \.commandPalette)
    return CommandPalettePanelHost(
      store: paletteStore,
      items: CommandPaletteFeature.items(
        in: paletteStore.mode,
        from: repositoriesStore.state,
        ghosttyCommands: ghosttyShortcuts.commandPaletteEntries,
        scripts: store.allScripts,
        runningScriptIDs: store.runningScriptIDs
      ),
      isPresented: paletteStore.isPresented
    )
  }
}

/// Hosts the `.navigationTitle` modifier so the title computation runs in
/// this view's body. `WindowTitle.compute` reads selection / sidebar.sections
/// fields. Confining the reads here keeps ContentView immune to title-only
/// invalidations from tab renames or section title edits.
private struct WindowTitleHost: View {
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    #if DEBUG
      let _ = contentRenderLogger.info("WindowTitleHost.body re-rendered")
    #endif
    return Color.clear
      .navigationTitle(
        WindowTitle.compute(
          repositories: repositoriesStore.state,
          terminalManager: terminalManager
        )
      )
  }
}
