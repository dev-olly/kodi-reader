import EpubKit
import ReaderUI
import SwiftUI

/// The same research queue is available from Home and the reading workspace.
struct RemindersListView: View {
    @Environment(AppModel.self) private var model
    var onOpen: ((ResearchReminder, String) -> Void)? = nil

    @State private var showCompleted = false
    @State private var bookFilter = ""
    @State private var query = ""
    @State private var editing: ReminderListEntry?
    @State private var deleted: ReminderListEntry?
    @State private var errorMessage: String?
    private var palette: ReminderPopoverPalette { .init(isDark: model.settings.theme.isDark) }

    private var entries: [ReminderListEntry] {
        model.reminderBooks.flatMap { book in
            book.reminders.map { ReminderListEntry(book: book, reminder: $0) }
        }
    }

    private var booksWithReminders: [BookRecord] {
        model.reminderBooks.filter { !$0.reminders.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var filteredEntries: [ReminderListEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            entry.reminder.isCompleted == showCompleted
                && (bookFilter.isEmpty || entry.book.id == bookFilter)
                && (search.isEmpty || [entry.reminder.title, entry.reminder.quotedText,
                                      entry.reminder.chapterTitle ?? "", entry.book.title, entry.book.author]
                    .joined(separator: "\n").localizedCaseInsensitiveContains(search))
        }.sorted {
            let lhs = showCompleted ? ($0.reminder.completedAt ?? $0.reminder.createdAt) : $0.reminder.createdAt
            let rhs = showCompleted ? ($1.reminder.completedAt ?? $1.reminder.createdAt) : $1.reminder.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id < $1.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            if entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    query.isEmpty && bookFilter.isEmpty
                        ? (showCompleted ? "No completed reminders" : "All caught up")
                        : "No matching reminders",
                    systemImage: showCompleted ? "checkmark.circle" : "tray",
                    description: Text(query.isEmpty && bookFilter.isEmpty
                        ? (showCompleted ? "Reminders you finish will appear here." : "Save a topic when you want to explore it later.")
                        : "Try another search or choose all books.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            row(entry)
                                .padding(.vertical, 14)
                            Rectangle().fill(palette.border).frame(height: 1)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
            if let deleted {
                HStack(spacing: 12) {
                    Text("Reminder deleted")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Undo") { undoDelete(deleted) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                    Button { self.deleted = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss deletion confirmation")
                }
                .padding(16)
                .background(model.settings.theme.accent.opacity(0.09))
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.ink)
        .background(palette.paper)
        .sheet(item: $editing) { entry in
            ReminderTitleEditor(entry: entry)
                .environment(model)
        }
        .alert("Couldn’t update reminder", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: booksWithReminders.map(\.id)) { _, ids in
            if !bookFilter.isEmpty, !ids.contains(bookFilter) { bookFilter = "" }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("YOUR REMINDERS")
                    .tracking(0.7)
                    .foregroundStyle(palette.muted)
                Text(String(format: "%02d", filteredEntries.count) + (showCompleted ? " COMPLETED" : " OPEN"))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, weight: .medium))
            Picker("Reminder status", selection: $showCompleted) {
                Text("Open").tag(false)
                Text("Completed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(palette.accent)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.muted)
                TextField("Search reminders", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search reminders")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear reminder search")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(palette.field, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
            HStack(spacing: 12) {
                Menu {
                    Picker("Book", selection: $bookFilter) {
                        Text("All books").tag("")
                        ForEach(booksWithReminders) { book in
                            Text(book.title).tag(book.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Text(booksWithReminders.first(where: { $0.id == bookFilter })?.title ?? "All books")
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Filter reminders by book")
                Spacer(minLength: 4)
            }
            .font(.system(size: 10))
            .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    private func row(_ entry: ReminderListEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Button { toggle(entry) } label: {
                    Image(systemName: entry.reminder.isCompleted ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((entry.reminder.isCompleted ? "Reopen reminder: " : "Complete reminder: ") + entry.reminder.title)
                .accessibilityValue(entry.reminder.isCompleted ? "Completed" : "Open")

                Button { open(entry) } label: {
                    Text(entry.reminder.title)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .strikethrough(entry.reminder.isCompleted)
                        .foregroundStyle(entry.reminder.isCompleted ? palette.muted : palette.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Return to the source")

                Menu {
                    Button("Edit reminder…") { editing = entry }
                    Button(entry.reminder.isCompleted ? "Mark as open" : "Mark as completed") { toggle(entry) }
                    Button("Open source") { open(entry) }
                    Divider()
                    Button("Delete reminder", role: .destructive) { delete(entry) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for reminder: " + entry.reminder.title)
            }

            Button { open(entry) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.book.title + " · " + sourceLabel(entry))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "arrow.up.right").font(.system(size: 8))
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .accessibilityLabel("Open source in " + entry.book.title)
            .help("Return to the source")
            .padding(.leading, 34)
        }
        .contextMenu {
            Button("Edit reminder…") { editing = entry }
            Button("Open source") { open(entry) }
            Button("Delete reminder", role: .destructive) { delete(entry) }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(palette.accent)
                    .frame(width: 37, height: 37)
                    .background(palette.iconBackground, in: .rect(cornerRadius: 11))
                Text("A thought for later.")
                    .font(.custom("Georgia", size: 23))
                Text("Keep reading. Save the topics you want to come back to here.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(palette.muted)
                Divider().padding(.vertical, 6)
                Label("Select a passage and choose Add reminder.", systemImage: "text.cursor")
                Label("In a note, type /remind or /task.", systemImage: "square.and.pencil")
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceLabel(_ entry: ReminderListEntry) -> String {
        if let chapter = entry.reminder.chapterTitle, !chapter.isEmpty { return chapter }
        if entry.reminder.locator.kind == .pdf { return "Page \(entry.reminder.locator.spineIndex + 1)" }
        switch entry.reminder.source {
        case .note: return "From a note"
        case .page: return "Saved page"
        case .selection: return "Selected passage"
        }
    }

    private func open(_ entry: ReminderListEntry) {
        if let onOpen { onOpen(entry.reminder, entry.book.id) }
        else { model.openReminder(entry.reminder, bookID: entry.book.id) }
    }

    private func toggle(_ entry: ReminderListEntry) {
        var reminder = model.reminder(with: entry.reminder.id, bookID: entry.book.id) ?? entry.reminder
        reminder.completedAt = reminder.isCompleted ? nil : Date()
        reminder.modifiedAt = Date()
        do { try model.updateReminder(reminder, bookID: entry.book.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ entry: ReminderListEntry) {
        do {
            try model.deleteReminder(entry.reminder.id, bookID: entry.book.id)
            deleted = entry
        } catch { errorMessage = error.localizedDescription }
    }

    private func undoDelete(_ entry: ReminderListEntry) {
        do {
            try model.restoreReminder(entry.reminder, bookID: entry.book.id)
            deleted = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct RemindersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Research reminders")
                    .font(.custom("Georgia", size: 23))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close reminders")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            RemindersListView { reminder, bookID in
                dismiss()
                model.openReminder(reminder, bookID: bookID)
            }
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 460, idealHeight: 620)
        .foregroundStyle(model.settings.theme.uiForeground)
        .background(ReminderPopoverPalette(isDark: model.settings.theme.isDark).paper)
    }
}

private struct ReminderListEntry: Identifiable {
    let book: BookRecord
    let reminder: ResearchReminder
    var id: String { book.id + ":" + reminder.id.uuidString }
}

private struct ReminderTitleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: ReminderListEntry
    @State private var title: String
    @State private var errorMessage: String?

    init(entry: ReminderListEntry) {
        self.entry = entry
        _title = State(initialValue: entry.reminder.title)
    }

    var body: some View {
        ReminderCaptureComposer(title: $title, quotedText: entry.reminder.quotedText,
            isEditing: true, errorMessage: errorMessage,
            onSave: save, onCancel: { dismiss() })
            .padding(20)
            .frame(width: 440)
            .background(model.settings.theme.surface)
            .environment(\.colorScheme, model.settings.theme.colorScheme)
    }

    private func save() {
        guard var reminder = model.reminder(with: entry.reminder.id, bookID: entry.book.id) else {
            errorMessage = "This reminder no longer exists."
            return
        }
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.modifiedAt = Date()
        do {
            try model.updateReminder(reminder, bookID: entry.book.id)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
