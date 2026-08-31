import Foundation
import Testing
@testable import OpenFoodJournal

struct PinnedMicronutrientSettingsTests {
    @Test func decodeTreatsEmptyAndLegacyCommaListsAsPins() {
        #expect(PinnedMicronutrientSettings.decode("").isEmpty)
        #expect(PinnedMicronutrientSettings.decode("   ").isEmpty)
        #expect(PinnedMicronutrientSettings.decode("alcohol,fiber, alcohol") == ["alcohol", "fiber"])
    }

    @Test func jsonRoundTripKeepsPinOrderAndDropsBlanks() throws {
        let encoded = PinnedMicronutrientSettings.encode(["fiber", "", "alcohol", "fiber"])
        #expect(PinnedMicronutrientSettings.decode(encoded) == ["fiber", "alcohol"])
        #expect(PinnedMicronutrientSettings.decode("[\"vitamin_a\",\"sodium\"]") == ["vitamin_a", "sodium"])
    }

    @Test func pinAppendsAndUnpinRemovesWithoutLosingNeighbors() {
        let pinned = PinnedMicronutrientSettings.pin("alcohol", in: ["fiber"])
        #expect(pinned == ["fiber", "alcohol"])
        #expect(PinnedMicronutrientSettings.pin("fiber", in: pinned) == ["alcohol", "fiber"])
        #expect(PinnedMicronutrientSettings.unpin("fiber", from: pinned) == ["alcohol"])
        #expect(PinnedMicronutrientSettings.unpin("missing", from: pinned) == pinned)
        #expect(PinnedMicronutrientSettings.isPinned("alcohol", in: pinned))
        #expect(!PinnedMicronutrientSettings.isPinned("sodium", in: pinned))
    }

    @Test func userDefaultsRoundTripsPinnedIDs() throws {
        let suite = "PinnedMicronutrientSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PinnedMicronutrientSettings.ids(in: defaults).isEmpty)
        defaults.set(PinnedMicronutrientSettings.encode(["alcohol", "fiber"]), forKey: PinnedMicronutrientSettings.idsKey)
        #expect(PinnedMicronutrientSettings.ids(in: defaults) == ["alcohol", "fiber"])
    }

    @Test func appSettingsRecordRoundTripsPinsAndOlderBackupsStayEmpty() throws {
        let old = try JSONDecoder().decode(AppSettingsRecord.self, from: Data(#"{"useProModel":false,"offContributeEnabled":false}"#.utf8))
        #expect(old.pinnedMicronutrientIDs.isEmpty)

        let settings = AppSettingsRecord(
            useProModel: false,
            pinnedMicronutrientIDs: [" alcohol ", "fiber", "fiber"],
            offContributeEnabled: false
        )
        let decoded = try JSONDecoder().decode(AppSettingsRecord.self, from: JSONEncoder().encode(settings))
        #expect(decoded.pinnedMicronutrientIDs == ["alcohol", "fiber"])
    }
}
