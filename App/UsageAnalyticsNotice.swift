import SwiftUI

/// A one-time, non-modal explanation. Reading is never blocked by analytics.
struct UsageAnalyticsNotice: View {
    @Environment(AppModel.self) private var model
    @AppStorage("kodi.analytics.noticeVersion") private var noticeVersion = 0

    var body: some View {
        if noticeVersion < 2, model.analytics.isEnabled {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Help improve Kodi").font(.callout.weight(.medium))
                    Text("Background usage statistics include feature counts, reader engagement, Ask AI response timings, and approximate country, using a random device ID. Your book text, notes, drawings, and AI content stay out of analytics. You can turn this off in Settings → Privacy.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button("Turn off analytics") {
                            model.analytics.setEnabled(false)
                            noticeVersion = 2
                        }
                        Link("Privacy policy", destination: URL(string: "https://www.kodi-reader.app/privacy")!)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
                Button { noticeVersion = 2 } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss usage analytics notice")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
