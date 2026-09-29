import AppKit
import ComposableArchitecture
import KelpieSettingsShared
import OrderedCollections
import Sharing
import SwiftUI

struct SidebarListView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @FocusState private var isSidebarFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile
  /// Read here purely so SwiftUI re-runs the body (and fires the `.onChange`
  /// below) when the menu writes a new value. The structure compute itself
  /// reads the toggles via local `@Shared` inside the reducer.
  @Shared(.sidebarGroupPinnedRows) private var groupPinnedRows: Bool
  @Shared(.sidebarGroupActiveRows) private var groupActiveRows: Bool
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
  @Shared(.sidebarSectionSort) private var sectionSort: SidebarSectionSort

  var body: some View {
    let state = store.state
    let structure = state.sidebarStructure
    let currentSelections = state.sidebarSelections
    let selection = Binding<Set<SidebarSelection>>(
      get: { currentSelections },
      set: { newValue in
        guard newValue != currentSelections else { return }
        store.send(.selectionChanged(newValue, focusTerminal: true))
      }
    )
    let pendingSidebarReveal = state.pendingSidebarReveal

    // The only legal view-side computation: a trivial join from the
    // reducer-derived `slotByID` against the Cmd state + shortcut overrides.
    // Gated on `isPressed` so the dict is empty when no hints are visible.
    let shortcutHintByID: [Worktree.ID: String]
    if commandKeyObserver.isPressed {
      let overrides = settingsFile.global.shortcutOverrides
      shortcutHintByID = structure.slotByID.compactMapValues { index in
        AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: index, overrides: overrides)
      }
    } else {
      shortcutHintByID = [:]
    }

    return ScrollViewReader { scrollProxy in
      // Three runs, three `ForEach`es, so each run's `.onMove` only sees its
      // own indices: groups reorder via their menu, members reorder inside
      // their group, ungrouped repos reorder among themselves. Membership
      // changes through the Add to Group menu.
      let groupSections = structure.groupBlockSections
      List(selection: selection) {
        ForEach(structure.leadingSections) { section in
          SidebarSectionDispatcher(
            section: section,
            structure: structure,
            shortcutHintByID: shortcutHintByID,
            store: store,
            terminalManager: terminalManager
          )
        }
        ForEach(Array(groupSections.enumerated()), id: \.element.id) { index, section in
          SidebarSectionDispatcher(
            section: section,
            structure: structure,
            shortcutHintByID: shortcutHintByID,
            allowsReordering: sectionSort.allowsReordering,
            groupIndex: index,
            groupCount: groupSections.count,
            store: store,
            terminalManager: terminalManager
          )
        }
        ForEach(structure.ungroupedSections) { section in
          SidebarSectionDispatcher(
            section: section,
            structure: structure,
            shortcutHintByID: shortcutHintByID,
            store: store,
            terminalManager: terminalManager
          )
        }
        .onMove(
          perform: sectionSort.allowsReordering
            ? { offsets, destination in
              guard let move = structure.ungroupedMove(offsets: offsets, destination: destination) else { return }
              store.send(.repositoriesMoved(move.offsets, move.destination))
            } : nil)
      }
      .listStyle(.sidebar)
      // Only the group card's bottom padding row is shorter than the sidebar's
      // default minimum; without this it stretches into an empty band.
      .environment(\.defaultMinListRowHeight, SidebarGroupCardFill.verticalInset)
      .focused($isSidebarFocused)
      .frame(minWidth: 220)
      .onChange(of: groupPinnedRows, initial: false) { _, _ in
        store.send(.sidebarGroupingTogglesChanged)
      }
      .onChange(of: groupActiveRows, initial: false) { _, _ in
        store.send(.sidebarGroupingTogglesChanged)
      }
      .onChange(of: nestWorktreesByBranch, initial: false) { _, _ in
        store.send(.sidebarNestByBranchChanged)
      }
      .onChange(of: sectionSort, initial: true) { oldValue, newValue in
        // `initial: true` so a change made while the sidebar column is
        // collapsed still lands on the next appear (the View menu writes
        // `@Shared` even when this view is unmounted). Animate a real toggle;
        // the initial appear (oldValue == newValue) resyncs without motion.
        store.send(.sidebarSectionSortChanged, animation: oldValue == newValue ? nil : .default)
      }
      .dropDestination(for: URL.self) { urls, _ in
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        store.send(.openRepositories(fileURLs))
        return true
      }
      .onKeyPress { keyPress in
        guard !keyPress.characters.isEmpty else { return .ignored }
        let navigationKeys: Set<KeyEquivalent> = [
          .upArrow, .downArrow, .leftArrow, .rightArrow,
          .home, .end, .pageUp, .pageDown,
        ]
        guard !navigationKeys.contains(keyPress.key) else { return .ignored }
        let hasCommandModifier = keyPress.modifiers.contains(.command)
        if hasCommandModifier { return .ignored }
        guard let worktreeID = store.selectedWorktreeID,
          state.sidebarSelectedWorktreeIDs.count == 1,
          state.sidebarSelectedWorktreeIDs.contains(worktreeID),
          let host = terminalManager.hostIfExists(for: worktreeID)
        else { return .ignored }
        host.focusAndInsertText(keyPress.characters)
        return .handled
      }
      .background(
        // NSOutlineView consumes arrow keys before SwiftUI `onKeyPress` runs.
        SidebarRightArrowMonitor(isSidebarFocused: isSidebarFocused) {
          guard let worktreeID = store.selectedWorktreeID,
            state.sidebarSelectedWorktreeIDs.count == 1,
            state.sidebarSelectedWorktreeIDs.contains(worktreeID),
            let host = terminalManager.hostIfExists(for: worktreeID)
          else { return false }
          host.focusSelectedTab()
          return true
        }
      )
      .task(id: pendingSidebarReveal?.id) {
        await revealPendingSidebarWorktree(pendingSidebarReveal, with: scrollProxy)
      }
    }
  }

  @MainActor
  private func revealPendingSidebarWorktree(
    _ pendingSidebarReveal: RepositoriesFeature.PendingSidebarReveal?,
    with scrollProxy: ScrollViewProxy
  ) async {
    guard let pendingSidebarReveal else { return }
    // Give SwiftUI time to materialize newly expanded section rows before scrolling.
    await Task.yield()
    await Task.yield()
    isSidebarFocused = true
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy.scrollTo(pendingSidebarReveal.worktreeID, anchor: .center)
    }
    store.send(.consumePendingSidebarReveal(pendingSidebarReveal.id))
  }
}

