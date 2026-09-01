import SwiftUI
import SwiftData
import UIKit

/// Observe only linked foods, including a copy explicitly saved from this entry.
/// Never guess by name and never start generation from a view or a scroll event.
struct JournalEntryFoodImage: View {
    let entryID: UUID
    let savedFoodID: UUID?
    @Query private var candidates: [SavedFood]

    init(entryID: UUID, savedFoodID: UUID?) {
        self.entryID = entryID
        self.savedFoodID = savedFoodID
        _candidates = Query(filter: JournalFoodImageLookup.predicate(entryID: entryID, savedFoodID: savedFoodID))
    }

    var body: some View {
        Group {
            if let food = JournalFoodImageLookup.food(in: candidates, entryID: entryID, savedFoodID: savedFoodID),
               let bytes = food.generatedIconImageData, let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(.secondary.opacity(0.08))
                    .overlay {
                        Image(systemName: "photo").font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: FoodIconMetrics.imageSize, height: FoodIconMetrics.imageSize)
        .clipShape(.circle)
        .frame(width: FoodIconMetrics.columnWidth)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

enum JournalFoodImageLookup {
    static func predicate(entryID: UUID, savedFoodID: UUID?) -> Predicate<SavedFood> {
        if let savedFoodID {
            return #Predicate<SavedFood> { food in
                food.id == savedFoodID || food.sourceJournalEntryID == entryID
            }
        }
        return #Predicate<SavedFood> { food in food.sourceJournalEntryID == entryID }
    }

    /// Original linkage wins when it has an image. A later saved snapshot is a
    /// valid fallback, including archived foods; this never changes nutrition.
    static func food(in candidates: [SavedFood], entryID: UUID, savedFoodID: UUID?) -> SavedFood? {
        let withImages = candidates.filter { !($0.generatedIconImageData?.isEmpty ?? true) }
        if let savedFoodID, let linked = withImages.first(where: { $0.id == savedFoodID }) {
            return linked
        }
        return withImages.filter { $0.sourceJournalEntryID == entryID }
            .sorted { $0.id.uuidString < $1.id.uuidString }.first
    }
}
