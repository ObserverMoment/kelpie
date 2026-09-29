import AppKit
import SwiftUI

/// Hosts a content's renderer view, resolved from the runtime and swapped when
/// the content hibernates or wakes.
struct ContentHostView: NSViewRepresentable {
  let contentID: ContentID
  let runtime: ContentRuntime
  /// The runtime is not observable; the reducer bumps this on hibernate and
  /// wake so `updateNSView` re-runs even when the layout value is unchanged.
  let epoch: UInt64

  /// This host's claim on the content it last mounted. Structural rebuilds
  /// and window-mode flips briefly overlap two hosts for one content; the
  /// claim keeps a stale host's late update from stealing the renderer.
  final class Coordinator {
    var claimedContentID: ContentID?
    var claim: UInt64 = 0
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    claim(context.coordinator)
    mount(into: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    // Retargeting to another content (tab switch) re-claims; the same content
    // only mounts while this host still holds the newest claim.
    if context.coordinator.claimedContentID != contentID {
      claim(context.coordinator)
    }
    guard runtime.isCurrentRenderHost(context.coordinator.claim, for: contentID) else { return }
    mount(into: container)
  }

  private func claim(_ coordinator: Coordinator) {
    coordinator.claimedContentID = contentID
    coordinator.claim = runtime.claimRenderHost(for: contentID)
  }

  private func mount(into container: NSView) {
    guard let renderer = runtime.renderer(for: contentID) else {
      container.subviews.forEach { $0.removeFromSuperview() }
      return
    }
    let hostedView: NSView
    if let surface = renderer as? GhosttySurfaceView {
      // Terminals mount through the scroll wrapper: it owns the surface's
      // frame, the overlay scroller, and zeroes the window safe-area insets.
      if let wrapper = container.subviews.first as? GhosttySurfaceScrollView,
        surface.scrollWrapper === wrapper
      {
        return
      }
      // Reuse the surface's own wrapper: a remount reparents it rather than
      // rebuilding at zero size, so the IOSurface keeps its frames.
      hostedView = surface.hostedView()
    } else {
      // Already showing the right renderer: nothing to do.
      if container.subviews.first === renderer { return }
      hostedView = renderer
    }
    container.subviews.forEach { $0.removeFromSuperview() }
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hostedView)
    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: container.topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}
