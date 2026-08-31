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
    let calorieProgressByDate: [Date: Double]

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
        let currentMonth = startOfMonth(for: AppPresentationDate.now)
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
        calendar.isDate(displayedMonth, equalTo: AppPresentationDate.now, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month/year header with navigation arrows
            monthHeader

            // Weekday column labels (S, M, T, W, T, F, S)
            weekdayHeader

            // Horizontally scrollable month grids with snap-to-month
            monthScroller

            Divider()
            HStack(spacing: 10) {
                legend("Below", .primary)
                legend("Near", .green.opacity(0.5))
                legend("Met", .green)
                legend("Over", OFJColor.calendarOverGoalRGB.color)
                legend("No log", .secondary.opacity(0.25))
            }
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal)
        .onChange(of: selectedDate) { _, date in
            scrolledMonth = startOfMonth(for: date).timeIntervalSinceReferenceDate
        }
        .onAppear {
            let initial = startOfMonth(for: selectedDate)
            scrolledMonth = initial.timeIntervalSinceReferenceDate
        }
    }

    // MARK: - Month Header

    /// Shows "March 2026" with left/right arrows to navigate months.
    private var monthHeader: some View {
        GlassEffectContainer(spacing: 8) {
          HStack {
            Button {
                navigateMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(displayedMonth <= (months.first?.startDate ?? displayedMonth))
            .accessibilityLabel("Previous month")

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
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
          }
        }
        .padding(.horizontal, 4)
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.caption2)
        }.foregroundStyle(.secondary)
    }

    // MARK: - Weekday Header

    /// Single-letter weekday labels (S, M, T, W, T, F, S)
    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
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
        .frame(height: 6 * 44 + 5 * 6)
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
                        .frame(height: 44)
                }
            }
        }
    }

    // MARK: - Day Cell

    /// A single day cell with a progress ring and day number.
    private func dayCell(for date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: AppPresentationDate.now)
        let progress = progressForDay(date)

        return Button {
            guard !isFuture else { return }
            selectedDate = date
        } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(isFuture ? 0.28 : 0.15),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: isFuture ? [2.5, 4] : []))
                if !isFuture {
                    Circle().trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(OFJColor.journalCalorieState(for: progress).ringColor,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isFuture ? Color.secondary.opacity(0.42) : isSelected ? .primary : .secondary)
                    .transaction { $0.animation = nil }
            }
            .frame(width: 36, height: 36)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)) }
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(.rect(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(isFuture)
            .accessibilityLabel(date.formatted(.dateTime.month(.wide).day()))
            .accessibilityValue(isFuture ? "Future date, unavailable" : "\(Int((progress * 100).rounded())) percent of calorie goal")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Navigation

    /// Navigate forward or backward by one month via scroll position.
    private func navigateMonth(by value: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        let target = startOfMonth(for: newMonth)
        guard months.contains(where: { $0.startDate == target }) else { return }
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

    /// Shared live values from History's query; never fetch inside each cell.
    private func progressForDay(_ date: Date) -> Double {
        calorieProgressByDate[calendar.startOfDay(for: date)] ?? 0
    }
}
