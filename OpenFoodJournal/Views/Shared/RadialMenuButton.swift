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

    // Glass morphing namespace — ties option circles to the plus button
    // so they morph in/out of it on open/close.
    @Namespace private var glassNamespace

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
        ZStack(alignment: .bottom) {
            // ── Dismiss layer ────────────────────────────────────────────────
            // When the menu is open, a full-screen transparent tap target sits
            // behind the glass container. Tapping anywhere outside the option
            // bubbles or plus button closes the menu — matching the "tap outside
            // to dismiss" UX pattern users expect from modal overlays.
            if isOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { close() }
            }

            // GlassEffectContainer gives all glass shapes a shared sampling region.
            // Option circles only exist in the hierarchy when open — this prevents
            // glass shapes from overlapping the plus button when closed, which
            // causes the glass renderer to blur icon content.
            GlassEffectContainer(spacing: 16) {
                ZStack {
                    if isOpen {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let angle = angleForIndex(index, total: items.count)
                            let position = positionForAngle(angle)
                            let isHighlighted = highlightedID == item.id

                            optionBubble(item: item, isHighlighted: isHighlighted)
                                .offset(x: position.x, y: position.y)
                                .glassEffectID(item.id, in: glassNamespace)
                                .glassEffectTransition(.matchedGeometry)
                                .animation(.spring(duration: 0.2), value: isHighlighted)
                                // Direct tap on a bubble — same effect as dragging to it.
                                // The dismiss layer is behind the GlassEffectContainer, so
                                // taps on bubbles are captured here first and never reach
                                // the dismiss layer.
                                .onTapGesture {
                                    close()
                                    // Small delay lets the spring close animation start
                                    // before presenting the sheet.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        item.action()
                                    }
                                }
                        }
                    }

                    // The central plus button — the morph target for option circles
                    plusButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 24)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: isOpen)
    }

    // MARK: - Plus Button

    /// The main circular plus button. Tap to toggle, or drag to interact with options.
    private var plusButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(isOpen ? 45 : 0))
            .animation(.spring(duration: 0.3), value: isOpen)
            .frame(width: plusSize, height: plusSize)
            // Expand the tappable/draggable area beyond the visible glass circle
            // so near-miss touches still hit the button instead of scrolling the
            // List behind it. 20pt padding on each side → 104×104pt hit target.
            .contentShape(Circle().inset(by: -20))
            .glassEffect(in: .circle)
            .glassEffectID("plus", in: glassNamespace)
            .offset(dragOffset)
            .gesture(dragGesture)
            .simultaneousGesture(tapGesture)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: isOpen)
            .sensoryFeedback(.selection, trigger: highlightedID)
    }

    // MARK: - Option Bubble

    /// A single option circle with icon and label.
    /// Only rendered when the menu is open, so glass never overlaps the plus button at rest.
    private func optionBubble(item: RadialMenuItem, isHighlighted: Bool) -> some View {
        let size = isHighlighted ? optionSize * 1.15 : optionSize

        return VStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isHighlighted ? item.color : .primary)
                .frame(width: size, height: size)
                .glassEffect(
                    isHighlighted
                        ? .regular.tint(item.color.opacity(0.35))
                        : .regular,
                    in: .circle
                )
                .frame(width: optionSize * 1.15, height: optionSize * 1.15) // ← layout never changes

            Text(item.label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isHighlighted ? item.color : .secondary)
        }
        .animation(.spring(duration: 0.2), value: isHighlighted)
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
