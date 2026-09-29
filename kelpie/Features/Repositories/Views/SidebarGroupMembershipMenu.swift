import ComposableArchitecture
import OrderedCollections
import SwiftUI

/// "Add to Group" submenu shared by the repository header menu and the folder
/// row context menu. Renders nothing until at least one group exists.
struct SidebarGroupMembershipMenu: View {
  let repositoryID: Repository.ID
  var isDisabled = false
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let groups = Array(store.state.sidebar.groups.values)
    if !groups.isEmpty {
      let currentGroupID = store.state.sidebar.groupID(containing: repositoryID)
      Menu("Add to Group", systemImage: "folder") {
        ForEach(groups) { group in
          Button {
            store.send(.moveRepositoryToGroup(repositoryID, group.id))
          } label: {
            if group.id == currentGroupID {
              Label(group.name, systemImage: "checkmark")
            } else {
              Text(group.name)
            }
          }
          .help("Move this item into \(group.name)")
          .disabled(group.id == currentGroupID)
        }
        if currentGroupID != nil {
          Divider()
          Button("Remove from Group") {
            store.send(.moveRepositoryToGroup(repositoryID, nil))
          }
          .help("Take this item out of its group")
        }
      }
      .help("Put this item in a sidebar group")
      .disabled(isDisabled)
    }
  }
}
