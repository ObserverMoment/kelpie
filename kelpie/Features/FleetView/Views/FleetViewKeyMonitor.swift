import AppKit
import SwiftUI

/// Window-scoped local key monitor alive while Fleet View is presented. The
/// Ghostty surface reclaims first responder aggressively, so Fleet View does
/// not rely on SwiftUI focus: every keystroke in this window is decided by
/// `FleetViewKeyDecision` before AppKit dispatches it. Command chords are
/// offered to the menu bar and otherwise dropped (so ⌘V cannot paste into the
/// hidden terminal); everything else is consumed. `isActive` turns the monitor
/// into a bystander during the exit transition, so the terminal the user just
/// opened receives its first keystrokes.
struct FleetViewKeyMonitor: NSViewRepresentable {
  let isActive: Bool
  let onDecision: (FleetViewKeyDecision) -> Void

  func makeNSView(context: Context) -> HostView {
    let view = HostView(frame: .zero)
    view.coordinator = context.coordinator
    context.coordinator.update(isActive: isActive, onDecision: onDecision)
    return view
  }

  func updateNSView(_ nsView: HostView, context: Context) {
    context.coordinator.update(isActive: isActive, onDecision: onDecision)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  static func dismantleNSView(_ nsView: HostView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Installs on window attach and uninstalls on detach, so the monitor never
  /// outlives the view or installs after a dismantle.
  final class HostView: NSView {
    weak var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        coordinator?.install(host: self)
      } else {
        coordinator?.uninstall()
      }
    }
  }

  @MainActor
  final class Coordinator {
    private var isActive = false
    private var onDecision: (FleetViewKeyDecision) -> Void = { _ in }
    private var monitor: Any?

    func update(isActive: Bool, onDecision: @escaping (FleetViewKeyDecision) -> Void) {
      self.isActive = isActive
      self.onDecision = onDecision
    }

    func install(host: NSView) {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak host] event in
        guard let host, event.window === host.window else { return event }
        let decision = FleetViewKeyDecision.decide(
          keyCode: event.keyCode, specialKey: event.specialKey, modifiers: event.modifierFlags)
        let consumed = MainActor.assumeIsolated {
          guard let self, self.isActive else { return false }
          switch decision {
          case .menuShortcut:
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
          case .swallow:
            break
          case .move, .activate, .dismiss:
            self.onDecision(decision)
          }
          return true
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
