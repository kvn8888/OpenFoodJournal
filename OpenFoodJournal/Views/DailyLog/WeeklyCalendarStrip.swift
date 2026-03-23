// Macros — Food Journaling App
// AGPL-3.0 License
//
// WeeklyCalendarStrip — A continuously scrollable monthly calendar
// modeled after iOS Calendar's monthly view:
//   • Vertical continuous scroll with smooth snapping to month boundaries
//   • Sticky month/year headers that transition as you scroll
//   • Each day shows a progress ring based on calorie intake vs. goal
//   • Tapping a day selects it and updates the parent's selectedDate
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

// MARK: - Month Identifier

/// Hashable identifier for a calendar month, used as scroll anchor targets.
/// Stores year and month so we can generate dates and create stable IDs.
private struct MonthID: Hashable, Identifiable {
    let year: Int
    let month: Int

    var id: Int { year * 100 + month }

    /// Human-readable month/year label (e.g. "March 2026")
    var label: String {
        let components = DateComponents(year: year, month: month, day: 1)
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// All dates in this month
    var dates: [Date] {
        let calendar = Calendar.current
        let components = DateComponents(year: year, month: month, day: 1)
        guard let firstDay = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstDay) else { return [] }
        return range.compactMap { day in
            calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
    }

    /// The weekday index (0 = Sunday) of the first day of this month.
    /// Used to add leading empty cells so the grid aligns with day-of-week columns.
    var firstWeekdayOffset: Int {
        let calendar = Calendar.current
        let components = DateComponents(year: year, month: month, day: 1)
        guard let firstDay = calendar.date(from: components) else { return 0 }
        // calendar.component(.weekday) returns 1=Sunday...7=Saturday
        return calendar.component(.weekday, from: firstDay) - 1
    }
}

// MARK: - WeeklyCalendarStrip

/// Continuously scrollable monthly calendar that replaces the old 7-day strip.
/// Generates months from 12 months ago to the current month, with smooth
/// scroll-snapping to month boundaries.
struct WeeklyCalendarStrip: View {
    /// The currently selected date — bound to the parent's state.
    @Binding var selectedDate: Date

    /// NutritionStore is used to look up whether past days have logged entries.
    @Environment(NutritionStore.self) private var nutritionStore

    /// UserGoals determines the calorie threshold for the "goal met" state.
    @Environment(UserGoals.self) private var goals

    /// Calendar used for all date math
    private let calendar = Calendar.current

    /// Whether the calendar is expanded (shows full months) or collapsed (shows one week)
    @State private var isExpanded = false

    /// The months available for scrolling (past 12 months + current month)
    private var months: [MonthID] {
        let today = Date.now
        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)

        // Generate 12 months back + current month = 13 months
        return (-12...0).compactMap { offset in
            var components = DateComponents(year: currentYear, month: currentMonth + offset)
            guard let date = calendar.date(from: components) else { return nil }
            return MonthID(
                year: calendar.component(.year, from: date),
                month: calendar.component(.month, from: date)
            )
        }
    }