/// Single switch that turns one `SidebarStructure.Section` into the right
/// SwiftUI view. The view has no other dispatch: the structure already
/// answered "what kind of section, what rows, in what order".
private struct SidebarSectionDispatcher: View {
  let section: SidebarStructure.Section
  let structure: SidebarStructure
  let shortcutHintByID: [Worktree.ID: String]
  /// Whether member drags may reorder (off while a display sort is active).
  var allowsReordering = false
  /// Position of a `.repositoryGroup` section among the groups, for its
  /// Move Up / Move Down menu items.
  var groupIndex = 0
  var groupCount = 0
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    switch section {
    case .placeholder:
      SidebarPlaceholderView()
        .moveDisabled(true)
    case .highlight(let kind, let rowIDs):
      SidebarHighlightSection(
        kind: kind,
        rowIDs: rowIDs,
        store: store,
        terminalManager: terminalManager,
        repositoryHighlightByID: structure.repositoryHighlightByID,
        shortcutHintByID: shortcutHintByID
      )
      .moveDisabled(true)
    case .failedRepository(let repositoryID, let rootURL, let customTitle, let color, let isRemote):
      SidebarFailedRepositorySection(
        repositoryID: repositoryID,
        rootURL: rootURL,
        customTitle: customTitle,
        color: color,
        isRemote: isRemote,
        store: store
      )
    case .environmentBlockedRepository(let repositoryID, let rootURL, let customTitle, let color):
      SidebarBlockedRepositorySection(
        repositoryID: repositoryID,
        rootURL: rootURL,
        customTitle: customTitle,
        color: color,
        store: store
      )
    case .folder(let repositoryID, let rowID):
      if let repository = store.state.repositories[id: repositoryID] {
        // Empty header keeps `.listStyle(.sidebar)` from merging two
        // consecutive folder repos visually.
        Section {
          SidebarFolderRow(
            repository: repository,
            rowID: rowID,
            shortcutHint: shortcutHintByID[rowID],
            store: store,
            terminalManager: terminalManager
          )
        } header: {
          EmptyView()
        }
      }
    case .repositoryGroup(let groupID, let name, let isCollapsed, let members):
      SidebarRepositoryGroupSection(
        groupID: groupID,
        name: name,
        isCollapsed: isCollapsed,
        members: members,
        groupIndex: groupIndex,
        groupCount: groupCount,
        structure: structure,
        shortcutHintByID: shortcutHintByID,
        allowsReordering: allowsReordering,
        store: store,
        terminalManager: terminalManager
      )
    case .repository(let repositoryID, let groups):
      if let repository = store.state.repositories[id: repositoryID] {
        SidebarGitRepositorySection(
          repository: repository,
          groups: groups,
          hoistSummary: structure.hoistSummaryByRepositoryID[repositoryID],
          shortcutHintByID: shortcutHintByID,
          store: store,
          terminalManager: terminalManager
        )
      }
    }
  }
}

