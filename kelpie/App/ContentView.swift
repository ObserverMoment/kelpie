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
    let isFleetPresented = store.fleetView.isPresented
    // Fleet and Pods collapse the sidebar column, and drop its toggle, so the
    // sidebar's repo and folder buttons leave the toolbar and the view switcher
    // moves up to the traffic lights. The user's own visibility is kept for Home.
    let columnVisibility = Binding<NavigationSplitViewVisibility>(
      get: { isFleetPresented ? .detailOnly : leftSidebarVisibility },
      // Reads the store, not `isFleetPresented`: as Fleet opens, the split view
      // writes `.detailOnly` through the previous body's binding.
      set: { if !store.fleetView.isPresented { leftSidebarVisibility = $0 } }
    )
    return NavigationSplitView(columnVisibility: columnVisibility) {
      SidebarView(store: repositoriesStore, terminalManager: terminalManager, isOverlayPresented: isFleetPresented)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SidebarBottomCardView(store: store)
        }
    } detail: {
      WorktreeDetailView(store: store, terminalManager: terminalManager)
    }
    .navigationSplitViewStyle(.automatic)
    .toolbar(removing: isFleetPresented ? .sidebarToggle : nil)
    .disabled(!repositoriesStore.isInitialLoadComplete)
    // Fleet View covers the split view instead of replacing it so the hosted
    // terminals are never torn down; it slides in from the sidebar's edge.
    .overlay {
      if store.fleetView.isPresented {
        FleetView(
          store: store.scope(state: \.fleetView, action: \.fleetView),
          podsStore: store.scope(state: \.pods, action: \.pods),
          threadsStore: store.scope(state: \.threads, action: \.threads),
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
    .focusedSceneAction(\.toggleThreadsViewAction, enabled: true) {
      store.send(.fleetView(.toggleThreads))
    }
    .focusedSceneAction(\.showStandardViewAction, enabled: store.fleetView.isPresented) {
      store.send(.fleetView(.dismiss))
    }
    // Lives here, not inside the overlay: the overlay leaves the tree the moment
    // Fleet View closes, so only a permanently mounted host can deactivate the
    // monitor for the exit transition.
    .background {
      // Off in the pod workspace, the mail viewer and a ⌘F field: their
      // terminals, reply box and filter take every keystroke, Escape included.
      FleetViewKeyMonitor(
        isActive: store.fleetView.isPresented && !store.fleetView.isShowingPodWorkspace && !store.mailViewerTakesKeys
          && !store.searchFieldTakesKeys
      ) {
        decision in
        switch decision {
        case .move(let direction): store.send(.fleetView(.moveFocus(direction)))
        case .activate: store.send(.fleetView(.activateFocusedCard))
        case .dismiss: store.send(.overlayEscapePressed)
        case .focusReply: store.send(.overlayTabPressed)
        case .markDone: store.send(.fleetView(.markFocusedDone))
        case .jump: store.send(.fleetView(.jumpToFocused))
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
    // ⌃⌘↑/↓ skip the sidebar's group headers while the column is hidden.
    // `initial: true` because a reopened window starts visible again while the
    // store still holds what the closed window last reported.
    .onChange(of: leftSidebarVisibility, initial: true) { _, visibility in
      store.send(.sidebarVisibilityChanged(visibility != .detailOnly))
    }
    .focusedSceneAction(\.toggleLeftSidebarAction, enabled: !store.fleetView.isPresented) {
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
