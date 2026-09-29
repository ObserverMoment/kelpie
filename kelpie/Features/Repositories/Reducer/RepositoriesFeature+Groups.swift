import ComposableArchitecture
import Foundation
import OrderedCollections
import SwiftUI

extension RepositoriesFeature {
  /// User-defined sidebar groups. Split out of the main switch, which is at
  /// type-checker capacity. Every arm writes `sidebar` under one lock; the
  /// post-reduce hook rebuilds the structure (see `cacheInvalidations`).
  static var repositoryGroupsReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .createRepositoryGroup(let name):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        @Dependency(\.uuid) var uuid
        let id = RepositoryGroupID(uuid().uuidString)
        state.$sidebar.withLock { $0.addGroup(id: id, name: trimmed) }
        return .none

      case .renameRepositoryGroup(let groupID, let name):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.sidebar.groups[groupID] != nil else { return .none }
        state.$sidebar.withLock { $0.renameGroup(groupID, to: trimmed) }
        return .none

      case .removeRepositoryGroup(let groupID):
        guard state.sidebar.groups[groupID] != nil else { return .none }
        let knownIDs = state.orderedRepositoryIDs()
        let ungroupable = state.ungroupableRepositoryIDs
        state.$sidebar.withLock { sidebar in
          sidebar.removeGroup(groupID)
          sidebar.normalizeSectionOrder(knownIDs: knownIDs, excluding: ungroupable)
        }
        return .none

      case .moveRepositoryToGroup(let repositoryID, let groupID):
        let knownIDs = state.orderedRepositoryIDs()
        let ungroupable = state.ungroupableRepositoryIDs
        state.$sidebar.withLock { sidebar in
          sidebar.assignGroup(of: repositoryID, to: groupID)
          // Reveal the result: a move into a collapsed group would otherwise
          // look like the repository vanished.
          if let groupID { sidebar.groups[groupID]?.collapsed = false }
          // Keep the key order agreeing with what the user now sees, so the
          // command palette and menu bar list repositories the same way.
          sidebar.normalizeSectionOrder(knownIDs: knownIDs, excluding: ungroupable)
        }
        return .none

      case .repositoryGroupExpansionChanged(let groupID, let isExpanded):
        guard state.sidebar.groups[groupID] != nil else { return .none }
        state.$sidebar.withLock { $0.groups[groupID]?.collapsed = !isExpanded }
        return .none

      case .repositoryGroupsMoved(let offsets, let destination):
        var ordered = Array(state.sidebar.groups.keys)
        guard !offsets.isEmpty, ordered.indices.contains(offsets.min() ?? 0),
          destination <= ordered.count
        else { return .none }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let knownIDs = state.orderedRepositoryIDs()
        let ungroupable = state.ungroupableRepositoryIDs
        // No `withAnimation` in reducer arms (#784); see `.repositoriesMoved`.
        state.$sidebar.withLock { sidebar in
          let groups = sidebar.groups
          sidebar.groups = OrderedDictionary(
            uniqueKeysWithValues: ordered.compactMap { id in groups[id].map { (id, $0) } }
          )
          sidebar.normalizeSectionOrder(knownIDs: knownIDs, excluding: ungroupable)
        }
        return .none

      default:
        return .none
      }
    }
  }
}
