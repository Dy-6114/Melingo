import SwiftUI
import Domain

/// Soft ADHD-niche study stats: hours with language first; empty states without shame zeros.
struct StatsView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var snap = StudyActivityLog.snapshot()

    private var hasTime: Bool { snap.secondsAll > 0 || snap.secondsToday > 0 || snap.secondsWeek > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hoursHero
                softShowUp
                focusIslands
                modeFuel
                dayparts
                microDeep
                switchAttention
                srsPulse
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
        .navigationTitle(AppL10n.t("sidebar.stats"))
        .toolbarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        snap = StudyActivityLog.snapshot()
    }

    // MARK: - Hours with language

    private var hoursHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppL10n.t("stats.hours.title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)

            if hasTime {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hoursString(snap.secondsToday))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.foreground)
                        .monospacedDigit()
                    Text(AppL10n.t("stats.hours.unit"))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(theme.mutedForeground)
                    Text(AppL10n.t("stats.hours.today"))
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                }

                HStack(spacing: 20) {
                    hoursChip(label: AppL10n.t("stats.hours.week"), value: hoursString(snap.secondsWeek))
                    hoursChip(label: AppL10n.t("stats.hours.all"), value: hoursString(snap.secondsAll))
                }
            } else {
                Text(AppL10n.t("stats.hours.empty"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(AppL10n.t("stats.hours.blurb"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.28), lineWidth: 1.5)
        }
    }

    private func hoursChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.foreground)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
        }
    }

    // MARK: - Days you came

    private var softShowUp: some View {
        sectionCard(title: AppL10n.t("stats.soft.title"), blurb: AppL10n.t("stats.soft.blurb")) {
            if snap.softShowUpDays == 0 && !hasTime {
                Text(AppL10n.t("stats.soft.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    WorkspaceChrome.StatCard(
                        title: AppL10n.t("stats.soft.days"),
                        value: "\(snap.softShowUpDays)",
                        systemImage: "calendar"
                    )
                    WorkspaceChrome.StatCard(
                        title: AppL10n.t("stats.hours.today"),
                        value: hoursString(snap.secondsToday),
                        systemImage: "clock"
                    )
                    WorkspaceChrome.StatCard(
                        title: AppL10n.t("stats.hours.week"),
                        value: hoursString(snap.secondsWeek),
                        systemImage: "chart.bar"
                    )
                }
            }
        }
    }

    // MARK: - Immersions

    private var focusIslands: some View {
        sectionCard(title: AppL10n.t("stats.focus.title"), blurb: AppL10n.t("stats.focus.blurb")) {
            if snap.longestSessionSeconds == 0 && snap.longestSessionTodaySeconds == 0 {
                Text(AppL10n.t("stats.focus.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 24) {
                    bigMetric(minutesString(snap.longestSessionTodaySeconds), AppL10n.t("stats.focus.today"))
                    bigMetric(minutesString(snap.longestSessionSeconds), AppL10n.t("stats.focus.best"))
                    bigMetric(minutesString(snap.averageSessionSeconds), AppL10n.t("stats.focus.avg"))
                }
            }
        }
    }

    // MARK: - Where attention went

    private var modeFuel: some View {
        sectionCard(title: AppL10n.t("stats.fuel.title"), blurb: AppL10n.t("stats.fuel.blurb")) {
            if snap.modeSeconds.isEmpty || snap.secondsWeek == 0 {
                Text(AppL10n.t("stats.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snap.modeSeconds, id: \.mode) { row in
                        modeBar(
                            name: modeLabel(row.mode),
                            seconds: row.seconds,
                            total: snap.secondsWeek
                        )
                    }
                    HStack(spacing: 16) {
                        Text(String(format: AppL10n.t("stats.fuel.reading"), hoursString(snap.readingSecondsWeek)))
                        Text(String(format: AppL10n.t("stats.fuel.drills"), hoursString(snap.drillSecondsWeek)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func modeBar(name: String, seconds: Int, total: Int) -> some View {
        let safeTotal = max(total, 1)
        let frac = total == 0 ? 0 : min(1, Double(seconds) / Double(safeTotal))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Text(hoursString(seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.muted.opacity(0.55))
                    if frac > 0, frac.isFinite {
                        Capsule()
                            .fill(theme.primary.opacity(0.75))
                            .frame(width: max(4, geo.size.width * frac))
                    }
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Clarity hours

    private var dayparts: some View {
        let d = snap.daypartSeconds
        let rawTotal = d.morning + d.afternoon + d.evening + d.night
        return sectionCard(title: AppL10n.t("stats.daypart.title"), blurb: AppL10n.t("stats.daypart.blurb")) {
            if rawTotal == 0 {
                Text(AppL10n.t("stats.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    daypartCol(AppL10n.t("stats.daypart.morning"), d.morning, rawTotal)
                    daypartCol(AppL10n.t("stats.daypart.afternoon"), d.afternoon, rawTotal)
                    daypartCol(AppL10n.t("stats.daypart.evening"), d.evening, rawTotal)
                    daypartCol(AppL10n.t("stats.daypart.night"), d.night, rawTotal)
                }
                .frame(height: 120)
            }
        }
    }

    private func daypartCol(_ label: String, _ seconds: Int, _ total: Int) -> some View {
        // Never divide by zero — empty bins stay empty (no NaN → full bar).
        let frac: CGFloat = {
            guard total > 0, seconds > 0 else { return 0 }
            let f = Double(seconds) / Double(total)
            guard f.isFinite else { return 0 }
            return CGFloat(min(1, max(0, f)))
        }()
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(frac > 0 ? theme.primary.opacity(0.7) : theme.muted.opacity(0.35))
                .frame(height: frac > 0 ? max(4, 72 * frac) : 4)
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Short breaths / long exhales

    private var microDeep: some View {
        sectionCard(title: AppL10n.t("stats.depth.title"), blurb: AppL10n.t("stats.depth.blurb")) {
            if snap.sessionCountWeek == 0 {
                Text(AppL10n.t("stats.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                HStack(spacing: 24) {
                    bigMetric("\(snap.microSessions)", AppL10n.t("stats.depth.micro"))
                    bigMetric("\(snap.deepSessions)", AppL10n.t("stats.depth.deep"))
                    bigMetric("\(snap.sessionCountWeek)", AppL10n.t("stats.depth.sessions"))
                }
            }
        }
    }

    // MARK: - Attention switches

    private var switchAttention: some View {
        let perHour = snap.secondsWeek > 0
            ? Double(snap.modeSwitchesWeek) / (Double(snap.secondsWeek) / 3600.0)
            : 0
        return sectionCard(title: AppL10n.t("stats.switch.title"), blurb: AppL10n.t("stats.switch.blurb")) {
            if snap.sessionCountWeek == 0 {
                Text(AppL10n.t("stats.empty"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                HStack(spacing: 24) {
                    bigMetric("\(snap.modeSwitchesWeek)", AppL10n.t("stats.switch.count"))
                    bigMetric(String(format: "%.1f", perHour.isFinite ? perHour : 0), AppL10n.t("stats.switch.perHour"))
                }
            }
        }
    }

    // MARK: - Review rhythm

    private var srsPulse: some View {
        sectionCard(title: AppL10n.t("stats.srs.title"), blurb: AppL10n.t("stats.srs.blurb")) {
            HStack(spacing: 24) {
                bigMetric("\(store.reviewedTodayCount)", AppL10n.t("stats.srs.today"))
                bigMetric("\(store.dueCount)", AppL10n.t("stats.srs.due"))
                bigMetric("\(store.studyStreakDays)", AppL10n.t("stats.srs.streak"))
                bigMetric(
                    "\(StudyLearnerPrefs.productionPassesLast7Days())",
                    AppL10n.t("stats.srs.production")
                )
                bigMetric(
                    "\(StudyLearnerPrefs.uniqueProductionCardsLast7Days())",
                    AppL10n.t("stats.srs.prodCards")
                )
            }
        }
    }

    // MARK: - Chrome

    private func sectionCard<Content: View>(
        title: String,
        blurb: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.foreground)
            Text(blurb)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
        }
    }

    private func bigMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.foreground)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hoursString(_ seconds: Int) -> String {
        guard seconds >= 60 else {
            if seconds <= 0 { return "0" }
            return String(format: AppL10n.t("stats.minutesShort"), 1)
        }
        let h = Double(seconds) / 3600.0
        if h < 0.05 {
            return String(format: AppL10n.t("stats.minutesShort"), max(1, seconds / 60))
        }
        if h < 10 { return String(format: "%.1f", h) }
        return String(format: "%.0f", h)
    }

    private func minutesString(_ seconds: Int) -> String {
        let m = max(0, (seconds + 30) / 60)
        return String(format: AppL10n.t("stats.minutesShort"), m)
    }

    private func modeLabel(_ raw: String) -> String {
        if raw == "reading" { return AppL10n.t("stats.mode.reading") }
        if let dest = StudyDestination(rawValue: raw) { return dest.localizedTitle }
        return raw
    }
}
