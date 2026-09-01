// OpenFoodJournal — Food Bank Emoji Settings
// AGPL-3.0 License

import Foundation

enum FoodBankEmojiSettings {
    static let autoGenerateKey = "foodBank.autoGenerateEmojis"
    static let useGeneratedIconImagesKey = "foodBank.useGeneratedIconImages"
}

/// Domain boundary used by Food Bank mutations to request image generation
/// without coupling persistence callers to Gemini or `ScanService`.
@MainActor
protocol SavedFoodImageGenerationQueuing: AnyObject {
    func enqueueFoodIconImageGeneration(for foodID: UUID)
}

/// Pure policy kept separate from the service so the BYOK opt-in behavior is
/// explicit and can be verified without making a provider request.
enum FoodIconGenerationPolicy {
    static func shouldAutomaticallyGenerate(
        isGenerationEnabled: Bool,
        usesGeneratedImages: Bool,
        needsGeneratedImage: Bool
    ) -> Bool {
        isGenerationEnabled && usesGeneratedImages && needsGeneratedImage
    }
}

/// FIFO bookkeeping for generated Food Bank images. It deduplicates both
/// pending work and the item currently in flight, preventing rapid saves from
/// either dropping or double-generating a food.
struct FoodIconGenerationQueue {
    private(set) var pendingFoodIDs: [UUID] = []
    private(set) var activeFoodID: UUID?

    var pendingCount: Int { pendingFoodIDs.count }
    var outstandingCount: Int { pendingFoodIDs.count + (activeFoodID == nil ? 0 : 1) }
    var isEmpty: Bool { outstandingCount == 0 }

    @discardableResult
    mutating func enqueue(_ foodID: UUID) -> Bool {
        guard activeFoodID != foodID, !pendingFoodIDs.contains(foodID) else {
            return false
        }
        pendingFoodIDs.append(foodID)
        return true
    }

    mutating func beginNext() -> UUID? {
        guard activeFoodID == nil, !pendingFoodIDs.isEmpty else { return nil }
        let foodID = pendingFoodIDs.removeFirst()
        activeFoodID = foodID
        return foodID
    }

    mutating func finishActive() {
        activeFoodID = nil
    }
}
