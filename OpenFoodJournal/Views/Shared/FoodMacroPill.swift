import SwiftUI

/// Shared by Journal and Food Bank: one neutral glass surface with three colored
/// values. Keep future tuning here so the two entry points cannot drift apart.
struct FoodMacroPill: View {
    let protein: Double
    let carbs: Double
    let fat: Double
    @ScaledMetric(relativeTo: .caption) private var diameter = OFJLayout.journalMacroDiameter
    @ScaledMetric(relativeTo: .caption) private var overlap = OFJLayout.journalMacroOverlap
    @ScaledMetric(relativeTo: .caption) private var numberSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var unitSize: CGFloat = 12

    var body: some View {
        HStack(spacing: -overlap) {
            column(value: protein, color: OFJColor.journalProtein)
            column(value: carbs, color: OFJColor.journalCarbohydrates)
            column(value: fat, color: OFJColor.journalFat)
        }
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protein \(protein.formatted()) grams, carbohydrates \(carbs.formatted()) grams, fat \(fat.formatted()) grams")
    }

    private func column(value: Double, color: Color) -> some View {
        VStack(spacing: -1) {
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(size: numberSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .ofjNumericTextTransition(value: value)
            Text("G").font(.system(size: unitSize, weight: .bold))
        }
        .foregroundStyle(color)
        .frame(width: diameter - overlap)
        .frame(width: diameter, height: diameter)
    }
}