    /// The week dates for the collapsed (single-week) view
    private var weekDates: [Date] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return []
        }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekInterval.start)
        }
    }

    /// 7 column grid for the days of the week
    private let dayColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    /// Day-of-week header labels
    private let dayLabels = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(spacing: 0) {
            // ── Toggle header: tap to expand/collapse ──
            toggleHeader

            if isExpanded {
                // ── Expanded: full monthly calendar with vertical scroll ──
                expandedCalendar
            } else {
                // ── Collapsed: single week strip (original behavior) ──
                collapsedWeekStrip
            }
        }
        .glassEffect(in: .rect(cornerRadius: 16))
        .animation(.spring(duration: 0.35, bounce: 0.15), value: isExpanded)
    }

    // MARK: - Toggle Header

    /// Shows current month/year and chevron to expand/collapse
    private var toggleHeader: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(selectedDate.formatted(.dateTime.month(.wide).year()))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))

                Spacer()

                // Today button — quickly jump back to today
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
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Calendar

    /// Full monthly calendar view with continuous vertical scrolling
    private var expandedCalendar: some View {
        VStack(spacing: 0) {
            // ── Day-of-week column headers ──
            dayOfWeekHeaders

            // ── Scrollable months ──
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                        ForEach(months) { month in
                            Section {
                                monthGrid(for: month)
                            } header: {
                                // Sticky month header that pins during scroll
                                Text(month.label)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .frame(height: 280)
                .onAppear {
                    // Scroll to the month containing the selected date
                    let targetMonth = monthID(for: selectedDate)
                    proxy.scrollTo(targetMonth.id, anchor: .top)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Collapsed Week Strip

    /// Single-week horizontal strip (the original interaction pattern)
    private var collapsedWeekStrip: some View {
        HStack(spacing: 0) {
            ForEach(weekDates, id: \.self) { date in
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(weekSwipeGesture)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Horizontal drag offset for the week swipe animation
    @State private var dragOffset: CGFloat = 0

    /// Swipe gesture to navigate between weeks
    private var weekSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let horizontal = value.translation.width
                let isHorizontal = abs(horizontal) > abs(value.translation.height)
                let threshold: CGFloat = 50

                if isHorizontal && abs(horizontal) > threshold {
                    if horizontal < 0, !isCurrentWeek {
                        // Swipe left → next week
                        let next = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
                        if next <= Date.now {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedDate = next
                            }
                        }
                    } else if horizontal > 0 {
                        // Swipe right → previous week
                        withAnimation(.spring(duration: 0.3)) {
                            selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
                        }
                    }
                }
            }
    }

    /// Whether the selected date is in the current week
    private var isCurrentWeek: Bool {
        calendar.isDate(selectedDate, equalTo: .now, toGranularity: .weekOfYear)
    }

    // MARK: - Shared Components

    /// Day-of-week column headers (S M T W T F S)
    private var dayOfWeekHeaders: some View {
        LazyVGrid(columns: dayColumns, spacing: 0) {
            ForEach(dayLabels, id: \.self) { label in
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

    /// Grid of day cells for a single month
    private func monthGrid(for month: MonthID) -> some View {
        LazyVGrid(columns: dayColumns, spacing: 4) {
            // Leading empty cells to align first day with correct weekday column
            ForEach(0..<month.firstWeekdayOffset, id: \.self) { _ in
                Color.clear.frame(height: 40)
            }

            // Actual day cells
            ForEach(month.dates, id: \.self) { date in
                DayCellView(date: date, state: cellState(for: date), compact: true)
                    .frame(height: 40)
                    .onTapGesture {
                        if date <= Date.now || calendar.isDateInToday(date) {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedDate = date
                                // Auto-collapse after selecting a date
                                isExpanded = false
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    /// Creates a MonthID from a Date
    private func monthID(for date: Date) -> MonthID {
        MonthID(
            year: calendar.component(.year, from: date),
            month: calendar.component(.month, from: date)
        )
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

/// A single day cell used in both the week strip and month grid.
/// In the week strip, it shows a 3-letter day abbreviation above the date circle.
/// In the month grid, only the date circle is shown (headers handle day labels).
private struct DayCellView: View {
    let date: Date
    let state: DayCellState
    /// When true, hides the day abbreviation (used in month grid where column headers exist)
    var compact: Bool = false

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

    /// Ring/circle size — smaller in compact mode to fit month grid
    private var circleSize: CGFloat { compact ? 30 : 34 }

    var body: some View {
        VStack(spacing: compact ? 0 : 4) {
            // Day abbreviation (only in non-compact / week strip mode)
            if !compact {
                Text(dayAbbreviation)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(dayTextColor)
            }

            // Date number inside a progress ring
            ZStack {
                // Background track (hidden for future days)
                if case .future = state {
                    // No ring for future days
                } else {
                    Circle()
                        .stroke(.secondary.opacity(0.15), lineWidth: compact ? 2 : 2.5)
                }

                // Progress ring — fills clockwise from top
                Circle()
                    .trim(from: 0, to: state.progressFraction)
                    .stroke(
                        state.ringColor,
                        style: StrokeStyle(lineWidth: compact ? 2 : 2.5, lineCap: .round)
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
                    .font(compact ? .caption : .subheadline)
                    .fontWeight(isSelected ? .bold : .semibold)
                    .foregroundStyle(dateTextColor)
            }
            .frame(width: circleSize, height: circleSize)
        }
        .padding(.vertical, compact ? 2 : 4)
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
