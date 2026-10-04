import ComposableArchitecture

extension AppFeature.Action {
  /// Whether an action can change a Fleet View structure input (`repositories`
  /// rows and structure, agent presence, layouts). Everything else skips the
  /// recompute while the overlay is up. Exhaustive, like `affectsWorktreeMenuSnapshot`,
  /// so a new action has to be classified.
  var affectsFleetViewStructure: Bool {
    switch self {
    case .repositories(let inner):
      return !inner.cacheInvalidations.isEmpty
    // Moving the Pods cursor reads the structure and changes none of its inputs.
    case .pods(.moveFocus), .pods(.columnCountChanged), .pods(.activateFocusedMember):
      return false
    // Pods add the pod-name caption and feed Pods mode, which the same pass computes.
    case .agentPresence, .terminals, .fleetView(.toggle), .fleetView(.togglePods), .fleetView(.toggleMailbox), .pods,
      .mailbox:
      return true
    case .fleetView, .settings, .updates, .commandPalette, .terminalEvent:
      return false
    case .applicationDidBecomeActive, .applicationDidResignActive,
      .appLaunched, .scenePhaseChanged, .openActionSelectionChanged,
      .refreshInstalledOpenActions, .installedOpenActionsResolved,
      .refreshWorktreesRequested,
      .worktreeSettingsLoaded, .openSelectedWorktree, .revealInFinder,
      .openWorktree, .openWorktreeFailed, .openFile, .openFileFromExplorer, .requestQuit,
      .requestTerminateAllTerminalSessions, .newTerminal, .renameSelectedTerminalTab,
      .selectTerminalTabAtIndex, .selectNextTerminalTab, .selectPreviousTerminalTab,
      .splitTerminal, .toggleWindowModeForFocusedPane, .toggleSplitZoom,
      .equalizeSplits, .focusSplit, .jumpToLatestUnread,
      .menuBarWorktreeSelected, .markAllNotificationsRead, .runScript, .runNamedScript,
      .manageRepositoryScripts,
      .stopScript, .stopRunScripts, .closeTab, .closeSurface,
      .startSearch, .searchSelection, .navigateSearchNext,
      .navigateSearchPrevious, .navigate, .sidebarVisibilityChanged,
      .systemNotificationsPermissionFailed, .deeplinkReceived,
      .deeplink, .commandAckTimedOut, .deeplinkConfirmationTimedOut,
      .deeplinkReferenceOpened, .settingsRelocationDidNotFinish, .settingsStoreUnreadable,
      .alert, .deeplinkInputConfirmation:
      return false
    }
  }
}
