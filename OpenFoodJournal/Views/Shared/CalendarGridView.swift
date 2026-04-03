// OpenFoodJournal — CalendarGridView
// A custom monthly calendar grid with calorie progress rings on each day cell.
// Uses a horizontal ScrollView with viewAligned snapping for native drag-to-page
// month navigation, matching the WeeklyCalendarStrip's feel.
// AGPL-3.0 License

import SwiftUI
import SwiftData

// MARK: - Month Identifier

/// A Hashable/Identifiable value for each month in the horizontal scroll.
/// Stores the first day of the month for stable identity and date generation.
private struct MonthID: Hashable, Identifiable {
    /// The first day of this month (start of day)
    let startDate: Date

    var id: TimeInterval { startDate.timeIntervalSinceReferenceDate }
}

// MARK: - CalendarGridView

struct CalendarGridView: View {
    // ── Bindings & Environment ────────────────────────────────────
    @Binding var selectedDate: Date
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    // ── Local State ───────────────────────────────────────────────
    @State private var scrolledMonth: MonthID.ID?

    private let calendar = Calendar.current

    /// Number of months of history to make scrollable
    private let monthsOfHistory = 24

    // Column layout for a 7-day week grid
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    // Day-of-week headers matching the user's locale
    private var weekdaySymbols: [String] {
        calendar.veryShortWeekdaySymbols
    }

    /// Pre-computed array of MonthIDs from ~2 years ago to the current month.
    private var months: [MonthID] {
        let currentMonth = startOfMonth(for: Date.now)
        return (-monthsOfHistory...0).compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: offset, to: currentMonth) else {
                return nil
            }
            return MonthID(startDate: calendar.startOfDay(for: month))
        }
    }

    /// The MonthID for the currently scrolled-to month (derived from scrollPosition)
    private var displayedMonth: Date {
        if let scrolledMonth,
           let match = months.first(where: { $0.id == scrolledMonth }) {
            return match.startDate
        }
        return startOfMonth(for: selectedDate)
    }

    /// Whether the displayed month is the current month
    private var isCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month/year header with navigation arrows
            monthHeader

            // Weekday column labels (S, M, T, W, T, F, S)
            weekdayHeader

            // Horizontally scrollable month grids with snap-to-month
            monthScroller
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal)
        .onAppear {
            let initial = startOfMonth(for: selectedDate)
            scrolledMonth = initial.timeIntervalSinceReferenceDate
        }
    }

    // MARK: - Month Header

    /// Shows "March 2026" with left/right arrows to navigate months.
    private var monthHeader: some View {
        HStack {
            Button {
                navigateMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: displayedMonth)

            Spacer()

            // Disable forward nav past current month
            Button {
                navigateMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Weekday Header

    /// Single-letter weekday labels (S, M, T, W, T, F, S)
    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Month Scroller

    /// Horizontal ScrollView containing all months with snap-to-page behavior.
    private var monthScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(months) { month in
                    monthGrid(for: month.startDate)
                        .containerRelativeFrame(.horizontal)
                        .id(month.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledMonth)
    }

    // MARK: - Month Grid

    /// The grid of day cells for a single month. Always renders 6 rows
    /// so all months have consistent height and the scroll doesn't jump.
    private func monthGrid(for monthStart: Date) -> some View {
        let days = daysInMonth(for: monthStart)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(for: date)
                } else {
                    Color.clear
                        .frame(height: 36)
                }
            }
        }
    }

    // MARK: - Day Cell

    /// A single day cell with a progress ring and day number.
    private func dayCell(for date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: .now)
        let progress = progressForDay(date)

        return Button {
            guard !isFuture else { return }
            withAnimation(.spring(duration: 0.3)) {
                selectedDate = date
            }
        } label: {
            ZStack {
                // Background track ring
                if !isFuture {
                    Circle()
                        .stroke(.secondary.opacity(0.15), lineWidth: 2)
                }

                // Progress ring — fills clockwise from top
                if progress > 0 && !isFuture {
                    Circle()
                        .trim(from: 0, to: min(progress, 1.0))
                        .stroke(
                            ringColor(for: progress),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                // Selected day background
                if isSelected {
                    Circle()
                        .fill(.regularMaterial)
                        .padding(2)
                }

                // Day number
                Text("\(calendar.component(.day, from: date))")
                    .font(.caption)
                    .fontWeight(isSelected || isToday ? .bold : .regular)
                    .foregroundStyle(
                        isFuture ? Color.secondary.opacity(0.4) :
                        isSelected ? Color.primary :
                        isToday ? Color.blue : Color.primary
                    )
            }
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    // MARK: - Navigation

    /// Navigate forward or backward by one month via scroll position.
    private func navigateMonth(by value: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        let target = startOfMonth(for: newMonth)
        withAnimation(.spring(duration: 0.3)) {
            scrolledMonth = target.timeIntervalSinceReferenceDate
        }
    }

    // MARK: - Helpers

    /// Returns the first day of the month containing the given date
    private func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)!
    }

    /// Generates an array of optional Dates for a month grid.
    /// Always returns 42 cells (6 rows x 7 columns) for consistent height.
    /// `nil` entries represent empty cells before/after the month's days.
    private func daysInMonth(for monthStart: Date) -> [Date?] {
        let start = startOfMonth(for: monthStart)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }

        // How many empty cells before the 1st
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)

        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: start) {
                days.append(date)
            }
        }

        // Pad to 42 cells (6 rows) for consistent height across months
        while days.count < 42 {
            days.append(nil)
        }

        return days
    }

    /// Calculates calorie progress (0.0–1.0+) for a given day
    private func progressForDay(_ date: Date) -> Double {
        guard goals.dailyCalories > 0,
              let log = nutritionStore.fetchLog(for: date) else {
            return 0
        }
        let totalCalories = log.safeEntries.reduce(0.0) { $0 + $1.calories }
        return totalCalories / goals.dailyCalories
    }

    /// Maps a progress fraction to a color using the same thresholds as WeeklyCalendarStrip.
    /// < 50% red, 50-80% yellow, 80-95% light green, 95-105% green, 105-120% orange, >120% purple
    private func ringColor(for progress: Double) -> Color {
        switch progress {
        case ..<0.50:      return .red
        case 0.50..<0.80:  return .yellow
        case 0.80..<0.95:  return Color.green.opacity(0.6)
        case 0.95..<1.05:  return .green
        case 1.05..<1.20:  return .orange
        default:           return .purple
        }
    }
}
