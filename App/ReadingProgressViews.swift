import ReaderUI
import SwiftUI

/// Shared summary for Home, the reader popover, and Reading settings.
struct ReadingProgressSummary: View {
    let progress: ReadingProgress
    @Environment(AppModel.self) private var model

    private var seconds: Int { max(0, Int(progress.todaySeconds)) }
    private var minutes: Int { seconds / 60 }
    private var goalFraction: Double {
        min(1, max(0, progress.todaySeconds / Double(progress.goalMinutes * 60)))
    }
    private var streakLabel: String {
        progress.currentStreak == 1 ? "1 day streak" : "\(progress.currentStreak) day streak"
    }
    private var status: String {
        if progress.isTodayComplete {
            return progress.todaySeconds < Double(progress.goalMinutes * 60)
                ? "Today’s streak is earned, even with your new goal."
                : "Goal complete. A little reading, every day."
        }
        return progress.currentStreak > 0
            ? "Reach today’s goal to keep your streak going."
            : "Reach your goal to start a reading streak."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(minutes) / \(progress.goalMinutes) min")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Today’s reading")
                    .accessibilityValue("\(minutes) minutes and \(seconds % 60) seconds of a \(progress.goalMinutes) minute goal")
                Spacer(minLength: 12)
                Label(streakLabel, systemImage: "flame")
                    .font(.callout)
                    .foregroundStyle(model.settings.theme.accent)
                    .fixedSize()
            }
            ProgressView(value: goalFraction)
                .tint(model.settings.theme.accent)
                .accessibilityLabel("Daily reading goal")
                .accessibilityValue(progress.isTodayComplete ? "Day complete" : "\(Int(goalFraction * 100)) percent")
            HStack(alignment: .top, spacing: 6) {
                if progress.isTodayComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(model.settings.theme.accent)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .foregroundStyle(model.settings.theme.muted)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            if let error = progress.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ReadingProgressCard: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingGoal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Daily reading")
                    .font(.headline)
                Spacer()
                Button("Edit goal") { isShowingGoal = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.settings.theme.accent)
                    .popover(isPresented: $isShowingGoal, arrowEdge: .bottom) {
                        ReadingProgressPopover(progress: model.readingProgress)
                    }
            }
            ReadingProgressSummary(progress: model.readingProgress)
        }
        .padding(20)
        .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(model.settings.theme.border, lineWidth: 1)
        }
    }
}

struct ReadingProgressToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingGoal = false

    var body: some View {
        Button { isShowingGoal.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: model.readingProgress.isTodayComplete ? "checkmark.circle.fill" : "timer")
                Text("\(Int(model.readingProgress.todaySeconds) / 60)/\(model.readingProgress.goalMinutes)m")
                    .monospacedDigit()
                    .font(.caption)
            }
            .foregroundStyle(model.settings.theme.accent)
        }
        .help("Daily reading goal and streak")
        .accessibilityLabel("Daily reading goal and streak")
        .accessibilityValue("\(Int(model.readingProgress.todaySeconds) / 60) of \(model.readingProgress.goalMinutes) minutes, \(model.readingProgress.currentStreak) day streak\(model.readingProgress.isTodayComplete ? ", day complete" : "")")
        .popover(isPresented: $isShowingGoal, arrowEdge: .bottom) {
            ReadingProgressPopover(progress: model.readingProgress)
        }
    }
}

private struct ReadingProgressPopover: View {
    let progress: ReadingProgress
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Daily reading").font(.headline)
            ReadingProgressSummary(progress: progress)
            Divider()
            ReadingGoalEditor(progress: progress)
        }
        .padding(20)
        .frame(width: 350)
        .background(model.settings.theme.surface)
        .foregroundStyle(model.settings.theme.uiForeground)
        .tint(model.settings.theme.accent)
        .preferredColorScheme(model.settings.theme.colorScheme)
    }
}

/// Presets and custom minutes use the same explicit save action in every surface.
struct ReadingGoalEditor: View {
    let progress: ReadingProgress
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var saveFailed = false
    private let presets = [5, 10, 15, 30, 60]

    private var validatedMinutes: Int? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let minutes = Int(value), (5...1440).contains(minutes) else { return nil }
        return minutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily goal").font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { minutes in
                    Button { draft = String(minutes) } label: {
                        Text("\(minutes)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(validatedMinutes == minutes ? model.settings.theme.accent : .secondary)
                    .accessibilityLabel("\(minutes) minutes per day")
                    .accessibilityAddTraits(validatedMinutes == minutes ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                TextField("Minutes per day", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("Daily reading goal in minutes")
                Text("min").foregroundStyle(.secondary)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(validatedMinutes == nil || validatedMinutes == progress.goalMinutes)
            }
            if (!draft.isEmpty && validatedMinutes == nil) || saveFailed {
                Text("Enter a whole number from 5 to 1,440 minutes.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("5–1,440 minutes per day. Changes apply today; earned days stay complete.")
                .font(.caption)
                .foregroundStyle(model.settings.theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = String(progress.goalMinutes) }
        .onChange(of: progress.goalMinutes) { _, minutes in draft = String(minutes) }
        .onChange(of: draft) { _, _ in saveFailed = false }
    }

    private func save() {
        guard let minutes = validatedMinutes else { saveFailed = true; return }
        saveFailed = !progress.setGoal(minutes: minutes)
    }
}

struct ReadingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle("Show reading goal and streak", isOn: $model.settings.showReadingProgress)
            } footer: {
                Text("Display daily progress on Home and in the reader toolbar.")
            }
            Section("Today") {
                ReadingProgressSummary(progress: model.readingProgress)
            }
            Section("Reading goal") {
                ReadingGoalEditor(progress: model.readingProgress)
            }
            Section("How reading time counts") {
                Text("Time adds up across EPUBs, PDFs, and saved articles while the reader is in front. Browsing webpages does not count.")
                Text("Tracking pauses after five minutes without keyboard, click, or scroll input, and resumes when you interact. It also pauses when you leave the reader or your Mac sleeps.")
                Text("Your streak and reading history stay on this Mac, work with usage analytics turned off, and remain when you delete a book.")
            }
            .font(.caption)
        }
        .formStyle(.grouped)
        .tint(model.settings.theme.accent)
        .preferredColorScheme(model.settings.theme.colorScheme)
    }
}