private struct SidebarGitRepositorySection: View {
  let repository: Repository
  let groups: [SidebarItemGroup]
  /// Non-nil when one or more of this repo's rows were hoisted into the
  /// highlight sections; rendered as a muted summary line under the rows.
  let hoistSummary: SidebarHoistSummary?
  let shortcutHintByID: [Worktree.ID: String]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  var body: some View {
    let isRemovingRepository = store.state.isRemovingRepository(repository)
    let isResolvingRemote = store.state.resolvingRemoteRepositoryIDs.contains(repository.id)
    let section = store.state.sidebar.sections[repository.id]
    Section(isExpanded: repositoryExpansionBinding) {
      SidebarItemsView(
        repository: repository,
        groups: groups,
        shortcutHintByID: shortcutHintByID,
        store: store,
        terminalManager: terminalManager
      )
      if let hoistSummary {
        SidebarHoistSummaryRow(
          repositoryName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
          summary: hoistSummary,
          store: store
        )
      }
    } header: {
      RepoSectionHeaderView(
        name: repository.name,
        customTitle: section?.title,
        color: section?.color,
        isRemoving: isRemovingRepository,
        hostInfo: repository.host?.displayAuthority,
        isResolving: isResolvingRemote
      )
    }
    .sectionActions {
      SidebarSectionActionsView(
        repositoryID: repository.id,
        isRemovingRepository: isRemovingRepository,
        isRemote: repository.host != nil,
        store: store
      )
    }
  }

  private var repositoryExpansionBinding: Binding<Bool> {
    Binding(
      get: { store.state.isRepositoryExpanded(repository.id) },
      set: { isExpanded in
        store.send(.repositoryExpansionChanged(repository.id, isExpanded: isExpanded))
      }
    )
  }
}

/// Muted, unselectable line under a repo's rows summarizing how many were
/// hoisted into the Pinned / Active sections, with a click that scrolls up to
/// them. Carries no `.tag`, so it stays out of selection and arrow-key
/// navigation; lives inside the `Section` body so it folds away when the repo
/// section is collapsed.
private struct SidebarHoistSummaryRow: View {
  let repositoryName: String
  let summary: SidebarHoistSummary
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Button {
      store.send(.revealHoistedWorktreeInSidebar(summary.revealTarget))
    } label: {
      HStack(spacing: 8) {
        if summary.pinnedCount > 0 {
          SidebarHoistSummarySegment(kind: .pinned, count: summary.pinnedCount)
        }
        if summary.activeCount > 0 {
          SidebarHoistSummarySegment(kind: .active, count: summary.activeCount)
        }
        Spacer(minLength: 0)
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    .listRowInsets(.leading, 0)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 4)
    .moveDisabled(true)
    .help("Show \(repositoryName)'s pinned and active worktrees")
    .accessibilityLabel("\(summary.label) above. Scroll to them.")
  }
}

