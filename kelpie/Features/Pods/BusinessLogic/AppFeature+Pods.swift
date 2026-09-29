import Foundation
import IdentifiedCollections

extension AppFeature.State {
  /// Members of the pod whose workspace is showing; empty when none is.
  var podWorkspaceSurfaceIDs: Set<UUID> {
    guard fleetView.isPresented, case .podWorkspace(let podID) = fleetView.mode,
      let pod = pods.pods[id: podID]
    else { return [] }
    return Set(pod.members.ids)
  }
}
