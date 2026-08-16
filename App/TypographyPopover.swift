import ReaderUI
import SwiftUI

/// Text and appearance controls. Every change flows straight through to the
/// reader, which repaginates around the current position.
struct TypographyPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            themes

            Divider()

            LabeledContent("Font") {
                Picker("", selection: $model.settings.font) {
                    ForEach(ReaderFont.allCases) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            stepperRow(
                title: "Text Size",
                value: $model.settings.fontSize,
                range: ReaderSettings.fontSizeRange,
                step: 1,
                format: { "\(Int($0))pt" }
            )

            stepperRow(
                title: "Line Spacing",
                value: $model.settings.lineHeight,
                range: ReaderSettings.lineHeightRange,
                step: 0.1,
                format: { String(format: "%.1f", $0) }
            )

            stepperRow(
                title: "Margins",
                value: $model.settings.marginRatio,
                range: ReaderSettings.marginRange,
                step: 0.01,
                format: { "\(Int($0 * 100))%" }
            )

            Divider()

            Toggle("Justify Text", isOn: $model.settings.justified)
            Toggle("Hyphenation", isOn: $model.settings.hyphenated)
            Toggle("Two Pages When Wide", isOn: $model.settings.twoPageSpread)
            Toggle("Animate Page Turns", isOn: $model.settings.animatePageTurns)
            Toggle(
                "Notes in Sidebar",
                isOn: Binding(
                    get: { model.notesInSidebar },
                    set: { model.notesInSidebar = $0 }
                )
            )
        }
        .padding(20)
        .frame(width: 320)
    }

    private var themes: some View {
        HStack(spacing: 10) {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    model.settings.theme = theme
                } label: {
                    Text("Aa")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.uiForeground)
                        .frame(width: 54, height: 44)
                        .background(theme.uiBackground, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    model.settings.theme == theme ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: model.settings.theme == theme ? 2.5 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .help(theme.displayName)
            }
        }
    }

    private func stepperRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
        }
    }
}