/// One bucket of the hoist summary: its count followed by the same colored dot
/// the matching highlight section header shows.
private struct SidebarHoistSummarySegment: View {
  let kind: SidebarStructure.HighlightKind
  let count: Int

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(count) \(kind.summaryNoun)")
      SidebarHighlightHeaderDot(color: kind.indicatorColor)
    }
  }
}

private struct SidebarSectionActionsView: View {
  let repositoryID: Repository.ID
  let isRemovingRepository: Bool
  /// Remote (SSH) repositories hide the local-only "Repository Settings…" and
  /// route Remove to `removeRemoteRepository` (drops the config; remote files
  /// untouched). Worktree creation (`+`) works for remote repos too.
  var isRemote: Bool = false
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Menu {
      Button("Customize Appearance…", systemImage: "paintbrush") {
        store.send(.requestCustomizeRepository(repositoryID))
      }
      .help("Set a custom title or color")
      .disabled(isRemovingRepository)
      if isRemote {
        Button("Edit Connection…", systemImage: "wifi") {
          store.send(.requestEditRemoteRepository(repositoryID))
        }
        .help("Edit the SSH server, port, user, or path")
        .disabled(isRemovingRepository)
      } else {
        Button("Repository Settings…", systemImage: "gear") {
          store.send(.openRepositorySettings(repositoryID))
        }
        .help("Repository Settings")
      }
      SidebarGroupMembershipMenu(repositoryID: repositoryID, isDisabled: isRemovingRepository, store: store)
      Divider()
      Button(
        isRemote ? "Remove Remote Repository…" : "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive
      ) {
        store.send(.requestDeleteRepository(repositoryID))
      }
      .help(isRemote ? "Remove this remote repository (remote files are untouched)" : "Remove Repository")
      .disabled(isRemovingRepository)
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("Options")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .menuStyle(.secondaryToolbar)

    Button {
      store.send(.createRandomWorktreeInRepository(repositoryID))
    } label: {
      Image(systemName: "plus")
        .accessibilityLabel("New Worktree")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isRemovingRepository)
    .foregroundStyle(.secondary)
    .help("New Worktree")
    .padding(.trailing, 4)
  }
}

/// A user-defined group as one list section drawn as a card: a header row,
/// then each member's own header row and worktree rows, then a padding row.
/// Plain rows rather than nested `Section`s because the sidebar list style
/// paints `listRowBackground` on rows only, never on section headers.
/// Membership changes through menus; members reorder among themselves by drag.
private struct SidebarRepositoryGroupSection: View {
  let groupID: RepositoryGroupID
  let name: String
  let isCollapsed: Bool
  let members: [SidebarStructure.Section]
  let groupIndex: Int
  let groupCount: Int
  let structure: SidebarStructure
  let shortcutHintByID: [Worktree.ID: String]
  let allowsReordering: Bool
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    // Empty header keeps `.listStyle(.sidebar)` from merging neighbouring
    // cards; the header row below is an ordinary row so it takes the fill.
    Section {
      SidebarGroupHeaderRow(
        groupID: groupID,
        name: name,
        isCollapsed: isCollapsed,
        groupIndex: groupIndex,
        groupCount: groupCount,
        store: store
      )
      .listRowBackground(SidebarGroupCardFill(edge: isCollapsed ? .single : .top))
      .moveDisabled(true)
      if !isCollapsed {
        // Members reorder among themselves only: the move maps into this
        // group's slice of the reorderable order, never across groups.
        ForEach(members) { member in
          SidebarGroupMemberRows(
            member: member,
            structure: structure,
            shortcutHintByID: shortcutHintByID,
            store: store,
            terminalManager: terminalManager
          )
        }
        .onMove(
          perform: allowsReordering
            ? { offsets, destination in
              guard let move = structure.memberMove(in: groupID, offsets: offsets, destination: destination)
              else { return }
              store.send(.repositoriesMoved(move.offsets, move.destination))
            } : nil)
        SidebarGroupCardBottomPaddingRow()
      }
    } header: {
      EmptyView()
    }
  }
}

