import Foundation
import Observation

/// Personal reading history is local product data, independent of usage analytics.
@MainActor
@Observable
final class ReadingProgress {
    static let minimumGoalMinutes = 5
    static let maximumGoalMinutes = 1_440
    static let idleTimeout: TimeInterval = 300

    private(set) var goalMinutes = 5
    private(set) var todaySeconds: TimeInterval = 0
    private(set) var isTodayComplete = false
    private(set) var currentStreak = 0
    private(set) var storageError: String?

    private struct Day: Codable {
        var seconds: TimeInterval = 0
        var targetMinutes: Int
        var earned = false
    }

    private struct History: Codable {
        var version = 1
        var goalMinutes = 5
        var days: [String: Day] = [:]
    }

    @ObservationIgnored private var history: History
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let date: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let startTimer: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var dayObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var readerEligible = false
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var lastUptime: TimeInterval
    @ObservationIgnored private var lastDate: Date
    @ObservationIgnored private var lastInteraction: TimeInterval
    @ObservationIgnored private var lastSaveUptime: TimeInterval
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var canWrite = true

    init(directory: URL, startTimer: Bool = true,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = {
             var value = Calendar(identifier: .gregorian)
             value.timeZone = .autoupdatingCurrent
             return value
         }) {
        fileURL = directory.appendingPathComponent("reading-progress.json")
        self.uptime = uptime
        self.date = date
        self.calendar = calendar
        self.startTimer = startTimer
        let now = uptime()
        lastUptime = now
        lastInteraction = now
        lastSaveUptime = now
        lastDate = date()
        history = History()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let loaded = try JSONDecoder().decode(History.self, from: Data(contentsOf: fileURL))
                guard loaded.version == 1,
                      Self.validGoal(loaded.goalMinutes),
                      loaded.days.values.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 && Self.validGoal($0.targetMinutes) }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                history = loaded
            } catch {
                // Keep unreadable or newer history intact rather than replacing it.
                canWrite = false
                storageError = "Reading history could not be loaded. Your saved file has been kept. New progress cannot be saved until it can be read again."
            }
        }
        goalMinutes = history.goalMinutes
        refreshToday(at: lastDate)

        if startTimer {
            for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
                dayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkpoint() }
                })
            }
        }
    }

    deinit {
        timer?.invalidate()
        dayObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Invalid input never silently changes the user's goal.
    @discardableResult
    func setGoal(minutes: Int) -> Bool {
        guard Self.validGoal(minutes) else { return false }
        advance()
        goalMinutes = minutes
        history.goalMinutes = minutes
        let key = dayKey(date())
        var today = history.days[key] ?? Day(targetMinutes: minutes)
        today.targetMinutes = minutes
        today.earned = today.earned || today.seconds >= Double(minutes * 60)
        history.days[key] = today
        dirty = true
        refreshToday(at: date())
        save()
        updateTimer()
        return true
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        transition { isActive = active }
    }

    func setReaderEligible(_ eligible: Bool) {
        guard eligible != readerEligible else { return }
        transition { readerEligible = eligible }
    }

    func setReadingWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        transition { windowVisible = visible }
    }

    func setSleeping(_ value: Bool) {
        guard value != sleeping else { return }
        transition { sleeping = value }
    }

    /// Called only for input in the main reader window, never Settings input.
    func recordInteraction() {
        guard isTracking else { return }
        // First close the old interval, excluding any time beyond its idle cutoff.
        advance()
        lastInteraction = uptime()
        updateTimer()
    }

    func tick() {
        advance()
        if dirty && uptime() - lastSaveUptime >= 15 { save() }
        updateTimer()
    }

    /// Synchronous atomic writes also make quit/update checkpoints durable.
    func checkpoint() {
        advance()
        save()
        updateTimer()
    }

    private static func validGoal(_ minutes: Int) -> Bool {
        (minimumGoalMinutes...maximumGoalMinutes).contains(minutes)
    }

    private var isTracking: Bool { isActive && readerEligible && windowVisible && !sleeping }

    private func transition(_ change: () -> Void) {
        let wasTracking = isTracking
        checkpoint()
        change()
        if isTracking && !wasTracking { lastInteraction = uptime() }
        updateTimer()
    }

    private func advance() {
        let now = uptime()
        let wallNow = date()
        let elapsed = now - lastUptime
        if isTracking, elapsed > 0 {
            let duration = max(0, min(now, lastInteraction + Self.idleTimeout) - lastUptime)
            if duration > 0 {
                // A wall-clock adjustment changes date attribution, never duration.
                let wallElapsed = wallNow.timeIntervalSince(lastDate)
                let start = abs(wallElapsed - elapsed) <= 2 ? lastDate : wallNow.addingTimeInterval(-elapsed)
                addTime(duration, startingAt: start)
            }
        }
        lastUptime = now
        lastDate = wallNow
        refreshToday(at: wallNow)
        // The idle timer stops here, so persist its final partial save interval.
        if isTracking && now >= lastInteraction + Self.idleTimeout { save() }
    }

    private func addTime(_ duration: TimeInterval, startingAt start: Date) {
        let cal = calendar()
        var cursor = start
        var remaining = duration
        var earnedDay = false
        while remaining > 0 {
            guard let interval = cal.dateInterval(of: .day, for: cursor) else { break }
            let seconds = min(remaining, interval.end.timeIntervalSince(cursor))
            guard seconds > 0 else { break }
            let key = dayKey(cursor)
            var day = history.days[key] ?? Day(targetMinutes: goalMinutes)
            day.seconds += seconds
            if !day.earned && day.seconds >= Double(day.targetMinutes * 60) {
                day.earned = true
                earnedDay = true
            }
            history.days[key] = day
            dirty = true
            remaining -= seconds
            cursor = interval.end
        }
        if earnedDay { save() }
    }

    private func refreshToday(at now: Date) {
        let today = history.days[dayKey(now)]
        todaySeconds = today?.seconds ?? 0
        isTodayComplete = today?.earned ?? false

        let cal = calendar()
        var cursor = cal.startOfDay(for: now)
        if !isTodayComplete {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) else {
                currentStreak = 0
                return
            }
            cursor = yesterday
        }
        var streak = 0
        while history.days[dayKey(cursor)]?.earned == true {
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        currentStreak = streak
    }

    private func dayKey(_ value: Date) -> String {
        let components = calendar().dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func save() {
        guard dirty, canWrite else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(history).write(to: fileURL, options: .atomic)
            dirty = false
            lastSaveUptime = uptime()
            storageError = nil
        } catch {
            storageError = "Reading progress could not be saved. Kodi will try again."
        }
    }

    private func updateTimer() {
        guard startTimer, isTracking, uptime() < lastInteraction + Self.idleTimeout else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
