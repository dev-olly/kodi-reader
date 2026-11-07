import EpubKit
import SwiftUI

/// The source stays fixed when focusing the title field clears the web selection.
struct ReminderCaptureDraft: Identifiable {
    let id = UUID()
    let bookID: String
    let source: ResearchReminder.Source
    let locator: Locator
    let quotedText: String
    let chapterTitle: String?
    let annotationID: UUID?
    let existingReminderID: UUID?
    let anchor: CGRect
}

struct ReminderCaptureComposer: View {
    @Binding var title: String
    let quotedText: String
    var isEditing = false
    var errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var titleFocused: Bool

    private var palette: ReminderPopoverPalette { .init(isDark: colorScheme == .dark) }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReminderPopoverHeader(title: isEditing ? "Edit Reminder" : "Add Reminder",
                                  palette: palette, onDismiss: onCancel)

            VStack(alignment: .leading, spacing: 9) {
                Text("What would you like to research?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink)
                TextField("A question, an idea, a little more context…", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.ink)
                    .lineSpacing(4)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .frame(minHeight: 48, alignment: .leading)
                    .background(palette.field, in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(titleFocused ? palette.accent.opacity(0.75) : palette.border,
                                          lineWidth: titleFocused ? 1.5 : 1)
                    }
                    .focused($titleFocused)
                    .accessibilityLabel("Reminder title")
                    .onSubmit { if canSave { onSave() } }
            }

            if !quotedText.isEmpty {
                ReminderSourceQuote(text: quotedText, palette: palette)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 16) {
                Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1)
                HStack {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(ReminderQuietButtonStyle(palette: palette))
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 12)
                    Button(action: onSave) {
                        Label(isEditing ? "Save Reminder" : "Add Reminder",
                              systemImage: isEditing ? "checkmark" : "plus")
                    }
                    .buttonStyle(ReminderPrimaryButtonStyle(palette: palette))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
        }
        .modifier(ReminderPopoverSurface(palette: palette))
        .onAppear { titleFocused = true }
        .accessibilityElement(children: .contain)
    }
}

struct ResearchReminderPopover: View {
    let reminder: ResearchReminder
    let onEdit: () -> Void
    let onComplete: () -> Void
    let onShowAll: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ReminderPopoverPalette { .init(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReminderPopoverHeader(title: "A thought for later", palette: palette, onDismiss: onDismiss)
            Text(reminder.title)
                .font(.system(size: 16, weight: .medium))
                .lineSpacing(5)
                .foregroundStyle(palette.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(reminder.title)
            if !reminder.quotedText.isEmpty {
                ReminderSourceQuote(text: reminder.quotedText, palette: palette)
            }
            VStack(spacing: 16) {
                Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1)
                HStack(spacing: 12) {
                    Button("Edit", action: onEdit)
                        .buttonStyle(ReminderQuietButtonStyle(palette: palette))
                    Button("All reminders", action: onShowAll)
                        .buttonStyle(ReminderQuietButtonStyle(palette: palette))
                    Spacer(minLength: 0)
                    Button("Complete", systemImage: "checkmark", action: onComplete)
                        .buttonStyle(ReminderPrimaryButtonStyle(palette: palette))
                }
            }
        }
        .modifier(ReminderPopoverSurface(palette: palette))
        .accessibilityElement(children: .contain)
    }
}

private struct ReminderPopoverHeader: View {
    let title: String
    let palette: ReminderPopoverPalette
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 38, height: 38)
                .background(palette.iconBackground, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("RESEARCH LATER")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(palette.muted)
                Text(title)
                    .font(.system(size: 23, weight: .regular, design: .serif))
                    .foregroundStyle(palette.ink)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .accessibilityLabel("Close reminder")
            .help("Close (Esc)")
            .keyboardShortcut(.cancelAction)
        }
    }
}

private struct ReminderSourceQuote: View {
    let text: String
    let palette: ReminderPopoverPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("FROM YOUR BOOK")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.3)
                .foregroundStyle(palette.muted)
            Text(text)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(palette.quoteInk)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 13)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(palette.quoteRule).frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReminderPopoverSurface: ViewModifier {
    let palette: ReminderPopoverPalette
    func body(content: Content) -> some View {
        content
            .padding(24)
            .frame(idealWidth: 400, maxWidth: 416)
            .fixedSize(horizontal: false, vertical: true)
            .background(palette.paper, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(palette.border.opacity(0.8)))
            .shadow(color: .black.opacity(palette.isDark ? 0.24 : 0.10), radius: 24, x: 0, y: 10)
            .shadow(color: .black.opacity(0.035), radius: 3, x: 0, y: 1)
    }
}

private struct ReminderPrimaryButtonStyle: ButtonStyle {
    let palette: ReminderPopoverPalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15)
            .frame(height: 36)
            .foregroundStyle(isEnabled ? palette.buttonInk : palette.muted)
            .background(isEnabled ? palette.accent : palette.iconBackground, in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(.rect(cornerRadius: 8))
    }
}

private struct ReminderQuietButtonStyle: ButtonStyle {
    let palette: ReminderPopoverPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? palette.ink : palette.muted)
            .padding(.vertical, 9)
            .contentShape(.rect)
    }
}

private struct ReminderPopoverPalette {
    let isDark: Bool
    var paper: Color { isDark ? color(0x252E28) : color(0xFBFCF7) }
    var field: Color { isDark ? color(0x1E2721) : .white }
    var ink: Color { isDark ? color(0xE9EEE9) : color(0x192A24) }
    var muted: Color { isDark ? color(0xAFBEB4) : color(0x67736A) }
    var accent: Color { isDark ? color(0xACD5B4) : color(0x245744) }
    var buttonInk: Color { isDark ? color(0x192A24) : .white }
    var border: Color { isDark ? color(0x455348) : color(0xDEE5DA) }
    var iconBackground: Color { isDark ? color(0x35483A) : color(0xE9EFE3) }
    var quoteInk: Color { isDark ? color(0xC5D0C5) : color(0x5D6B60) }
    var quoteRule: Color { isDark ? color(0x637E69) : color(0xBBCBB7) }
    var error: Color { isDark ? color(0xF4AC9E) : color(0xA53C2C) }

    private func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}
