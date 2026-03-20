// Macros — Food Journaling App
// AGPL-3.0 License
//
// WeeklyCalendarStrip — A horizontal 7-day calendar strip that replaces
// the old left/right arrow date picker. Each day cell shows:
//   • 3-letter day abbreviation (e.g. "Mon")
//   • Date number in a circle whose style reflects the cell's state
//
// Four states drive the visual appearance:
//   1. Selected (active day) — black text, thick black circle stroke
//   2. Past (default)        — gray text, thin gray circle stroke
//   3. Past (goal met)       — gray text, thin green circle stroke
//   4. Future                — light gray text, no circle stroke

import SwiftUI
import SwiftData

// MARK: - Day Cell State

/// Represents the visual state of a single day cell in the strip.
/// For past days, includes the calorie progress fraction (0.0–1.0+) and a
/// color derived from how close the user got to their daily goal.
enum DayCellState {
    case selected(progress: Double)  // The currently active/selected day (may also show progress)
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

// MARK: - WeeklyCalendarStrip

/// The main strip view. It computes the 7 days of the week containing
/// `selectedDate`, then renders each as a tappable DayCellView.
struct WeeklyCalendarStrip: View {
    /// The currently selected date — bound to the parent's state.
    @Binding var selectedDate: Date

    /// NutritionStore is used to look up whether past days have logged entries.
    @Environment(NutritionStore.self) private var nutritionStore

    /// UserGoals determines the calorie threshold for the "goal met" state.
    @Environment(UserGoals.self) private var goals

    /// Calendar used for all date math (start of week, comparisons, etc.)
    private let calendar = Calendar.current

    /// Computes the 7 dates for the week containing `selectedDate`.
    /// Starts from Sunday (or the user's locale-specific first weekday).
    private var weekDates: [Date] {
        // Find the start of the week containing the selected date
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return []
        }
        // Generate 7 consecutive days starting from the week's start
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekInterval.start)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Navigate to previous week
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The 7 day cells, evenly distributed across available width
            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    DayCellView(
                        date: date,
                        state: cellState(for: date)
                    )
                    .frame(maxWidth: .infinity)  // Even distribution
                    .onTapGesture {
                        // Only allow selecting today or past days
                        if date <= Date.now || calendar.isDateInToday(date) {
                            withAnimation(.spring(duration: 0.3)) {
                                selectedDate = date
                            }
                        }
                    }
                }
            }

            // Navigate to next week (disabled if it would go past today)
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    let next = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
                    // Allow navigating forward only if the week contains today or earlier
                    if next <= Date.now {
                        selectedDate = next
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isCurrentWeek ? 0.3 : 1)
            .disabled(isCurrentWeek)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    /// Whether the selected date is in the current week (disables forward nav)
    private var isCurrentWeek: Bool {
        calendar.isDate(selectedDate, equalTo: .now, toGranularity: .weekOfYear)
    }

    /// Determines the visual state for a given date in the strip.
    /// Computes calorie progress as a fraction of the daily goal.
    private func cellState(for date: Date) -> DayCellState {
        let startOfDate = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: .now)

        // Future days (after today) get the dimmed "future" state
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

/// A single day cell in the strip: day abbreviation on top, circled date below.
/// The circle is a progress ring that fills based on calorie intake vs. goal.
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

    var body: some View {
        VStack(spacing: 4) {
            // Day abbreviation (top)
            Text(dayAbbreviation)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(dayTextColor)

            // Date number inside a progress ring (bottom)
            ZStack {
                // Background track — thin gray circle (hidden for future days)
                if case .future = state {
                    // No ring for future days
                } else {
                    Circle()
                        .stroke(.secondary.opacity(0.15), lineWidth: 2.5)
                }

                // Progress ring — fills clockwise from the top based on calorie progress
                Circle()
                    .trim(from: 0, to: state.progressFraction)
                    .stroke(
                        state.ringColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))  // Start from top (12 o'clock)

                // Filled background for selected day only
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
            .frame(width: 34, height: 34)
        }
        .padding(.vertical, 4)
    }

    // MARK: - State-Driven Styling

    /// Text color for the day abbreviation, varies by state
    private var dayTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .past:         return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }

    /// Text color for the date number, varies by state
    private var dateTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .past:         return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var date = Date.now
    WeeklyCalendarStrip(selectedDate: $date)
        .padding()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(UserGoals())
}