/// Rows for one member of a group: a repository contributes a header row
/// (chevron, name, actions) and, while expanded, its worktree rows; a folder
/// contributes its single row.
private struct SidebarGroupMemberRows: View {
  let member: SidebarStructure.Section
  let structure: SidebarStructure
  let shortcutHintByID: [Worktree.ID: String]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    switch member {
    case .repository(let repositoryID, let groups):
      if let repository = store.state.repositories[id: repositoryID] {
        let section = store.state.sidebar.sections[repositoryID]
        let isExpanded = store.state.isRepositoryExpanded(repositoryID)
        // Resolve the header's inputs here so the header row itself tracks
        // no store state; one observing body per member, not two.
        // The repository (header and rows) sits one small step in from the
        // group title, as a single left-aligned column.
        SidebarGroupedRepositoryHeaderRow(
          repository: repository,
          customTitle: section?.title,
          color: section?.color,
          isExpanded: isExpanded,
          isRemovingRepository: store.state.isRemovingRepository(repository),
          isResolvingRemote: store.state.resolvingRemoteRepositoryIDs.contains(repositoryID),
          store: store
        )
        .padding(.leading, SidebarNestLayout.groupMemberIndent)
        .listRowBackground(SidebarGroupCardFill(edge: .middle))
        if isExpanded {
          SidebarItemsView(
            repository: repository,
            groups: groups,
            shortcutHintByID: shortcutHintByID,
            store: store,
            terminalManager: terminalManager
          )
          .padding(.leading, SidebarNestLayout.groupMemberIndent)
          .listRowBackground(SidebarGroupCardFill(edge: .middle))
          if let hoistSummary = structure.hoistSummaryByRepositoryID[repositoryID] {
            SidebarHoistSummaryRow(
              repositoryName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
              summary: hoistSummary,
              store: store
            )
            .padding(.leading, SidebarNestLayout.groupMemberIndent)
            .listRowBackground(SidebarGroupCardFill(edge: .middle))
          }
        }
      }
    case .folder(let repositoryID, let rowID):
      if let repository = store.state.repositories[id: repositoryID] {
        SidebarFolderRow(
          repository: repository,
          rowID: rowID,
          shortcutHint: shortcutHintByID[rowID],
          store: store,
          terminalManager: terminalManager
        )
        .padding(.leading, SidebarNestLayout.groupMemberIndent)
        .listRowBackground(SidebarGroupCardFill(edge: .middle))
      }
    case .highlight, .placeholder, .failedRepository, .environmentBlockedRepository, .repositoryGroup:
      EmptyView()
    }
  }
}

/// Group card header: disclosure chevron, folder glyph and name, and the
/// group's ellipsis menu (revealed on hover, like a section's actions).
private struct SidebarGroupHeaderRow: View {
  let groupID: RepositoryGroupID
  let name: String
  let isCollapsed: Bool
  let groupIndex: Int
  let groupCount: Int
  let store: StoreOf<RepositoriesFeature>
  @State private var isHovered = false
  @State private var isRenaming = false
  @State private var draftName = ""

