// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import AVFoundation

struct ScanCaptureView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ScanMode = .label
    @State private var capturedEntry: NutritionEntry?
    @State private var cameraPermissionDenied = false

    // CameraController manages the AVCaptureSession lifetime
    @State private var camera = CameraController()

    var body: some View {
        ZStack {
            // Live camera preview — full screen
            if camera.isReady {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                if cameraPermissionDenied {
                    CameraPermissionView()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }

            // UI overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    // Mode toggle
                    GlassEffectContainer(spacing: 0) {
                        Picker("Scan mode", selection: $mode) {
                            Text("Label").tag(ScanMode.label)
                            Text("Photo").tag(ScanMode.foodPhoto)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    Spacer()

                    // Torch button
                    Button {
                        camera.toggleTorch()
                    } label: {
                        Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Mode hint
                Text(mode == .label
                     ? "Point at a nutrition facts label"
                     : "Point at your food for an estimate")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                    .padding(.bottom, 24)
                    .animation(.easeInOut, value: mode)

                // Capture button
                CaptureButton(isScanning: scanService.isScanning) {
                    Task { await capture() }
                }
                .padding(.bottom, 48)
            }

            // Error banner
            if let error = scanService.error {
                VStack {
                    Spacer()
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .glassEffect(.regular.tint(.red.opacity(0.4)), in: .rect(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                }
            }

            // Result card slides up from bottom
            if let entry = capturedEntry {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { /* intentionally blocks taps */ }

                VStack {
                    Spacer()
                    ScanResultCard(
                        entry: entry,
                        onConfirm: {
                            nutritionStore.log(entry, to: .now)

                            // Auto-save to Food Bank so scanned foods are reusable
                            let saved = SavedFood(from: entry)
                            nutritionStore.modelContext.insert(saved)
                            try? nutritionStore.modelContext.save()
                            let sync = nutritionStore.syncService
                            Task { try? await sync?.createFood(saved) }

                            dismiss()
                        },
                        onRetake: {
                            withAnimation(.spring(duration: 0.4)) {
                                capturedEntry = nil
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .transition(.opacity)
                .animation(.spring(duration: 0.4), value: capturedEntry != nil)
            }
        }
        .task {
            await camera.setup()
            if camera.permissionDenied {
                cameraPermissionDenied = true
            }
        }
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: - Capture

    private func capture() async {
        guard !scanService.isScanning else { return }

        let image = await camera.capturePhoto()
        guard let image else { return }

        do {
            let entry = try await scanService.scan(image: image, mode: mode)
            withAnimation(.spring(duration: 0.5)) {
                capturedEntry = entry
            }
        } catch {
            // Error is already stored in scanService.error
        }
    }
}

// MARK: - Capture Button

private struct CaptureButton: View {
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 76, height: 76)

                if isScanning {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .disabled(isScanning)
        .buttonStyle(.plain)
        .accessibilityLabel(isScanning ? "Processing…" : "Capture photo")
    }
}

// MARK: - Camera Permission View

private struct CameraPermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.6))
            Text("Camera Access Required")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to scan nutrition labels and food.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 8)
        }
    }
}

// MARK: - CameraController

/// Manages the AVCaptureSession lifecycle. Isolated to @MainActor for UI-safe state updates.
@Observable
@MainActor
final class CameraController: NSObject {
    var isReady = false
    var torchOn = false
    var permissionDenied = false

    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?

    func setup() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { permissionDenied = true; return }
        default:
            permissionDenied = true
            return
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        session.startRunning()
        isReady = true
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        try? device.lockForConfiguration()
        torchOn.toggle()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            Task { @MainActor in photoContinuation?.resume(returning: nil) }
            return
        }
        Task { @MainActor in photoContinuation?.resume(returning: image) }
    }
}

#Preview {
    ScanCaptureView()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(ScanService())
}
