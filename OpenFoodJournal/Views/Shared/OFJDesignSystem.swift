// OpenFoodJournal — executable UI foundations
// AGPL-3.0 License

import SwiftUI

/// Canonical color roles for app chrome and nutrition data.
///
/// These values intentionally match the existing UI. Centralizing them is an
/// architectural guardrail, not authorization to recolor current screens.
enum OFJColor {
    static let calories = Color.orange
    static let protein = Color.blue
    static let carbohydrates = Color.green
    static let fat = Color.yellow

    static let scanAction = Color.blue
    static let manualAction = Color.green
    static let containerAction = Color.orange
    static let foodBankAction = Color.purple
    static let assistantActivity = Color.blue
    static let labelConfidence = Color.teal
    static let estimateConfidence = Color.orange
    static let navigationAction = Color.blue

    enum ProgressBand: CaseIterable {
        case under
        case nearing
        case approaching
        case met
        case slightlyOver
        case farOver

        var color: Color {
            switch self {
            case .under: .red
            case .nearing: .yellow
            case .approaching: Color.green.opacity(0.6)
            case .met: .green
            case .slightlyOver: .orange
            case .farOver: .purple
            }
        }
    }

    static func progressBand(for ratio: Double) -> ProgressBand {
        switch ratio {
        case ..<0.50: .under
        case 0.50..<0.80: .nearing
        case 0.80..<0.95: .approaching
        case 0.95..<1.05: .met
        case 1.05..<1.20: .slightlyOver
        default: .farOver
        }
    }

    static func progress(for ratio: Double) -> Color {
        progressBand(for: ratio).color
    }
}

/// Shared spacing scale. Existing call sites migrate to these values
/// incrementally so architecture work does not become an accidental redesign.
enum OFJSpace {
    static let s1: CGFloat = 1
    static let s2: CGFloat = 2
    static let s3: CGFloat = 3
    static let s4: CGFloat = 4
    static let s5: CGFloat = 5
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s9: CGFloat = 9
    static let s12: CGFloat = 12
    static let s14: CGFloat = 14
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s40: CGFloat = 40
}

/// Shape hierarchy for the current Liquid Glass design language.
enum OFJRadius {
    static let card: CGFloat = 20
    static let compactCard: CGFloat = 16
    static let control: CGFloat = 12
    static let badge: CGFloat = 8
}

/// Semantic typography roles. System text styles remain the default so Dynamic
/// Type continues to work; bespoke nutrition displays retain their current size.
enum OFJType {
    static let nutritionDisplay = Font.system(size: 32, weight: .bold, design: .rounded)
    static let rowTitle = Font.body.weight(.medium)
    static let rowSubtitle = Font.caption
    static let formLabel = Font.subheadline
    static let macroChip = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let confidenceIcon = Font.system(size: 9)
    static let confidenceText = Font.system(size: 9, weight: .medium)
}

/// Named timings prevent interaction feel from drifting between components.
enum OFJMotion {
    static let quickDuration: TimeInterval = 0.2
    static let standardDuration: TimeInterval = 0.3
    static let menuDuration: TimeInterval = 0.4
    static let menuBounce: Double = 0.3

    static let quickSpring = Animation.spring(duration: quickDuration)
    static let standardSpring = Animation.spring(duration: standardDuration)
    static let menuSpring = Animation.spring(duration: menuDuration, bounce: menuBounce)
    static let standardFade = Animation.easeInOut(duration: standardDuration)
}

/// Shared geometry for list-backed screens and tappable controls.
enum OFJLayout {
    static let minimumHitTarget: CGFloat = 44
    static let listHorizontalInset = OFJSpace.s16
    static let listVerticalInset = OFJSpace.s8
    static let journalBottomClearance: CGFloat = 100
    static let emptyStateTopPadding = OFJSpace.s40

    static var standardListRowInsets: EdgeInsets {
        EdgeInsets(
            top: listVerticalInset,
            leading: listHorizontalInset,
            bottom: listVerticalInset,
            trailing: listHorizontalInset
        )
    }

    static var calendarListRowInsets: EdgeInsets {
        EdgeInsets(
            top: listVerticalInset,
            leading: listHorizontalInset,
            bottom: 0,
            trailing: listHorizontalInset
        )
    }
}

/// Provider-neutral screen phases. Views can keep one stable outer container
/// while swapping only the phase content, preventing loading-to-content jumps.
enum OFJContentPhase: String, CaseIterable, Hashable {
    case loading
    case content
    case empty
    case failure
}

#if DEBUG
private struct OFJFoundationPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OFJSpace.s20) {
                Text("OpenFoodJournal")
                    .font(.largeTitle.bold())

                Text("2,308")
                    .font(OFJType.nutritionDisplay)

                GlassEffectContainer(spacing: OFJSpace.s12) {
                    HStack(spacing: OFJSpace.s12) {
                        nutrientChip("P", color: OFJColor.protein)
                        nutrientChip("C", color: OFJColor.carbohydrates)
                        nutrientChip("F", color: OFJColor.fat)
                    }
                }

                ForEach(OFJContentPhase.allCases, id: \.self) { phase in
                    Label(phase.rawValue.capitalized, systemImage: symbol(for: phase))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OFJSpace.s16)
                        .glassEffect(in: .rect(cornerRadius: OFJRadius.card))
                }
            }
            .padding(OFJSpace.s16)
        }
    }

    private func nutrientChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(OFJType.macroChip)
            .foregroundStyle(color)
            .frame(minWidth: OFJLayout.minimumHitTarget, minHeight: OFJLayout.minimumHitTarget)
            .glassEffect(.regular.tint(color.opacity(0.35)), in: .circle)
    }

    private func symbol(for phase: OFJContentPhase) -> String {
        switch phase {
        case .loading: "progress.indicator"
        case .content: "checkmark.circle"
        case .empty: "tray"
        case .failure: "exclamationmark.triangle"
        }
    }
}

#Preview("OFJ Foundations · Light") {
    OFJFoundationPreview()
        .preferredColorScheme(.light)
}

#Preview("OFJ Foundations · Dark") {
    OFJFoundationPreview()
        .preferredColorScheme(.dark)
}

#Preview("OFJ Foundations · Accessibility Type") {
    OFJFoundationPreview()
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