  var body: some View {
    // Folder and name lead; the disclosure chevron sits at the trailing edge so
    // member titles below can start at the card's left edge.
    HStack(spacing: 4) {
      Label {
        Text(name)
      } icon: {
        // The toolbar's "New Group" glyph minus its plus: SF Symbols has no
        // badge-less variant, so the badge (the first palette layer) is
        // painted clear and the folder and grid take the foreground.
        Image(systemName: "square.grid.3x1.folder.badge.plus")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.clear, .primary)
          .accessibilityHidden(true)
      }
      .foregroundStyle(.primary)
      .appFontInheriting(.subheadline, weight: .semibold)
      Spacer(minLength: 4)
      Menu {
        Button("Rename Group…", systemImage: "pencil") {
          draftName = name
          isRenaming = true
        }
        .help("Rename this group")
        Divider()
        // `toOffset` is the insertion index before removal, so moving one
        // slot down targets two past the current index.
        Button("Move Up", systemImage: "arrow.up") {
          store.send(.repositoryGroupsMoved([groupIndex], groupIndex - 1))
        }
        .help("Move this group above the previous one")
        .disabled(groupIndex == 0)
        Button("Move Down", systemImage: "arrow.down") {
          store.send(.repositoryGroupsMoved([groupIndex], groupIndex + 2))
        }
        .help("Move this group below the next one")
        .disabled(groupIndex >= groupCount - 1)
        Divider()
        Button("Remove Group", systemImage: "folder.badge.minus", role: .destructive) {
          store.send(.removeRepositoryGroup(groupID))
        }
        .help("Remove this group; its repositories stay in the sidebar")
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Group Options")
          .contentShape(Rectangle())
      }
      .menuStyle(.secondaryToolbar)
      .opacity(isHovered ? 1 : 0)
      SidebarDisclosureChevron(isExpanded: !isCollapsed) {
        store.send(.repositoryGroupExpansionChanged(groupID, isExpanded: isCollapsed))
      }
      .help(isCollapsed ? "Expand group" : "Collapse group")
    }
    // Top padding matches the card's top margin so the title sits inside it; a
    // collapsed group has no padding row below, so the header pads itself.
    .padding(.top, SidebarGroupCardFill.verticalInset + 2)
    .padding(.bottom, isCollapsed ? SidebarGroupCardFill.verticalInset + 2 : 2)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .alert("Rename Group", isPresented: $isRenaming) {
      TextField("Name", text: $draftName)
      Button("Rename") {
        store.send(.renameRepositoryGroup(groupID, name: draftName))
      }
      Button("Cancel", role: .cancel) {}
    }
  }
}

/// A member repository's header inside a group card: chevron, the usual
/// repository header, and the section actions revealed on hover.
private struct SidebarGroupedRepositoryHeaderRow: View {
  let repository: Repository
  let customTitle: String?
  let color: RepositoryColor?
  let isExpanded: Bool
  let isRemovingRepository: Bool
  let isResolvingRemote: Bool
  let store: StoreOf<RepositoriesFeature>
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 4) {
      SidebarDisclosureChevron(isExpanded: isExpanded) {
        store.send(.repositoryExpansionChanged(repository.id, isExpanded: !isExpanded))
      }
      .help(isExpanded ? "Collapse repository" : "Expand repository")
      RepoSectionHeaderView(
        name: repository.name,
        customTitle: customTitle,
        color: color,
        isRemoving: isRemovingRepository,
        hostInfo: repository.host?.displayAuthority,
        isResolving: isResolvingRemote
      )
      Spacer(minLength: 4)
      SidebarSectionActionsView(
        repositoryID: repository.id,
        isRemovingRepository: isRemovingRepository,
        isRemote: repository.host != nil,
        store: store
      )
      .opacity(isHovered ? 1 : 0)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}

/// The rotating chevron used by rows that stand in for a section header.
private struct SidebarDisclosureChevron: View {
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.right")
        .imageScale(.small)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: SidebarNestLayout.groupChevronWidth, height: SidebarNestLayout.groupChevronWidth)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    .animation(.easeOut(duration: 0.15), value: isExpanded)
  }
}

private struct SidebarFailedRepositorySection: View {
  let repositoryID: Repository.ID
  let rootURL: URL
  let customTitle: String?
  let color: RepositoryColor?
  /// A disconnected SSH repo: route Remove to the remote config store and offer
  /// "Edit Connection…" to fix a bad host/path, rather than the local-roots flow.
  let isRemote: Bool
  let store: StoreOf<RepositoriesFeature>

  private func removeFailedRepository() {
    store.send(isRemote ? .requestDeleteRepository(repositoryID) : .requestRemoveFailedRepository(repositoryID))
  }

