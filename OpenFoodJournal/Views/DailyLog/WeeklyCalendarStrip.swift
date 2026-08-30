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
//   • The Journal toolbar owns the "Today" jump and selected month/year title
//
// Day cell states drive visual appearance:
//   1. Selected (active day) — rounded rectangle, bold text, progress ring
//   2. Past (default)        — secondary text, progress ring shows intake
//   3. Future                — dimmed text, empty dashed progress ring

import SwiftUI

// MARK: - Day Cell State

/// Represents the visual state of a single day cell in the calendar.
/// For past days, includes the calorie progress fraction (0.0–1.0+) and a
/// color derived from how close the user got to their daily goal.
enum DayCellState {
    case selected(progress: Double)  // The currently active/selected day
    case past(progress: Double)      // A past day with logged data
    case future                      // A day in the future (no data yet)

    var isSelected: Bool {
        if case .selected = self { return true }
        return false
    }

    var isFuture: Bool {
        if case .future = self { return true }
        return false
    }

    var progress: Double? {
        switch self {
        case .selected(let progress), .past(let progress):
            progress
        case .future:
            nil
        }
    }

    /// Calendar-only palette: adaptive black below 80%, existing greens near
    /// and at goal, and #D86669 above goal.
    var ringColor: Color {
        guard let progress else { return .clear }
        return OFJColor.journalCalorieState(for: progress).ringColor
    }

    /// The fraction (0.0–1.0) of the ring that should be filled.
    /// Capped at 1.0 so the ring never overflows visually.
    var progressFraction: Double {
        min(max(progress ?? 0, 0), 1)
    }

    var accessibilityValue: String {
        switch self {
        case .selected(let progress):
            "Selected, \(Int((progress * 100).rounded())) percent of calorie goal"
        case .past(let progress):
            "\(Int((progress * 100).rounded())) percent of calorie goal"
        case .future:
            "Future date, unavailable"
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

    /// Required live input from the Journal's shared query-backed totals.
    /// No cell-level fetches: fetching an empty day once does not subscribe to
    /// the DailyLog that may later be created by a local write or CloudKit.
    private let calorieProgressByDate: [Date: Double]

    /// Calendar used for all date math
    private let calendar = Calendar.current

    init(
        selectedDate: Binding<Date>,
        calorieProgressByDate: [Date: Double]
    ) {
        _selectedDate = selectedDate
        self.calorieProgressByDate = calorieProgressByDate
    }

    /// Number of weeks of history to make scrollable
    private let weeksOfHistory = JournalDayData.weeksOfHistory

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
        weekScroller
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
            .onChange(of: selectedDate) { oldDate, newDate in
                // When selectedDate changes (e.g. "Today" button), scroll to that week.
                // Only open an animated transaction when the week actually changed —
                // otherwise every same-week tap re-animates the whole strip one update
                // after the tap's own animation, retargeting transitions mid-flight.
                guard let target = weekIDForDate(newDate),
                      weekIDForDate(oldDate) != target else {
                    return
                }
                withAnimation(OFJMotion.standardSpring) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
        }
        .padding(.vertical, OFJSpace.s4)
    }

    // MARK: - Week Row

    /// Renders 7 day cells in a horizontal row for one week.
    private func weekRow(for week: WeekID) -> some View {
        HStack(spacing: 0) {
            ForEach(week.dates, id: \.self) { date in
                CalendarDayButton(
                    date: date,
                    state: cellState(for: date),
                    selectedDate: $selectedDate
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, OFJSpace.s4)
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

        let progress = calorieProgressByDate[startOfDate] ?? 0

        let startOfSelected = calendar.startOfDay(for: selectedDate)
        if startOfDate == startOfSelected {
            return .selected(progress: progress)
        }

        return .past(progress: progress)
    }
}

// MARK: - Calendar Day Control

/// Owns pointer/press feedback and selection semantics so every date behaves
/// like a real accessible control instead of a tap gesture attached to text.
private struct CalendarDayButton: View {
    let date: Date
    let state: DayCellState
    @Binding var selectedDate: Date

    @State private var isHovering = false

    var body: some View {
        Button {
            guard !state.isFuture else { return }
            withAnimation(OFJMotion.standardSpring) {
                selectedDate = date
            }
        } label: {
            DayCellView(date: date, state: state)
        }
        .buttonStyle(
            CalendarDayButtonStyle(
                isHighlighted: !state.isFuture && (state.isSelected || isHovering)
            )
        )
        .disabled(state.isFuture)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        )
        .accessibilityValue(state.accessibilityValue)
        .accessibilityHint(
            state.isFuture
                ? "Future dates cannot be selected"
                : "Shows this day in the journal"
        )
        .accessibilityAddTraits(state.isSelected ? .isSelected : [])
    }
}

private struct CalendarDayButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let showRectangle = isHighlighted || configuration.isPressed

        configuration.label
            .frame(
                maxWidth: .infinity,
                minHeight: OFJLayout.calendarDayControlHeight
            )
            .background {
                RoundedRectangle(
                    cornerRadius: OFJRadius.compactCard,
                    style: .continuous
                )
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: OFJRadius.compactCard,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(
                    color: Color.black.opacity(showRectangle ? 0.09 : 0),
                    radius: 8,
                    y: 3
                )
                .opacity(showRectangle ? 1 : 0)
                .padding(.horizontal, OFJSpace.s2)
            }
            .contentShape(
                .rect(cornerRadius: OFJRadius.compactCard)
            )
            // Card and label share one timeline that matches the selection
            // animation in CalendarDayButton, so the highlight and the day's
            // colors can't land on different clocks.
            .animation(OFJMotion.standardSpring, value: showRectangle)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            // Press feedback stays quick and is scoped to the scale alone.
            .animation(OFJMotion.quickSpring, value: configuration.isPressed)
    }
}

