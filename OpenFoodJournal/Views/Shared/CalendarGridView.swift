// OpenFoodJournal — CalendarGridView
// A custom monthly calendar grid with calorie progress rings on each day cell.
// Replaces the system DatePicker(.graphical) in HistoryView to show at-a-glance
// nutrition progress for each day. Supports month navigation with smooth transitions.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct CalendarGridView: View {
    // ── Bindings & Environment ────────────────────────────────────
    @Binding var selectedDate: Date
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    // ── Local State ───────────────────────────────────────────────
    // The month currently being displayed (first day of that month)
    @State private var displayedMonth: Date = .now

    private let calendar = Calendar.current

    // Column layout for a 7-day week grid
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    // Day-of-week headers matching the user's locale
    private var weekdaySymbols: [String] {
        calendar.veryShortWeekdaySymbols
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month/year header with navigation arrows
            monthHeader

            // Weekday column labels (S, M, T, W, T, F, S)
            weekdayHeader

            // Day cells grid with progress rings
            dayGrid
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal)
        // Swipe left/right to navigate months
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    // Horizontal swipe: negative = swipe left = next month
                    let horizontal = value.translation.width
                    if horizontal < -50 && !isCurrentMonth {
                        withAnimation(.spring(duration: 0.3)) {
                            displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth)!
                        }
                    } else if horizontal > 50 {
                        withAnimation(.spring(duration: 0.3)) {
                            displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth)!
                        }
                    }
                }
        )
        .onAppear {
            // Initialize displayedMonth to the month of selectedDate
            displayedMonth = startOfMonth(for: selectedDate)
        }
    }

    // MARK: - Month Header

    /// Shows "March 2026" with left/right arrows to navigate months.
    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth)!
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)

            Spacer()

            // Disable forward nav past current month
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth)!
                }
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
    /// Uses enumerated indices as IDs because veryShortWeekdaySymbols has
    /// duplicates ("S" twice, "T" twice) — ForEach(id: \.self) would dedupe them.
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

    // MARK: - Day Grid

    /// The main grid of day cells. Each cell shows the day number with a progress ring.
    /// Empty cells pad the start/end to align days with correct weekday columns.
    private var dayGrid: some View {
        let days = daysInMonth()
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(days, id: \.self) { date in
                if let date {
                    dayCell(for: date)
                } else {
                    // Empty spacer for days before/after the month
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

    // MARK: - Helpers

    /// Whether the displayed month is the current month (disables forward nav)
    private var isCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    /// Returns the first day of the month containing the given date
    private func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)!
    }

    /// Generates an array of optional Dates for the month grid.
    /// `nil` entries represent empty cells before/after the month's days.
    private func daysInMonth() -> [Date?] {
        let start = startOfMonth(for: displayedMonth)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }

        // How many empty cells before the 1st (to align with correct weekday column)
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)

        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: start) {
                days.append(date)
            }
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
