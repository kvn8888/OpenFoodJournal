// OpenFoodJournal — RadialMenuDemo
// An animated tutorial that shows users how to press-and-drag the "+" button
// to quickly select an action from the radial menu. Used in onboarding and
// "What's New" screens to teach the drag-to-select gesture.
//
// The animation loops forever and shows:
// 1. A finger pressing the "+" button
// 2. The radial options fanning out (Food Bank, Containers, Manual, Scan)
// 3. The finger dragging toward the "Scan" option
// 4. The Scan option highlighting as the finger approaches
// 5. The finger releasing and the menu closing
//
// All animation is driven by a simple phase state machine — no external
// dependencies (no Lottie, no Rive). Pure SwiftUI.

import SwiftUI

/// A self-contained animation view that demonstrates the radial menu's
/// press-and-drag gesture. Loops automatically and requires no user interaction.
struct RadialMenuDemo: View {

    // MARK: - Animation Phases

    /// Each phase represents a distinct moment in the demo animation.
    /// The animation state machine advances through these sequentially.
    private enum Phase: CaseIterable {
        case idle           // Plus button visible, finger off-screen
        case fingerAppears  // Finger slides into view, approaching the button
        case pressing       // Finger presses the button (scale-down effect)
        case menuOpen       // Radial options fan out, finger starts dragging
        case dragging       // Finger moves toward the Scan option
        case highlighted    // Scan option is highlighted (finger is over it)
        case released       // Finger lifts, action triggers, menu closes
        case pause          // Brief pause before looping
    }

    /// The current phase of the animation — drives all visual changes.
    @State private var phase: Phase = .idle

    // MARK: - Layout Constants

    /// Radius of the demo's radial arc (smaller than the real menu for the demo frame)
    private let arcRadius: CGFloat = 80
    /// Size of each option circle in the demo
    private let optionSize: CGFloat = 44
    /// Size of the central plus button in the demo
    private let plusSize: CGFloat = 52

    // MARK: - Menu Item Data

    /// Simplified representations of the real radial menu items.
    /// These match the actual items in DailyLogView.
    private struct DemoItem {
        let icon: String
        let label: String
        let color: Color
    }

    /// The four radial menu items in the same order as the real app.
    /// Index 0 = 210° (lower-left), index 3 = 330° (lower-right).
    private let items: [DemoItem] = [
        DemoItem(icon: "refrigerator", label: "Food Bank", color: .purple),
        DemoItem(icon: "scalemass", label: "Containers", color: .orange),
        DemoItem(icon: "pencil", label: "Manual", color: .green),
        DemoItem(icon: "camera.fill", label: "Scan", color: .blue),
    ]

    /// Index of the item the finger drags toward (Scan = index 3)
    private let targetIndex = 3

    // MARK: - Body

    var body: some View {
        ZStack {
            // The demo menu visualization
            menuVisualization

            // The animated finger/hand cursor
            fingerCursor
        }
        // Fixed frame so the demo has consistent sizing in any container
        .frame(width: 260, height: 260)
        .onAppear { startAnimation() }
    }

    // MARK: - Menu Visualization

