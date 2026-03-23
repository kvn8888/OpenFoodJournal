// Macros — Food Journaling App
// AGPL-3.0 License
//
// WeeklyCalendarStrip — A horizontally scrollable week strip that snaps
// cleanly to week boundaries (Sun–Sat), inspired by the smooth momentum
// snapping of the iOS Calendar app.
//
//   • Horizontal continuous scroll through ~52 weeks of history
//   • Each "page" is one full week (Sun–Sat), always snaps to alignment
//   • scrollTargetLayout + scrollTargetBehavior(.viewAligned) for the snap
//   • Each day shows a progress ring based on calorie intake vs. goal
//   • Tapping a day selects it and updates the parent's selectedDate
//   • "Today" button to jump back to the current week
//
// Day cell states drive visual appearance:
//   1. Selected (active day) — bold text, filled background, progress ring
//   2. Past (default)        — secondary text, progress ring shows intake
//   3. Future                — dimmed text, no progress ring

import SwiftUI
import SwiftData

// MARK: - Day Cell State

/// Represents the visual state of a single day cell in the calendar.
/// For past days, includes the calorie progress fraction (0.0–1.0+) and a
/// color derived from how close the user got to their daily goal.
enum DayCellState {
    case selected(progress: Double)  // The currently active/selected day
    case past(progress: Double)      // A past day with logged data
    case future                      // A day in the future (no data yet)

    /// The progress-based ring color for past and selected days.
    /// Thresholds:
    ///   < 50%  → red (significantly under)
    ///   50–80% → yellow (under target)
    ///   80–95% → light green (getting close)
    ///   95–105% → green (goal matched ±5%)
    ///   105–120% → orange (slightly over)
    ///   > 120% → purple (significantly over)
    var ringColor: Color {
        let pct: Double
        switch self {
        case .selected(let p): pct = p
        case .past(let p):     pct = p
        case .future:          return .clear
        }

        switch pct {
        case ..<0.50:          return .red
        case 0.50..<0.80:     return .yellow
        case 0.80..<0.95:     return Color.green.opacity(0.6)
        case 0.95..<1.05:     return .green
        case 1.05..<1.20:     return .orange
        default:              return .purple
        }
    }

    /// The fraction (0.0–1.0) of the ring that should be filled.
    /// Capped at 1.0 so the ring never overflows visually.
    var progressFraction: Double {
        switch self {
        case .selected(let p): return min(p, 1.0)
        case .past(let p):     return min(p, 1.0)
        case .future:          return 0
        }
    }
}

// MARK: - Week Identifier

/// A Hashable/Identifiable value for each week in the horizontal scroll.
/// Stores the Sunday start date so we can generate all 7 days and use it
/// as a stable scroll anchor target.
private struct WeekID: Hashable, Identifiable {
    /// The Sunday that starts this week (start of day)
    let startDate: Date

    /// Stable identifier — timeIntervalSinceReferenceDate of the Sunday
    var id: TimeInterval { startDate.timeIntervalSinceReferenceDate }

    /// The 7 dates (Sun–Sat) in this week
    var dates: [Date] {
        (0..<7).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: startDate)
        }
    }
}

// MARK: - WeeklyCalendarStrip

/// Horizontally scrollable week strip with smooth snap-to-week behavior.
/// Pre-generates ~52 weeks of history so the user can freely scroll back
/// in time. Uses scrollTargetLayout + scrollTargetBehavior(.viewAligned)
/// for the iOS Calendar-style momentum snapping.
struct WeeklyCalendarStrip: View {
    /// The currently selected date — bound to the parent's state.
    @Binding var selectedDate: Date

    /// NutritionStore is used to look up whether past days have logged entries.
    @Environment(NutritionStore.self) private var nutritionStore

    /// UserGoals determines the calorie threshold for the "goal met" state.
    @Environment(UserGoals.self) private var goals

    /// Calendar used for all date math
    private let calendar = Calendar.current

    /// Number of weeks of history to make scrollable
    private let weeksOfHistory = 52

