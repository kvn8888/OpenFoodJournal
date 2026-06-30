// OpenFoodJournal — SavedFoodRowView
// A compact row displaying a saved food's name, key macros, and origin badge.
// Used in the FoodBankView list. Designed for quick scanning of saved foods.
// AGPL-3.0 License

import SwiftUI
import UIKit

struct SavedFoodRowView: View {
    // The saved food item to display in this row
    let food: SavedFood
    @AppStorage(FoodBankEmojiSettings.useGeneratedIconImagesKey) private var useGeneratedIconImages = false
    @State private var generatedIconAnimationTrigger = 0

    var body: some View {
        HStack(spacing: 12) {
            // ── Left: Emoji when assigned, otherwise the existing calorie/type badge ──
            VStack(alignment: .center, spacing: 2) {
                if useGeneratedIconImages {
                    if let data = food.generatedIconImageData,
                       let image = UIImage(data: data) {
                        GeneratedFoodIconImage(
                            image: image,
                            animationTrigger: generatedIconAnimationTrigger
                        )
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                    } else {
                        Image(systemName: "photo.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(
                                width: FoodIconMetrics.imageSize,
                                height: FoodIconMetrics.imageSize
                            )
                    }
                    Text("\(Int(food.calories)) cal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else if let emoji = food.normalizedEmoji {
                    Text(emoji)
                        .font(.title3)
                    Text("\(Int(food.calories)) cal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else if food.kind == .calculator {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(.teal)
                    Text("\(food.calculatorIngredients.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(food.calories))")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("cal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: FoodIconMetrics.columnWidth)

            // ── Center: Food name + serving info ──
            VStack(alignment: .leading, spacing: 2) {
                // Show brand above food name if available
                if let brand = food.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(food.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if food.kind == .calculator {
                    Label("Calculator · \(food.calculatorIngredients.count) ingredient\(food.calculatorIngredients.count == 1 ? "" : "s")", systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if food.kind == .composite {
                    Label("Composite", systemImage: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Show serving size if available
                if let serving = food.servingSize {
                    Text(serving)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ── Right: Macro chips matching the journal's EntryRowView ──
            if food.kind == .calculator {
                Text("\(food.calculatorIngredients.count) item\(food.calculatorIngredients.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    MacroChip(value: food.protein, color: .blue, label: "P")
                    MacroChip(value: food.carbs, color: .green, label: "C")
                    MacroChip(value: food.fat, color: .yellow, label: "F")
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.smooth(duration: 0.2), value: food.hasGeneratedFoodIconImage)
        .onChange(of: food.generatedIconImageUpdatedAt) { _, newValue in
            guard useGeneratedIconImages,
                  newValue != nil,
                  food.hasGeneratedFoodIconImage else { return }

            generatedIconAnimationTrigger += 1
        }
        // Ensures the full row area is tappable/swipeable, even when brand is
        // absent and the row is shorter — prevents swipe gesture lag on compact rows
        .contentShape(Rectangle())
    }
}

private enum FoodIconMetrics {
    static let imageSize: CGFloat = 51
    static let columnWidth: CGFloat = 58
    static let shineWidth: CGFloat = imageSize * 0.3
    static let shineHeight: CGFloat = imageSize * 1.7
    static let shineTravel: CGFloat = imageSize
    static let sparkleSize: CGFloat = 18
    static let sparkleOffset: CGFloat = imageSize * 0.15
}

private struct GeneratedFoodIconImage: View {
    let image: UIImage
    let animationTrigger: Int

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(
                width: FoodIconMetrics.imageSize,
                height: FoodIconMetrics.imageSize
            )
            .clipShape(Circle())
            .overlay {
                FoodIconShine(animationTrigger: animationTrigger)
                    .clipShape(Circle())
            }
            .overlay(alignment: .topTrailing) {
                FoodIconSparklePulse(animationTrigger: animationTrigger)
                    .offset(
                        x: FoodIconMetrics.sparkleOffset,
                        y: -FoodIconMetrics.sparkleOffset
                    )
            }
            .keyframeAnimator(
                initialValue: FoodIconRevealValues(),
                trigger: animationTrigger
            ) { content, value in
                content
                    .scaleEffect(value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.1, duration: 0.14)
                    CubicKeyframe(0.98, duration: 0.12)
                    CubicKeyframe(1.0, duration: 0.14)
                }
            }
    }
}

private struct FoodIconRevealValues {
    var scale: CGFloat = 1
}

private struct FoodIconShine: View {
    let animationTrigger: Int

    var body: some View {
        Color.clear
            .overlay {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.72),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(
                        width: FoodIconMetrics.shineWidth,
                        height: FoodIconMetrics.shineHeight
                    )
                    .rotationEffect(.degrees(28))
                    .keyframeAnimator(
                        initialValue: FoodIconShineValues(),
                        trigger: animationTrigger
                    ) { content, value in
                        content
                            .opacity(value.opacity)
                            .offset(x: value.xOffset)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.04)
                            CubicKeyframe(0.9, duration: 0.12)
                            CubicKeyframe(0, duration: 0.26)
                        }
                        KeyframeTrack(\.xOffset) {
                            LinearKeyframe(-FoodIconMetrics.shineTravel, duration: 0.04)
                            CubicKeyframe(FoodIconMetrics.shineTravel, duration: 0.38)
                        }
                    }
            }
    }
}

private struct FoodIconShineValues {
    var opacity: Double = 0
    var xOffset: CGFloat = -FoodIconMetrics.shineTravel
}

private struct FoodIconSparklePulse: View {
    let animationTrigger: Int

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: FoodIconMetrics.sparkleSize, weight: .semibold))
            .foregroundStyle(.yellow, .orange)
            .shadow(color: .orange.opacity(0.35), radius: 2)
            .frame(
                width: FoodIconMetrics.sparkleSize,
                height: FoodIconMetrics.sparkleSize
            )
            .accessibilityHidden(true)
            .keyframeAnimator(
                initialValue: FoodIconSparkleValues(),
                trigger: animationTrigger
            ) { content, value in
                content
                    .opacity(value.opacity)
                    .scaleEffect(value.scale)
                    .offset(y: value.yOffset)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0.03)
                    CubicKeyframe(1, duration: 0.12)
                    CubicKeyframe(0, duration: 0.34)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.7, duration: 0.03)
                    CubicKeyframe(1.18, duration: 0.18)
                    CubicKeyframe(0.85, duration: 0.28)
                }
                KeyframeTrack(\.yOffset) {
                    LinearKeyframe(2, duration: 0.03)
                    CubicKeyframe(-4, duration: 0.46)
                }
            }
    }
}

private struct FoodIconSparkleValues {
    var opacity: Double = 0
    var scale: CGFloat = 0.7
    var yOffset: CGFloat = 2
}
