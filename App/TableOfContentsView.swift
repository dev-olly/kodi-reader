import EpubKit
import ReaderUI
import SwiftUI

struct TableOfContentsView: View {
    let book: EPUBBook
    let reader: ReaderController
    /// Called after the user jumps to an entry so the host can dismiss a popover.
    var onSelect: (() -> Void)? = nil

    @State private var query = ""

    var body: some View {
        Group {
            if book.publication.toc.isEmpty {
                ContentUnavailableView(
                    "No Contents",
                    systemImage: "list.bullet.indent",
                    description: Text("This book does not include a table of contents.")
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
            ForEach(book.publication.toc) { entry in
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

    private func jump(_ entry: TOCEntry) {
        guard !entry.path.isEmpty else { return }
        reader.go(to: entry)
        onSelect?()
    }

    private var filtered: [TOCEntry] {
        guard !query.isEmpty else { return book.publication.toc }
        return book.publication.toc
            .flatMap(\.flattened)
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

private struct TOCRow: View {
    let entry: TOCEntry
    let reader: ReaderController
    let onSelect: (TOCEntry) -> Void

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
        .foregroundStyle(entry.path.isEmpty ? .secondary : .primary)
        .disabled(entry.path.isEmpty)
    }
}