  var body: some View {
    let standardizedRootURL = rootURL.standardizedFileURL
    let fallbackName = Repository.name(for: standardizedRootURL)
    let displayName = Repository.sidebarDisplayName(custom: customTitle, fallback: fallbackName)
    let path = standardizedRootURL.path(percentEncoded: false)
    Section {
      FailedRepositoryRow(
        name: displayName,
        path: path,
        removeRepository: removeFailedRepository
      )
      .tag(SidebarSelection.failedRepository(repositoryID))
      .moveDisabled(true)
    } header: {
      RepoSectionHeaderView(
        name: fallbackName,
        customTitle: customTitle,
        color: color,
        isRemoving: false,
        hostInfo: store.state.repositories[id: repositoryID]?.host?.displayAuthority
      )
    }
    .sectionActions {
      // No `+`: the repo isn't loadable, so worktree create is meaningless.
      Menu {
        if isRemote {
          Button("Edit Connection…", systemImage: "wifi") {
            store.send(.requestEditRemoteRepository(repositoryID))
          }
          .help("Edit the SSH server, port, user, or path")
        }
        Button(
          isRemote ? "Remove Remote Repository…" : "Remove Repository…",
          systemImage: "folder.badge.minus",
          role: .destructive
        ) {
          removeFailedRepository()
        }
        .help(
          isRemote
            ? "Remove this remote repository (remote files are untouched)"
            : "Remove this repository from Kelpie. Files on disk are untouched."
        )
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Options")
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .menuStyle(.secondaryToolbar)
    }
  }
}

/// A git repo hidden behind an environment block (unaccepted license / missing
/// tools). Renders a non-selectable warning row so the repo stays visible; the
/// bottom banner owns the remedy, so there's no per-row action here.
private struct SidebarBlockedRepositorySection: View {
  let repositoryID: Repository.ID
  let rootURL: URL
  let customTitle: String?
  let color: RepositoryColor?
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let standardizedRootURL = rootURL.standardizedFileURL
    let fallbackName = Repository.name(for: standardizedRootURL)
    let displayName = Repository.sidebarDisplayName(custom: customTitle, fallback: fallbackName)
    let path = standardizedRootURL.path(percentEncoded: false)
    Section {
      EnvironmentBlockedRepositoryRow(
        name: displayName,
        path: path,
        // Path-based removal, so it works even though the blocked root has no
        // `loadFailuresByID` entry to key on.
        removeRepository: { store.send(.requestRemoveFailedRepository(repositoryID)) }
      )
      .moveDisabled(true)
    } header: {
      RepoSectionHeaderView(
        name: fallbackName,
        customTitle: customTitle,
        color: color,
        isRemoving: false,
        hostInfo: nil
      )
    }
  }
}

// MARK: - Sidebar placeholder.

private struct SidebarPlaceholderView: View {
  var body: some View {
    ForEach(0..<2, id: \.self) { section in
      Section {
        ForEach(0..<3, id: \.self) { _ in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("placeholder-branch")
                .appFont(.body)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
              Text("placeholder")
                .appFont(.footnote)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
            }
          } icon: {
            Image(systemName: "arrow.triangle.branch")
              .accessibilityHidden(true)
              .foregroundStyle(.secondary)
              .redacted(reason: .placeholder)
              .shimmer(isActive: true)
          }
        }
      } header: {
        Text(section == 0 ? "repository" : "second-repo")
          .foregroundStyle(.secondary)
          .redacted(reason: .placeholder)
          .shimmer(isActive: true)
      }
    }
  }
}

private struct SidebarRightArrowMonitor: NSViewRepresentable {
  let isSidebarFocused: Bool
  let handle: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.update(isSidebarFocused: isSidebarFocused, handle: handle)
    context.coordinator.install(host: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(isSidebarFocused: isSidebarFocused, handle: handle)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    private var isSidebarFocused = false
    private var handle: () -> Bool = { false }
    private var monitor: Any?

    func update(isSidebarFocused: Bool, handle: @escaping () -> Bool) {
      self.isSidebarFocused = isSidebarFocused
      self.handle = handle
    }

    func install(host: NSView) {
      guard monitor == nil else { return }
      // Local monitors are process-global; scope to the host's window so a
      // stale `@FocusState` in another window can't steal the keystroke.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak host] event in
        guard event.specialKey == .rightArrow else { return event }
        let userModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.isDisjoint(with: userModifiers) else { return event }
        guard let host, event.window === host.window else { return event }
        let consumed = MainActor.assumeIsolated {
          (self?.isSidebarFocused ?? false) && (self?.handle() ?? false)
        }
        return consumed ? nil : event
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
