import EpubKit
import ReaderUI
import SwiftUI

struct TableOfContentsView: View {
    let document: ReaderDocument
    let reader: ReaderController
    /// Called after the user jumps to an entry so the host can dismiss a popover.
    var onSelect: (() -> Void)? = nil

    @State private var query = ""

    var body: some View {
        Group {
            if document.outline.isEmpty {
                ContentUnavailableView(
                    "No Contents",
                    systemImage: "list.bullet.indent",
                    description: Text("This document does not include a table of contents.")
                )
            } else {
                List {
                    if filtered.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    } else {
                        outline
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $query, placement: .automatic, prompt: "Search contents")
        .navigationTitle("Contents")
    }

    @ViewBuilder
    private var outline: some View {
        // A flat search result list is easier to scan than a filtered tree.
        if query.isEmpty {
            ForEach(document.outline) { entry in
                TOCRow(entry: entry, reader: reader, onSelect: jump)
            }
        } else {
            ForEach(filtered) { entry in
                Button { jump(entry) } label: {
                    Text(entry.title).lineLimit(2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func jump(_ entry: DocumentOutlineEntry) {
        guard let destination = entry.destination else { return }
        reader.go(to: destination)
        onSelect?()
    }

    private var filtered: [DocumentOutlineEntry] {
        guard !query.isEmpty else { return document.outline }
        return document.outline
            .flatMap(\.flattened)
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

private struct TOCRow: View {
    let entry: DocumentOutlineEntry
    let reader: ReaderController
    let onSelect: (DocumentOutlineEntry) -> Void

    var body: some View {
        if entry.children.isEmpty {
            row
        } else {
            DisclosureGroup {
                ForEach(entry.children) { child in
                    TOCRow(entry: child, reader: reader, onSelect: onSelect)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        Button {
            onSelect(entry)
        } label: {
            Text(entry.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(entry.destination == nil ? .secondary : .primary)
        .disabled(entry.destination == nil)
    }
}
