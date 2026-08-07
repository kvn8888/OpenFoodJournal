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
        #expect(OFJLayout.cameraTopControlSize >= OFJLayout.minimumHitTarget)
        #expect(OFJLayout.cameraUtilityControlSize >= OFJLayout.minimumHitTarget)
        #expect(OFJLayout.cameraModeControlHeight >= OFJLayout.minimumHitTarget)
        #expect(OFJLayout.cameraZoomControlWidth > OFJLayout.minimumHitTarget)
        #expect(OFJLayout.cameraZoomControlHeight >= OFJLayout.minimumHitTarget)
        #expect(OFJLayout.cameraShutterSize > OFJLayout.cameraUtilityControlSize)
        #expect(OFJLayout.journalBottomClearance == 100)
    }

    @Test("camera exposes exactly the three supported capture modes in visual order")
    func cameraModeContract() {
        let descriptors = ScanCameraModeDescriptor.supported

        #expect(descriptors.map(\.mode) == [.foodPhoto, .barcode, .label])
        #expect(descriptors.map(\.title) == ["Scan Food", "Barcode", "Food Label"])
        #expect(descriptors.allSatisfy { !$0.symbol.isEmpty })
        #expect(!descriptors.map(\.mode).contains(.manual))
    }

    @Test("camera zoom uses Apple's display multiplier and preserves a visible 1x neutral point")
    func cameraZoomConfiguration() {
        let configuration = CameraZoomConfiguration(
            range: 1.0...10.0,
            displayMultiplier: 0.5
        )

        #expect(configuration.neutralFactor == 2.0)
        #expect(configuration.displayFactor(for: 1.0) == 0.5)
        #expect(configuration.displayFactor(for: 2.0) == 1.0)
        #expect(configuration.displayLabel(for: 2.0) == "1×")
        #expect(configuration.displayLabel(for: 3.0) == "1.5×")
        #expect(configuration.clampedFactor(100) == 10.0)
        #expect(configuration.isAdjustable)
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

    @Test("appearance themes preserve blue as default and resolve unknown backups safely")
    func accentThemeContract() {
        #expect(
            OFJAccentTheme.allCases
                == [.systemBlue, .harvestOrange, .leafGreen, .berryPurple]
        )
        #expect(OFJAccentTheme.defaultTheme == .systemBlue)
        #expect(OFJAccentTheme.resolved(from: "harvestOrange") == .harvestOrange)
        #expect(OFJAccentTheme.resolved(from: "future-theme") == .systemBlue)
    }

    @Test("Harvest Orange uses the owner-approved accent and tonal surface values")
    func harvestOrangePalette() {
        #expect(
            OFJColor.harvestOrangeAccentRGB
                == OFJColor.SRGB8(red: 0xE9, green: 0x79, blue: 0x2B)
        )
        #expect(
            OFJColor.harvestLightCanvasRGB
                == OFJColor.SRGB8(red: 0xF6, green: 0xF5, blue: 0xF3)
        )
        #expect(
            OFJColor.harvestLightCardRGB
                == OFJColor.SRGB8(red: 0xFF, green: 0xFF, blue: 0xFF)
        )
        #expect(
            OFJColor.harvestDarkCanvasRGB
                == OFJColor.SRGB8(red: 0x20, green: 0x20, blue: 0x1F)
        )
        #expect(
            OFJColor.harvestDarkCardRGB
                == OFJColor.SRGB8(red: 0x2A, green: 0x2A, blue: 0x28)
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
