import Foundation
import UserNotifications

/// Local soft daily nudges. Opt-in from the review done screen or Settings.
@MainActor
enum ReviewReminderService {
    private static let legacyRequestID = "melingo.daily.review"
    private static let requestIDPrefix = "melingo.daily.review."
    private static let horizonDays = 14
    private static let enabledKey = "review.reminders.enabled"
    private static let hour = 9
    private static let minute = 0

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var pendingIDs: [String] {
        (0..<horizonDays).map { "\(requestIDPrefix)\($0)" } + [legacyRequestID]
    }

    /// Requests notification permission and schedules soft local reminders around 9:00.
    @discardableResult
    static func enable(dueCountHint: Int = 0) async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                isEnabled = false
                return false
            }
        } catch {
            isEnabled = false
            return false
        }
        isEnabled = true
        await reschedule(dueCountHint: dueCountHint)
        return true
    }

    static func disable() async {
        isEnabled = false
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    /// Schedules the next two weeks of one-shot 9:00 notifications with rotating soft copy.
    /// Call again after locale changes or when the app becomes active.
    static func reschedule(dueCountHint: Int = 0) async {
        _ = dueCountHint // kept for call-site compatibility; soft voice omits counts
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

        let cal = Calendar.current
        let now = Date()
        guard let todayStart = cal.dateInterval(of: .day, for: now)?.start else { return }

        for offset in 0..<horizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let fire = cal.date(from: comps), fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = AppL10n.t("review.reminder.title")
            content.body = AppL10n.softReminderBody(dayOffset: offset)
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(requestIDPrefix)\(offset)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