    /// Renders the plus button and radial option circles.
    /// Options only appear when the phase is past `menuOpen`.
    private var menuVisualization: some View {
        ZStack {
            // Option circles — only shown when menu is "open"
            if showOptions {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let angle = angleForIndex(index)
                    let pos = positionForAngle(angle)
                    let isTarget = index == targetIndex && isHighlightPhase

                    optionCircle(item: item, isHighlighted: isTarget)
                        .offset(x: pos.x, y: pos.y)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            // Plus button (centered)
            plusButtonView
        }
        // Shift everything up slightly so the plus button sits at the bottom
        // of the demo frame, with options arcing above it
        .offset(y: 60)
    }

    /// The central "+" circle that's always visible.
    private var plusButtonView: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: plusSize, height: plusSize)

            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                // Rotate 45° when open (becomes an "×" like the real button)
                .rotationEffect(.degrees(showOptions ? 45 : 0))
        }
        // Subtle scale-down while finger is pressed (same duration as the real button)
        .scaleEffect(fingerIsPressed ? 0.9 : 1.0)
        // Follow the finger slightly during drag (mimics translation * 0.15)
        .offset(x: plusButtonFollowOffset.x, y: plusButtonFollowOffset.y)
    }

    // MARK: - Option Circle

    /// A single option circle with icon and label, matching the real app's style.
    private func optionCircle(item: DemoItem, isHighlighted: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isHighlighted
                          ? item.color.opacity(0.25)
                          : Color(.systemGray5))
                    .frame(
                        width: isHighlighted ? optionSize * 1.15 : optionSize,
                        height: isHighlighted ? optionSize * 1.15 : optionSize
                    )

                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isHighlighted ? item.color : .primary)
            }

            Text(item.label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isHighlighted ? item.color : .secondary)
        }
        .animation(.spring(duration: 0.2), value: isHighlighted)
    }

    // MARK: - Finger Cursor

    /// The animated hand/finger icon that demonstrates the gesture.
    private var fingerCursor: some View {
        Image(systemName: "hand.point.up.fill")
            .font(.system(size: 32))
            .foregroundStyle(.primary.opacity(0.7))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .offset(x: fingerOffset.x, y: fingerOffset.y)
            .opacity(fingerOpacity)
            // Stay "pressed" (scaled down) for the entire press-through-drag sequence
            .scaleEffect(fingerIsPressed ? 0.85 : 1.0)
    }

    // MARK: - Computed Properties

    /// Whether the radial options should be visible (menu is open).
    private var showOptions: Bool {
        switch phase {
        case .menuOpen, .dragging, .highlighted: return true
        default: return false
        }
    }

    /// Whether we're in a phase where the target should highlight.
    private var isHighlightPhase: Bool {
        phase == .highlighted
    }

    /// Whether the finger should appear "pressed down" — stays pressed
    /// from the initial press through the entire drag until release.
    private var fingerIsPressed: Bool {
        switch phase {
        case .pressing, .menuOpen, .dragging, .highlighted: return true
        default: return false
        }
    }

    /// How much the plus button should follow the finger during drag.
    /// Mimics the real RadialMenuButton's `translation * 0.15` effect.
    private var plusButtonFollowOffset: CGPoint {
        switch phase {
        case .dragging:
            let targetPos = positionForAngle(angleForIndex(targetIndex))
            return CGPoint(x: targetPos.x * 0.5 * 0.15, y: targetPos.y * 0.5 * 0.15)
        case .highlighted:
            let targetPos = positionForAngle(angleForIndex(targetIndex))
            return CGPoint(x: targetPos.x * 0.15, y: targetPos.y * 0.15)
        default:
            return .zero
        }
    }

    /// The finger's position at each phase of the animation.
    private var fingerOffset: CGPoint {
        switch phase {
        case .idle:
            // Off-screen, below the demo
            return CGPoint(x: 20, y: 200)
        case .fingerAppears:
            // Approaching the plus button (which is at y: 60 offset)
            return CGPoint(x: 10, y: 80)
        case .pressing:
            // On top of the plus button
            return CGPoint(x: 5, y: 75)
        case .menuOpen:
            // Still on the button, menu just opened
            return CGPoint(x: 5, y: 75)
        case .dragging:
            // Midway between button and Scan option (330° = upper-right)
            let targetPos = positionForAngle(angleForIndex(targetIndex))
            return CGPoint(
                x: targetPos.x * 0.5 + 5,
                y: 60 + targetPos.y * 0.5 + 15
            )
        case .highlighted:
            // On top of the Scan option
            let targetPos = positionForAngle(angleForIndex(targetIndex))
            return CGPoint(
                x: targetPos.x + 5,
                y: 60 + targetPos.y + 15
            )
        case .released, .pause:
            // Pull away slightly (finger lifts)
            let targetPos = positionForAngle(angleForIndex(targetIndex))
            return CGPoint(
                x: targetPos.x + 20,
                y: 60 + targetPos.y - 20
            )
        }
    }

    /// Finger visibility at each phase.
    private var fingerOpacity: Double {
        switch phase {
        case .idle: return 0
        case .fingerAppears: return 0.8
        case .pressing, .menuOpen, .dragging, .highlighted: return 0.8
        case .released: return 0.4
        case .pause: return 0
        }
    }

    // MARK: - Geometry Helpers

    /// Calculate the angle for a menu item index (same math as the real RadialMenuButton).
    /// 4 items spread from 210° to 330°.
    private func angleForIndex(_ index: Int) -> Double {
        let startAngle = 210.0
        let endAngle = 330.0
        let step = (endAngle - startAngle) / Double(items.count - 1)
        return startAngle + step * Double(index)
    }

    /// Convert a polar angle to a cartesian offset from center.
    private func positionForAngle(_ degrees: Double) -> CGPoint {
        let radians = CGFloat(degrees * .pi / 180)
        return CGPoint(
            x: arcRadius * cos(radians),
            y: arcRadius * sin(radians)
        )
    }

    // MARK: - Animation Driver

    /// Runs the animation loop by advancing through phases with timed delays.
    private func startAnimation() {
        Task {
            while !Task.isCancelled {
                // Phase 1: Idle (brief pause at start)
                phase = .idle
                try? await Task.sleep(for: .seconds(0.8))

                // Phase 2: Finger slides into view
                withAnimation(.easeOut(duration: 0.5)) {
                    phase = .fingerAppears
                }
                try? await Task.sleep(for: .seconds(0.6))

                // Phase 3: Press — finger pushes down on button
                withAnimation(.easeInOut(duration: 0.15)) {
                    phase = .pressing
                }
                try? await Task.sleep(for: .seconds(0.2))

                // Phase 4: Menu opens — options fan out
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                    phase = .menuOpen
                }
                try? await Task.sleep(for: .seconds(0.5))

                // Phase 5: Drag toward Scan option
                withAnimation(.easeInOut(duration: 0.6)) {
                    phase = .dragging
                }
                try? await Task.sleep(for: .seconds(0.7))

                // Phase 6: Arrive at Scan — highlight it
                withAnimation(.easeOut(duration: 0.3)) {
                    phase = .highlighted
                }
                try? await Task.sleep(for: .seconds(0.6))

                // Phase 7: Release — finger lifts, menu closes
                withAnimation(.easeOut(duration: 0.3)) {
                    phase = .released
                }
                try? await Task.sleep(for: .seconds(0.5))

                // Phase 8: Pause before looping
                withAnimation(.easeOut(duration: 0.3)) {
                    phase = .pause
                }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RadialMenuDemo()
        .padding()
        .background(Color(.systemGroupedBackground))
}
