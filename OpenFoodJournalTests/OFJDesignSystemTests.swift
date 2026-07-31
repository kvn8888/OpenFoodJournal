// OpenFoodJournal — executable UI foundation contracts
// AGPL-3.0 License

import SwiftUI
import Testing
@testable import OpenFoodJournal

@MainActor
struct OFJDesignSystemTests {
    @Test("root tabs exclude Settings and preserve primary destinations")
    func rootTabs() {
        #expect(AppTab.allCases == [.journal, .foodBank, .history, .assistant])
        #expect(JournalRoute.allCases == [.settings])
    }

    @Test("shape hierarchy remains concentric")
    func radiiAreOrdered() {
        #expect(OFJRadius.card > OFJRadius.compactCard)
        #expect(OFJRadius.compactCard > OFJRadius.control)
        #expect(OFJRadius.control > OFJRadius.badge)
    }

    @Test("spacing scale remains strictly ordered")
    func spacingIsOrdered() {
        let spacing = [
            OFJSpace.s1,
            OFJSpace.s2,
            OFJSpace.s3,
            OFJSpace.s4,
            OFJSpace.s5,
            OFJSpace.s6,
            OFJSpace.s8,
            OFJSpace.s9,
            OFJSpace.s12,
            OFJSpace.s14,
            OFJSpace.s16,
            OFJSpace.s20,
            OFJSpace.s24,
            OFJSpace.s40,
        ]

        #expect(spacing == spacing.sorted())
        #expect(Set(spacing).count == spacing.count)
    }

    @Test("list metrics preserve the existing Journal geometry")
    func listMetrics() {
        let standard = OFJLayout.standardListRowInsets
        #expect(standard.top == 8)
        #expect(standard.leading == 16)
        #expect(standard.bottom == 8)
        #expect(standard.trailing == 16)

        let calendar = OFJLayout.calendarListRowInsets
        #expect(calendar.top == 8)
        #expect(calendar.leading == 16)
        #expect(calendar.bottom == 0)
        #expect(calendar.trailing == 16)

        #expect(OFJLayout.minimumHitTarget >= 44)
        #expect(OFJLayout.calendarDayControlHeight >= OFJLayout.minimumHitTarget)
        #expect(OFJLayout.calendarDayRingSize < OFJLayout.calendarDayControlHeight)
        #expect(OFJLayout.calendarRingLineWidth > 0)
        #expect(OFJLayout.journalBottomClearance == 100)
    }

    @Test(
        "Journal calorie state uses black below goal, existing greens near goal, and red above goal",
        arguments: [
            (0.00, OFJColor.JournalCalorieState.belowGoal),
            (0.79, .belowGoal),
            (0.80, .approachingGoal),
            (0.94, .approachingGoal),
            (0.95, .goalMet),
            (1.04, .goalMet),
            (1.05, .overGoal),
            (1.50, .overGoal),
        ]
    )
    func journalCalorieStates(
        ratio: Double,
        expected: OFJColor.JournalCalorieState
    ) {
        #expect(OFJColor.journalCalorieState(for: ratio) == expected)
    }

    @Test("Journal over-goal red is the approved D86669 value")
    func journalOverGoalColor() {
        #expect(
            OFJColor.calendarOverGoalRGB
                == OFJColor.SRGB8(red: 0xD8, green: 0x66, blue: 0x69)
        )
    }

    @Test("calendar day states preserve future blocking and bounded progress")
    func calendarDayStates() {
        let future = DayCellState.future
        #expect(future.isFuture)
        #expect(!future.isSelected)
        #expect(future.progress == nil)
        #expect(future.progressFraction == 0)

        let selected = DayCellState.selected(progress: 1.25)
        #expect(selected.isSelected)
        #expect(!selected.isFuture)
        #expect(selected.progress == 1.25)
        #expect(selected.progressFraction == 1)
    }

    @Test(
        "calorie progress resolves to the canonical status band",
        arguments: [
            (0.49, OFJColor.ProgressBand.under),
            (0.50, .nearing),
            (0.80, .approaching),
            (0.95, .met),
            (1.05, .slightlyOver),
            (1.20, .farOver),
        ]
    )
    func progressBands(ratio: Double, expected: OFJColor.ProgressBand) {
        #expect(OFJColor.progressBand(for: ratio) == expected)
    }

    @Test("motion timings remain positive and ordered by intent")
    func motionTimings() {
        #expect(OFJMotion.quickDuration > 0)
        #expect(OFJMotion.quickDuration < OFJMotion.standardDuration)
        #expect(OFJMotion.standardDuration < OFJMotion.menuDuration)
        #expect((0...1).contains(OFJMotion.menuBounce))
    }

    @Test("screen phases cover stable loading, content, empty, and failure states")
    func contentPhases() {
        #expect(OFJContentPhase.allCases == [.loading, .content, .empty, .failure])
    }
}
