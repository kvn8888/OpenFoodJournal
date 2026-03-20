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

// MARK: - Day Cell State

/// Represents the visual state of a single day cell in the strip.
/// The state determines text color, circle stroke color, and stroke width.
enum DayCellState {
    case selected       // The currently active/selected day
    case pastDefault    // A past day where the user did NOT meet their calorie goal
    case pastGoalMet    // A past day where the user DID meet their calorie goal
    case future         // A day in the future (no data yet)
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
    /// Checks: is it the selected day? Is it in the future? Did the user meet their goal?
    private func cellState(for date: Date) -> DayCellState {
        let startOfDate = calendar.startOfDay(for: date)
        let startOfSelected = calendar.startOfDay(for: selectedDate)

        // Selected day always gets the "selected" state
        if startOfDate == startOfSelected {
            return .selected
        }

        // Future days (after today) get the dimmed "future" state
        if startOfDate > calendar.startOfDay(for: .now) {
            return .future
        }

        // Past day — check if the user met their calorie goal
        if let log = nutritionStore.fetchLog(for: date) {
            let totalCalories = log.entries.reduce(0.0) { $0 + $1.calories }
            // "Goal met" = logged at least 80% of daily calorie target
            // (a reasonable threshold so users don't need to hit exactly 100%)
            if totalCalories >= goals.dailyCalories * 0.8 {
                return .pastGoalMet
            }
        }

        return .pastDefault
    }
}

// MARK: - DayCellView

/// A single day cell in the strip: day abbreviation on top, circled date below.
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

    var body: some View {
        VStack(spacing: 4) {
            // Day abbreviation (top)
            Text(dayAbbreviation)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(dayTextColor)

            // Date number inside a circle (bottom)
            Text(dayNumber)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(dateTextColor)
                .frame(width: 32, height: 32)
                .background(dateBackground)
                .overlay(dateCircleOverlay)
        }
        .padding(.vertical, 4)
    }

    // MARK: - State-Driven Styling

    /// Text color for the day abbreviation, varies by state
    private var dayTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .pastDefault:  return .secondary
        case .pastGoalMet:  return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }

    /// Text color for the date number, varies by state
    private var dateTextColor: Color {
        switch state {
        case .selected:     return .primary
        case .pastDefault:  return .secondary
        case .pastGoalMet:  return .secondary
        case .future:       return .secondary.opacity(0.4)
        }
    }

    /// Background shape — only the selected day gets a filled white circle
    @ViewBuilder
    private var dateBackground: some View {
        if state == .selected {
            Circle()
                .fill(.regularMaterial)
        }
    }

    /// Circle overlay — stroke color and width depend on state
    @ViewBuilder
    private var dateCircleOverlay: some View {
        switch state {
        case .selected:
            Circle()
                .stroke(.primary, lineWidth: 2.5)
        case .pastDefault:
            Circle()
                .stroke(.secondary.opacity(0.4), lineWidth: 1)
        case .pastGoalMet:
            Circle()
                .stroke(.green, lineWidth: 1.5)
        case .future:
            EmptyView()  // No circle for future days
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
