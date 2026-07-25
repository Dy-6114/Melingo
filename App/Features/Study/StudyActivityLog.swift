import Foundation
import Domain
import SwiftUI

/// Append-only study/reading activity for hours-first statistics.
/// Stored in UserDefaults; reading also still writes ReadingSession.
enum StudyActivityLog {
    private static let key = "study.activityLog.v1"
    private static let maxEvents = 4_000
    /// Floor so short legitimate visits still land (soft day needs cumulative ≥2 min).
    private static let minRecordSeconds = 1

    struct Event: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        /// `StudyDestination.rawValue` or `"reading"`.
        var mode: String
        var startedAt: Date
        var seconds: Int
        var itemsCompleted: Int
        var itemsCorrect: Int

        var dateLocal: String {
            LocalCalendarDate.string(from: startedAt)
        }
    }

    struct Snapshot: Sendable {
        var events: [Event]
        var secondsToday: Int
        var secondsWeek: Int
        var secondsAll: Int
        var longestSessionSeconds: Int
        var longestSessionTodaySeconds: Int
        var softShowUpDays: Int
        var softShowUpStreak: Int
        var microSessions: Int
        var deepSessions: Int
        var modeSeconds: [(mode: String, seconds: Int)]
        var daypartSeconds: (morning: Int, afternoon: Int, evening: Int, night: Int)
        var modeSwitchesWeek: Int
        var averageSessionSeconds: Int
        var sessionCountWeek: Int
        var readingSecondsWeek: Int
        var drillSecondsWeek: Int
        var hasAnyActivity: Bool { secondsAll > 0 || !events.isEmpty }
    }

    @discardableResult
    static func record(
        mode: String,
        seconds: Int,
        startedAt: Date = .now,
        itemsCompleted: Int = 0,
        itemsCorrect: Int = 0
    ) -> Bool {
        guard seconds >= minRecordSeconds else { return false }
        var events = load()
        events.append(
            Event(
                id: UUID(),
                mode: mode,
                startedAt: startedAt,
                seconds: seconds,
                itemsCompleted: itemsCompleted,
                itemsCorrect: itemsCorrect
            )
        )
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
        save(events)
        #if DEBUG
        print("[StudyActivityLog] +\(seconds)s mode=\(mode)")
        #endif
        return true
    }

    static func load() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Event].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ events: [Event]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // Ensure disk flush if app is killed right after background.
        UserDefaults.standard.synchronize()
    }

    static func snapshot(now: Date = .now) -> Snapshot {
        let events = load()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        let today = events.filter { $0.startedAt >= todayStart }
        let week = events.filter { $0.startedAt >= weekStart }

        let secondsToday = today.reduce(0) { $0 + $1.seconds }
        let secondsWeek = week.reduce(0) { $0 + $1.seconds }
        let secondsAll = events.reduce(0) { $0 + $1.seconds }

        let longestAll = events.map(\.seconds).max() ?? 0
        let longestToday = today.map(\.seconds).max() ?? 0

        // Soft presence: any day with ≥2 minutes on language screens.
        let daySeconds: [String: Int] = Dictionary(grouping: events, by: \.dateLocal)
            .mapValues { $0.reduce(0) { $0 + $1.seconds } }
        let softDays = daySeconds.filter { $0.value >= 120 }.map(\.key).sorted()
        let softShowUpDays = softDays.count
        let softShowUpStreak = softStreak(days: Set(softDays), from: todayStart, calendar: cal)

        let micro = week.filter { $0.seconds < 5 * 60 }.count
        let deep = week.filter { $0.seconds >= 20 * 60 }.count

        var modeMap: [String: Int] = [:]
        for e in week {
            modeMap[e.mode, default: 0] += e.seconds
        }
        let modeSeconds = modeMap
            .map { (mode: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        var morning = 0, afternoon = 0, evening = 0, night = 0
        for e in week {
            let hour = cal.component(.hour, from: e.startedAt)
            switch hour {
            case 5..<12: morning += e.seconds
            case 12..<17: afternoon += e.seconds
            case 17..<22: evening += e.seconds
            default: night += e.seconds
            }
        }

        let switches = modeSwitchCount(in: week)
        let avg = week.isEmpty ? 0 : secondsWeek / week.count
        let reading = week.filter { $0.mode == "reading" }.reduce(0) { $0 + $1.seconds }
        let drills = max(0, secondsWeek - reading)

        return Snapshot(
            events: events,
            secondsToday: secondsToday,
            secondsWeek: secondsWeek,
            secondsAll: secondsAll,
            longestSessionSeconds: longestAll,
            longestSessionTodaySeconds: longestToday,
            softShowUpDays: softShowUpDays,
            softShowUpStreak: softShowUpStreak,
            microSessions: micro,
            deepSessions: deep,
            modeSeconds: modeSeconds,
            daypartSeconds: (morning, afternoon, evening, night),
            modeSwitchesWeek: switches,
            averageSessionSeconds: avg,
            sessionCountWeek: week.count,
            readingSecondsWeek: reading,
            drillSecondsWeek: drills
        )
    }

    private static func softStreak(days: Set<String>, from todayStart: Date, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        var day = todayStart
        let todayKey = LocalCalendarDate.string(from: day)
        if !days.contains(todayKey) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            if !days.contains(LocalCalendarDate.string(from: day)) { return 0 }
        }
        var streak = 0
        while days.contains(LocalCalendarDate.string(from: day)) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    private static func modeSwitchCount(in events: [Event]) -> Int {
        let ordered = events.sorted { $0.startedAt < $1.startedAt }
        guard ordered.count >= 2 else { return 0 }
        var switches = 0
        for i in 1..<ordered.count {
            if ordered[i].mode != ordered[i - 1].mode { switches += 1 }
        }
        return switches
    }
}

// MARK: - View modifier

/// Tracks wall-clock time while a Study destination is on screen.
/// Flushes on disappear, scene background/inactive, and every ~60s — not only on clean dismiss.
struct TrackStudyActivityModifier: ViewModifier {
    let mode: String
    @Environment(\.scenePhase) private var scenePhase
    /// Set synchronously in `onAppear` — never rely on a later async tick.
    @State private var startedAt: Date?
    @State private var isTracking = false

    func body(content: Content) -> some View {
        content
            .onAppear { beginTracking() }
            .onDisappear { flush(restart: false) }
            .onChange(of: mode) { _, _ in
                flush(restart: true)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    // App resign / hide — onDisappear often never runs.
                    flush(restart: true)
                case .active:
                    beginTracking()
                @unknown default:
                    break
                }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                guard isTracking, scenePhase == .active else { return }
                flush(restart: true)
            }
    }

    private func beginTracking() {
        if startedAt == nil {
            startedAt = Date()
        }
        isTracking = true
    }

    private func flush(restart: Bool) {
        guard let start = startedAt else {
            if restart { startedAt = Date(); isTracking = true }
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds >= 1 {
            StudyActivityLog.record(mode: mode, seconds: seconds, startedAt: start)
        }
        if restart {
            startedAt = Date()
            isTracking = true
        } else {
            startedAt = nil
            isTracking = false
        }
    }
}

extension View {
    func trackStudyActivity(mode: String) -> some View {
        modifier(TrackStudyActivityModifier(mode: mode))
    }

    func trackStudyActivity(_ destination: StudyDestination) -> some View {
        trackStudyActivity(mode: destination.rawValue)
    }
}