// MARK: - Day Cell

/// A single day cell showing a day abbreviation and a date number inside
/// a progress ring. Used in the week strip rows.
private struct DayCellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date
    let state: DayCellState

    /// 3-letter day abbreviation (e.g. "Mon", "Tue")
    private var dayAbbreviation: String {
        date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    /// Day-of-month number (e.g. "13", "7")
    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    var body: some View {
        VStack(spacing: OFJSpace.s4) {
            // Day abbreviation (e.g. "Mon")
            Text(dayAbbreviation)
                .font(OFJType.calendarWeekday)
                .foregroundStyle(dayTextColor)

            // Date number inside a progress ring
            ZStack {
                if state.isFuture {
                    Circle()
                        .stroke(
                            Color.secondary.opacity(0.28),
                            style: StrokeStyle(
                                lineWidth: OFJLayout.calendarRingLineWidth,
                                lineCap: .round,
                                dash: [2.5, 4]
                            )
                        )
                } else {
                    Circle()
                        .stroke(
                            Color.secondary.opacity(0.15),
                            lineWidth: OFJLayout.calendarRingLineWidth
                        )

                    // Progress ring — fills clockwise from top.
                    Circle()
                        .trim(from: 0, to: state.progressFraction)
                        .stroke(
                            state.ringColor,
                            style: StrokeStyle(
                                lineWidth: OFJLayout.calendarRingLineWidth,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(-90))
                        // Data updates animate only the arc/color, without
                        // restarting selection or cross-fading date glyphs.
                        .animation(reduceMotion ? nil : .easeInOut, value: state.progress)
                }

                // The date number text.
                //
                // Font weight is not an interpolatable property. Animating this
                // Text makes SwiftUI cross-fade a bold raster against a regular
                // one, so both glyph sets sit on screen at partial opacity for
                // the whole duration — the deselecting day looks like it snaps
                // to bold and then back to thin. Strip the transaction so the
                // weight (and its paired color) change in a single clean frame
                // while the card and ring animate around it.
                Text(dayNumber)
                    .font(OFJType.calendarDay)
                    .fontWeight(state.isSelected ? .bold : .regular)
                    .foregroundStyle(dateTextColor)
                    .transaction { $0.animation = nil }
            }
            .frame(
                width: OFJLayout.calendarDayRingSize,
                height: OFJLayout.calendarDayRingSize
            )
        }
    }

    // MARK: - State-Driven Styling

    private var dayTextColor: Color {
        switch state {
        case .selected: .primary
        case .past: .secondary
        case .future: .secondary.opacity(0.42)
        }
    }

    private var dateTextColor: Color {
        switch state {
        case .selected: .primary
        case .past: .secondary
        case .future: .secondary.opacity(0.42)
        }
    }
}

// MARK: - Preview

/// The preview supplies the same value input as production, without a database.
@MainActor
private struct CalendarStripPreview: View {
    @State private var date = Date.now

    private var calorieProgressByDate: [Date: Double] {
        guard let weekStart = Calendar.current.dateInterval(
            of: .weekOfYear,
            for: date
        )?.start else {
            return [:]
        }

        let progress = [0.38, 0.64, 0.81, 0.97, 1.08, 0.9, 0.0]
        return Dictionary(uniqueKeysWithValues: progress.enumerated().compactMap { offset, value in
            Calendar.current.date(byAdding: .day, value: offset, to: weekStart)
                .map { (Calendar.current.startOfDay(for: $0), value) }
        })
    }

    var body: some View {
        WeeklyCalendarStrip(
            selectedDate: $date,
            calorieProgressByDate: calorieProgressByDate
        )
            .padding()
    }
}

private struct CalendarStateMatrixPreview: View {
    @State private var selectedDate = Date.now

    private var samples: [(Date, DayCellState)] {
        let calendar = Calendar.current
        return [
            (selectedDate, .selected(progress: 0.72)),
            (calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate, .past(progress: 0.99)),
            (calendar.date(byAdding: .day, value: -2, to: selectedDate) ?? selectedDate, .past(progress: 1.12)),
            (calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate, .future),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                CalendarDayButton(
                    date: sample.0,
                    state: sample.1,
                    selectedDate: $selectedDate
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(OFJSpace.s16)
    }
}

#Preview("Calendar Strip") {
    CalendarStripPreview()
}

#Preview("Calendar States · Light") {
    CalendarStateMatrixPreview()
        .preferredColorScheme(.light)
}

#Preview("Calendar States · Dark") {
    CalendarStateMatrixPreview()
        .preferredColorScheme(.dark)
}

#Preview("Calendar States · Accessibility Type") {
    CalendarStateMatrixPreview()
        .environment(\.dynamicTypeSize, .accessibility3)
}
