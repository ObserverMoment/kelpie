import KelpieSettingsShared
import SwiftUI

/// The rolling summary under a thread's reply box. Hidden until the first
/// summary lands; a spinner shows while Claude rewrites it.
struct ThreadSummaryCard: View {
  let summary: String?
  let isSummarizing: Bool

  var body: some View {
    if summary != nil || isSummarizing {
      Divider()
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "text.alignleft")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(summary ?? "Summarizing…")
          .appFont(.callout)
          .foregroundStyle(summary == nil ? .tertiary : .secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isSummarizing {
          ProgressView()
            .controlSize(.small)
            .help("Updating the summary")
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(Color(nsColor: .controlBackgroundColor))
      .accessibilityIdentifier("threadSummaryCard")
    }
  }
}
