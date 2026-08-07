// OpenFoodJournal — scan camera controls
// AGPL-3.0 License

import SwiftUI

/// The three capture modes shown directly on the live camera.
///
/// Keeping the display contract separate from `ScanCaptureView` makes the mode
/// order and labels independently testable without launching AVFoundation.
struct ScanCameraModeDescriptor: Identifiable, Equatable {
    let mode: ScanMode
    let title: String
    let symbol: String

    var id: String { mode.rawValue }

    static let supported: [ScanCameraModeDescriptor] = [
        ScanCameraModeDescriptor(
            mode: .foodPhoto,
            title: "Scan Food",
            symbol: "viewfinder"
        ),
        ScanCameraModeDescriptor(
            mode: .barcode,
            title: "Barcode",
            symbol: "barcode.viewfinder"
        ),
        ScanCameraModeDescriptor(
            mode: .label,
            title: "Food Label",
            symbol: "doc.text.viewfinder"
        ),
    ]
}

struct ScanCameraControls: View {
    @Binding var mode: ScanMode

    let zoomFactor: Double
    let zoomConfiguration: CameraZoomConfiguration
    let torchOn: Bool
    let torchAvailable: Bool
    let canRetry: Bool
    let isBusy: Bool
    let onExit: () -> Void
    let onRetry: () -> Void
    let onZoom: (Double) -> Void
    let onTorch: () -> Void
    let onCapture: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            bottomLegibilityGradient

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: OFJSpace.s20)

                bottomControls
            }
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: OFJSpace.s12) {
            HStack {
                CameraGlassIconButton(
                    symbol: "xmark",
                    accessibilityLabel: "Exit camera",
                    action: onExit
                )

                Spacer()

                if canRetry {
                    CameraGlassIconButton(
                        symbol: "arrow.clockwise",
                        accessibilityLabel: "Retry last scan",
                        isDisabled: isBusy,
                        action: onRetry
                    )
                } else {
                    Color.clear
                        .frame(
                            width: OFJLayout.cameraTopControlSize,
                            height: OFJLayout.cameraTopControlSize
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, OFJSpace.s16)
        .padding(.top, OFJSpace.s8)
    }

    private var bottomControls: some View {
        GlassEffectContainer(spacing: OFJSpace.s12) {
            VStack(spacing: OFJSpace.s12) {
                zoomControl
                modeSelector
                captureBar
            }
        }
        .padding(.horizontal, OFJSpace.s16)
        .padding(.bottom, OFJSpace.s24)
    }

    private var zoomControl: some View {
        VStack(spacing: OFJSpace.s3) {
            Text(zoomConfiguration.displayLabel(for: zoomFactor))
                .font(OFJType.cameraZoom)
                .monospacedDigit()
                .ofjNumericTextTransition(
                    value: zoomConfiguration.displayFactor(for: zoomFactor)
                )

            Slider(
                value: Binding(
                    get: { zoomFactor },
                    set: onZoom
                ),
                in: zoomConfiguration.range
            ) {
                Text("Zoom")
            } minimumValueLabel: {
                Image(systemName: "minus.magnifyingglass")
            } maximumValueLabel: {
                Image(systemName: "plus.magnifyingglass")
            }
            .sliderNeutralValue(zoomConfiguration.neutralFactor)
            .tint(.white)
            .disabled(!zoomConfiguration.isAdjustable)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, OFJSpace.s12)
        .frame(
            maxWidth: OFJLayout.cameraZoomControlWidth,
            minHeight: OFJLayout.cameraZoomControlHeight
        )
        .glassEffect(
            .regular.tint(.black.opacity(0.42)).interactive(),
            in: .capsule
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera zoom")
        .accessibilityValue(zoomConfiguration.displayLabel(for: zoomFactor))
    }

    private var modeSelector: some View {
        HStack(spacing: OFJSpace.s8) {
            ForEach(ScanCameraModeDescriptor.supported) { descriptor in
                CameraModeButton(
                    descriptor: descriptor,
                    isSelected: mode == descriptor.mode
                ) {
                    withAnimation(OFJMotion.quickSpring) {
                        mode = descriptor.mode
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan modes")
    }

    private var captureBar: some View {
        HStack {
            CameraGlassIconButton(
                symbol: torchOn ? "bolt.fill" : "bolt.slash.fill",
                accessibilityLabel: torchOn ? "Turn torch off" : "Turn torch on",
                size: OFJLayout.cameraUtilityControlSize,
                isSelected: torchOn,
                isDisabled: !torchAvailable,
                action: onTorch
            )

            Spacer()

            CaptureButton(isScanning: isBusy, action: onCapture)

            Spacer()

            CameraGlassIconButton(
                symbol: "photo.on.rectangle",
                accessibilityLabel: "Choose from photo library",
                size: OFJLayout.cameraUtilityControlSize,
                action: onLibrary
            )
        }
        .padding(.horizontal, OFJSpace.s16)
    }

    private var bottomLegibilityGradient: some View {
        LinearGradient(
            colors: [
                .clear,
                .black.opacity(0.22),
                .black.opacity(0.72),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 360)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CameraModeButton: View {
    let descriptor: ScanCameraModeDescriptor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: OFJSpace.s6) {
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 20, weight: .semibold))

                Text(descriptor.title)
                    .font(OFJType.cameraMode)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: OFJLayout.cameraModeControlHeight)
            .contentShape(.rect(cornerRadius: OFJRadius.compactCard))
            .glassEffect(
                .regular
                    .tint(
                        isSelected
                            ? .white.opacity(0.28)
                            : .black.opacity(0.48)
                    )
                    .interactive(),
                in: .rect(cornerRadius: OFJRadius.compactCard)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptor.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CameraGlassIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var size: CGFloat = OFJLayout.cameraTopControlSize
    var isSelected = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .glassEffect(
                    .regular
                        .tint(
                            isSelected
                                ? .white.opacity(0.30)
                                : .black.opacity(0.48)
                        )
                        .interactive(),
                    in: .circle
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CaptureButton: View {
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.34))
                    .frame(
                        width: OFJLayout.cameraShutterSize,
                        height: OFJLayout.cameraShutterSize
                    )

                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(
                        width: OFJLayout.cameraShutterSize,
                        height: OFJLayout.cameraShutterSize
                    )

                if isScanning {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(
                            width: OFJLayout.cameraShutterSize - 14,
                            height: OFJLayout.cameraShutterSize - 14
                        )
                }
            }
        }
        .disabled(isScanning)
        .buttonStyle(.plain)
        .accessibilityLabel(isScanning ? "Processing…" : "Capture photo")
    }
}

#if DEBUG
private struct ScanCameraControlsPreview: View {
    @State private var mode = ScanMode.foodPhoto
    @State private var zoom = 2.0
    @State private var torchOn = false

    private let zoomConfiguration = CameraZoomConfiguration(
        range: 1.0...10.0,
        displayMultiplier: 0.5
    )

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.green.opacity(0.55), .brown, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScanCameraControls(
                mode: $mode,
                zoomFactor: zoom,
                zoomConfiguration: zoomConfiguration,
                torchOn: torchOn,
                torchAvailable: true,
                canRetry: true,
                isBusy: false,
                onExit: {},
                onRetry: {},
                onZoom: { zoom = $0 },
                onTorch: { torchOn.toggle() },
                onCapture: {},
                onLibrary: {}
            )
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Scan Camera Controls") {
    ScanCameraControlsPreview()
}

#Preview("Scan Camera Controls · Accessibility Type") {
    ScanCameraControlsPreview()
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
