import Foundation

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case title
    case dateAdded
    case dateRead

    public var id: Self { self }

    public var title: String {
        switch self {
        case .title: return "Title"
        case .dateAdded: return "Date added"
        case .dateRead: return "Date last read"
        }
    }
}

public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case recentlyRead
    case inProgress
    case unread
    case finished

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: return "All books"
        case .recentlyRead: return "Recently read"
        case .inProgress: return "In progress"
        case .unread: return "Unread"
        case .finished: return "Finished"
        }
    }
}

/// A library view's search, reading-status filter, and display order.
public struct LibraryQuery: Sendable {
    public var searchText: String
    public var sort: LibrarySort
    public var ascending: Bool
    public var filter: LibraryFilter

    public init(
        searchText: String = "",
        sort: LibrarySort = .dateRead,
        ascending: Bool = false,
        filter: LibraryFilter = .all
    ) {
        self.searchText = searchText
        self.sort = sort
        self.ascending = ascending
        self.filter = filter
    }

    public func apply(
        to books: [BookRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BookRecord] {
        let tokens = searchText.split(whereSeparator: \.isWhitespace).map {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        // Calendar arithmetic preserves a seven-day window across clock changes.
        let recentCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        return books.filter { book in
            guard matchesFilter(book, recentCutoff: recentCutoff, now: now) else { return false }
            guard !tokens.isEmpty else { return true }
            let searchable = (book.title + "\n" + book.author)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return tokens.allSatisfy { searchable.contains($0) }
        }.sorted(by: precedes)
    }

    private func matchesFilter(_ book: BookRecord, recentCutoff: Date, now: Date) -> Bool {
        switch filter {
        case .all:
            return true
        case .recentlyRead:
            return book.progress > 0.001
                && book.lastOpenedAt >= recentCutoff
                && book.lastOpenedAt <= now
        case .inProgress:
            return book.progress > 0.001 && book.progress < 0.99
        case .unread:
            return book.progress <= 0.001
        case .finished:
            return book.progress >= 0.99
        }
    }

    private func precedes(_ lhs: BookRecord, _ rhs: BookRecord) -> Bool {
        switch sort {
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame {
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        case .dateAdded:
            switch (lhs.addedAt, rhs.addedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
        case .dateRead:
            if lhs.lastOpenedAt != rhs.lastOpenedAt {
                return ascending ? lhs.lastOpenedAt < rhs.lastOpenedAt : lhs.lastOpenedAt > rhs.lastOpenedAt
            }
        }
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}
