// OpenFoodJournal — RadialMenuButton
// A floating "+" button that reveals action options in an upper semicircle.
// The user long-presses or taps to reveal options, then drags toward one to select.
// Options fan out radially above the plus button like a floral pattern.
// AGPL-3.0 License

import SwiftUI

// MARK: - Menu Item Model

/// Describes one action option in the radial menu.
struct RadialMenuItem: Identifiable {
    let id: String
    let label: String
    let icon: String          // SF Symbol name
    let color: Color          // Tint color for the option circle
    let action: () -> Void
}

// MARK: - RadialMenuButton

/// A floating "+" button that, when activated, fans out option icons in an
/// upper semicircle. Dragging toward an option highlights it; releasing triggers it.
///
/// Layout: options spread evenly along an arc from 210° to 330° (clock positions
/// roughly 7 to 11), placing them above and around the plus button.
struct RadialMenuButton: View {
    /// The menu items to display in the semicircle
    let items: [RadialMenuItem]

    // ── State ─────────────────────────────────────────────────────
    @State private var isOpen = false           // Whether the menu is expanded
    @State private var dragOffset: CGSize = .zero  // Current drag translation
    @State private var highlightedID: String?   // Which item is under the drag
    @State private var didTrigger = false        // Prevents double-fire on release

    // ── Layout Constants ──────────────────────────────────────────
    /// Radius of the semicircle arc from center of plus button to center of options
    private let arcRadius: CGFloat = 110

    /// Size of each option circle
    private let optionSize: CGFloat = 60

    /// Size of the central plus button
    private let plusSize: CGFloat = 64

    /// How close the drag needs to be to an option to highlight it
    private let activationRadius: CGFloat = 44

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dim overlay when menu is open (tappable to dismiss)
            if isOpen {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
            }

            // The menu items, positioned along the arc
            ZStack {
                // Each item gets an angle along the upper semicircle
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = angleForIndex(index, total: items.count)
                    let position = positionForAngle(angle)
                    let isHighlighted = highlightedID == item.id

                    optionBubble(item: item, isHighlighted: isHighlighted)
                        .offset(x: isOpen ? position.x : 0,
                                y: isOpen ? position.y : 0)
                        .scaleEffect(isOpen ? (isHighlighted ? 1.15 : 1.0) : 0.3)
                        .opacity(isOpen ? 1.0 : 0.0)
                        .animation(
                            .spring(duration: 0.4, bounce: 0.3)
                            .delay(isOpen ? Double(index) * 0.04 : 0),
                            value: isOpen
                        )
                        .animation(.spring(duration: 0.2), value: isHighlighted)
                }
            }

            // The central plus button
            plusButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 24)
    }

    // MARK: - Plus Button

    /// The main circular plus button. Tap to toggle, or drag to interact with options.
    private var plusButton: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(isOpen ? 45 : 0))
            }
            .frame(width: plusSize, height: plusSize)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            .offset(dragOffset)
            .gesture(dragGesture)
            .simultaneousGesture(tapGesture)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: isOpen)
            .sensoryFeedback(.selection, trigger: highlightedID)
    }

    // MARK: - Option Bubble

    /// A single option circle with icon and label.
    private func optionBubble(item: RadialMenuItem, isHighlighted: Bool) -> some View {
        VStack(spacing: 6) {
            // Icon circle
            Circle()
                .fill(isHighlighted ? item.color : Color(.systemGray5))
                .overlay {
                    Image(systemName: item.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isHighlighted ? .white : .primary)
                }
                .frame(width: optionSize, height: optionSize)
                .shadow(color: isHighlighted ? item.color.opacity(0.4) : .clear,
                        radius: 12, y: 2)

            // Label (only visible when menu is open)
            Text(item.label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isHighlighted ? item.color : .secondary)
        }
    }

    // MARK: - Gestures

    /// Tap gesture: toggles menu open/closed
    private var tapGesture: some Gesture {
        TapGesture()
            .onEnded {
                if isOpen {
                    close()
                } else {
                    open()
                }
            }
    }

    /// Drag gesture: opens menu on drag start, highlights nearest option,
    /// triggers action on release
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isOpen {
                    open()
                    didTrigger = false
                }

                // Update drag offset (subtle movement of plus button)
                dragOffset = CGSize(
                    width: value.translation.width * 0.15,
                    height: value.translation.height * 0.15
                )

                // Find which option the drag is closest to
                highlightedID = closestItem(to: value.translation)?.id
            }
            .onEnded { value in
                // If an option is highlighted, trigger its action
                if let highlighted = highlightedID,
                   let item = items.first(where: { $0.id == highlighted }),
                   !didTrigger {
                    didTrigger = true
                    close()
                    // Small delay so the close animation plays before the sheet opens
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        item.action()
                    }
                } else {
                    // No option selected — just close
                    withAnimation(.spring(duration: 0.3)) {
                        dragOffset = .zero
                    }
                }
                highlightedID = nil
            }
    }

    // MARK: - Geometry Helpers

    /// Calculate the angle for a given item index.
    /// Items spread evenly across an arc from 210° to 330° (upper semicircle).
    /// 270° is straight up.
    private func angleForIndex(_ index: Int, total: Int) -> Double {
        guard total > 1 else { return 270.0 } // Single item goes straight up

        let startAngle = 210.0   // Lower-left of arc
        let endAngle = 330.0     // Lower-right of arc
        let step = (endAngle - startAngle) / Double(total - 1)
        return startAngle + step * Double(index)
    }

    /// Convert a polar angle (in degrees) to a cartesian offset from the plus button center.
    /// Note: 270° = straight up, 180° = left, 0°/360° = right.
    private func positionForAngle(_ degrees: Double) -> CGPoint {
        let radians = CGFloat(degrees * .pi / 180)
        return CGPoint(
            x: arcRadius * CoreGraphics.cos(radians),
            y: arcRadius * CoreGraphics.sin(radians)
        )
    }

    /// Find which menu item the drag translation is closest to,
    /// within the activation radius.
    private func closestItem(to translation: CGSize) -> RadialMenuItem? {
        var best: (item: RadialMenuItem, dist: CGFloat)?

        for (index, item) in items.enumerated() {
            let angle = angleForIndex(index, total: items.count)
            let pos = positionForAngle(angle)

            // Distance from drag point to option center
            let dx = translation.width - pos.x
            let dy = translation.height - pos.y
            let dist = sqrt(dx * dx + dy * dy)

            if dist < activationRadius {
                if best == nil || dist < best!.dist {
                    best = (item, dist)
                }
            }
        }
        return best?.item
    }

    // MARK: - Open / Close

    private func open() {
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
            isOpen = true
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.3)) {
            isOpen = false
            dragOffset = .zero
        }
    }
}
