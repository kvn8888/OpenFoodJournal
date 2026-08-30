// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

/// A circular progress ring showing a macro value vs. goal.
struct MacroRingView: View {
    let value: Double
    let goal: Double
    let color: Color
    let label: String
    let unit: String
    var usesJournalStyle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overColor: Color { usesJournalStyle ? OFJColor.calendarOverGoalRGB.color : .orange }
    private var strokeWidth: CGFloat { usesJournalStyle ? OFJLayout.journalNutrientRingStroke : 5 }

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(value / goal, 1.0)
    }

    private var isOver: Bool {
        goal > 0 && value > goal
    }

    var body: some View {
        // Rings are pinned to top; labels sit below and can wrap without
        // shifting the ring position. fixedSize(vertical: false) lets the
        // label text wrap horizontally within the available width.
        VStack(spacing: usesJournalStyle ? 7 : 4) {
            ZStack {
                // Track
                Circle()
                    .stroke(color.opacity(usesJournalStyle ? 0.1 : 0.2), lineWidth: strokeWidth)

                // Progress arc
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        isOver ? overColor : color,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut, value: progress)

                // Center label
                VStack(spacing: usesJournalStyle ? -2 : 0) {
                    Text(value, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: usesJournalStyle ? 16 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isOver ? overColor : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 40)
                        .ofjNumericTextTransition(value: value)
                    Text(unit)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)

            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 56)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 56, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(value)) of \(Int(goal)) \(unit)")
    }
}

#Preview("Normal") {
    HStack(spacing: 20) {
        MacroRingView(value: 1200, goal: 2000, color: .orange, label: "Calories", unit: "kcal")
        MacroRingView(value: 95, goal: 150, color: .blue, label: "Protein", unit: "g")
        MacroRingView(value: 180, goal: 200, color: .green, label: "Carbs", unit: "g")
        MacroRingView(value: 70, goal: 65, color: .yellow, label: "Fat", unit: "g")
    }
    .padding()
}

#Preview("Over Goal") {
    MacroRingView(value: 2400, goal: 2000, color: .orange, label: "Calories", unit: "kcal")
        .padding()
}