    /// Pre-computed array of WeekIDs from ~1 year ago to the current week.
    /// Each entry represents one Sunday–Saturday week.
    private var weeks: [WeekID] {
        // Find the Sunday that starts the current week
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date.now)?.start else {
            return []
        }
        // Generate weeksOfHistory weeks back + current week
        return (-weeksOfHistory...0).compactMap { offset in
            guard let sunday = calendar.date(byAdding: .weekOfYear, value: offset, to: currentWeekStart) else {
                return nil
            }
            return WeekID(startDate: calendar.startOfDay(for: sunday))
        }
    }

    /// The WeekID that contains the currently selected date
    private var selectedWeekID: WeekID? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return nil
        }
        return WeekID(startDate: calendar.startOfDay(for: interval.start))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header: month/year label + Today button ──
            calendarHeader

            // ── Day-of-week labels (S M T W T F S) ──
            dayOfWeekLabels

            // ── Horizontally scrollable weeks ──
            weekScroller
        }
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    // MARK: - Header

    /// Shows the month/year for the selected date, plus a "Today" button
    /// when the user has scrolled away from the current day.
    private var calendarHeader: some View {
        HStack {
            Text(selectedDate.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            // Today button — only visible when not on today's date
            if !calendar.isDateInToday(selectedDate) {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        selectedDate = .now
                    }
                } label: {
                    Text("Today")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Day-of-Week Labels

    /// Fixed row of single-letter weekday headers (S M T W T F S)
    private var dayOfWeekLabels: some View {
        HStack(spacing: 0) {
            ForEach(Calendar.current.veryShortWeekdaySymbols, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Week Scroller

    /// The horizontal ScrollView containing all weeks.
    /// scrollTargetLayout marks each week HStack as a snap target,
    /// and scrollTargetBehavior(.viewAligned) makes the scroll decelerate
    /// to the nearest week boundary — this is the iOS Calendar-style snap.
    private var weekScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(weeks) { week in
                        // One full week row (Sun–Sat)
                        weekRow(for: week)
                            .containerRelativeFrame(.horizontal)
                            .id(week.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                // Start scrolled to the week containing the selected date
                if let target = selectedWeekID {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
            .onChange(of: selectedDate) { _, newDate in
                // When selectedDate changes (e.g. "Today" button), scroll to that week
                if let target = weekIDForDate(newDate) {
                    withAnimation(.spring(duration: 0.3)) {
                        proxy.scrollTo(target.id, anchor: .center)
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Week Row

    /// Renders 7 day cells in a horizontal row for one week.
    private func weekRow(for week: WeekID) -> some View {
        HStack(spacing: 0) {
            ForEach(week.dates, id: \.self) { date in
                DayCellView(
                    date: date,
                    state: cellState(for: date)
                )
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    if date <= Date.now || calendar.isDateInToday(date) {
                        withAnimation(.spring(duration: 0.3)) {
                            selectedDate = date
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    /// Finds the WeekID that contains a given date
    private func weekIDForDate(_ date: Date) -> WeekID? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return nil
        }
        return WeekID(startDate: calendar.startOfDay(for: interval.start))
    }

    /// Determines the visual state for a given date.
    /// Computes calorie progress as a fraction of the daily goal.
    private func cellState(for date: Date) -> DayCellState {
        let startOfDate = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: .now)

        // Future days get the dimmed state
        if startOfDate > today {
            return .future
        }

        // Calculate calorie progress for this day
        let progress: Double
        if let log = nutritionStore.fetchLog(for: date), goals.dailyCalories > 0 {
            let totalCalories = log.entries.reduce(0.0) { $0 + $1.calories }
            progress = totalCalories / goals.dailyCalories
        } else {
            progress = 0
        }

        let startOfSelected = calendar.startOfDay(for: selectedDate)
        if startOfDate == startOfSelected {
            return .selected(progress: progress)
        }

        return .past(progress: progress)
    }
}

// MARK: - DayCellView

/// A single day cell showing a day abbreviation and a date number inside
/// a progress ring. Used in the week strip rows.
private struct DayCellView: View {
    let date: Date
    let state: DayCellState

    /// 3-letter day abbreviation (e.g. "Mon", "Tue")
    private var dayAbbreviation: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Day-of-month number (e.g. "13", "7")
    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    /// Whether this is the selected day (affects text weight and background)
    private var isSelected: Bool {
        if case .selected = state { return true }
        return false
    }

    /// Ring/circle size
    private let circleSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            // Day abbreviation (e.g. "Mon")
            Text(dayAbbreviation)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(dayTextColor)

            // Date number inside a progress ring
            ZStack {
                // Background track (hidden for future days)
                if case .future = state {
                    // No ring for future days
                } else {
                    Circle()
                        .stroke(.secondary.opacity(0.15), lineWidth: 2.5)
                }

                // Progress ring — fills clockwise from top
                Circle()
                    .trim(from: 0, to: state.progressFraction)
                    .stroke(
                        state.ringColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Filled background for selected day
                if isSelected {
                    Circle()
                        .fill(.regularMaterial)
                        .padding(2)
                }

                // The date number text
                Text(dayNumber)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .bold : .semibold)
                    .foregroundStyle(dateTextColor)
            }
            .frame(width: circleSize, height: circleSize)
        }
        .padding(.vertical, 4)
    }

    // MARK: - State-Driven Styling

    private var dayTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .past:         return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }

    private var dateTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .past:         return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }
}

// MARK: - Preview

/// A simple wrapper view that provides the required environment objects for previewing.
private struct CalendarStripPreview: View {
    @State private var date = Date.now

    var body: some View {
        WeeklyCalendarStrip(selectedDate: $date)
            .padding()
            .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
            .environment(UserGoals())
    }
}

#Preview {
    CalendarStripPreview()
        .modelContainer(.preview)
}
