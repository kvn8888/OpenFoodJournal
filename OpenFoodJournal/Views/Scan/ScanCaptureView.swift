// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import AVFoundation
import PhotosUI

struct ScanCaptureView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(\.dismiss) private var dismiss

    /// The date the scanned entry will be logged to (passed from DailyLogView)
    var logDate: Date = .now

    @State private var mode: ScanMode = .label
    @State private var cameraPermissionDenied = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: PhotosPickerItem?

    // After capture/selection, holds the image for the prompt step
    @State private var capturedImage: UIImage?
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

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

            // After capturing/selecting a photo, show confirmation with prompt field
            if let image = capturedImage {
                promptOverlay(image: image)
                    .transition(.opacity)
            } else {
                // Camera UI overlay — only visible before capture
                cameraOverlay
                    .transition(.opacity)
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
        }
        .animation(.easeInOut(duration: 0.25), value: capturedImage != nil)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isPromptFocused = false }
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    withAnimation { capturedImage = image }
                }
            }
            photoSelection = nil
        }
    }

    // MARK: - Camera Overlay

    /// The live camera UI: mode toggle, torch, photo library, capture button
    private var cameraOverlay: some View {
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

                // Photo library button
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)

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
    }

    // MARK: - Prompt Overlay

    /// Shown after capture/selection. Displays the photo with an optional prompt
    /// field before sending to Gemini.
    private func promptOverlay(image: UIImage) -> some View {
        ZStack {
            // Dim the camera preview behind
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Photo preview
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxHeight: 300)
                    .padding(.horizontal, 24)

                // Optional prompt — only shown for food photos, not label scans.
                // Label scans extract structured data from the nutrition facts panel;
                // extra context would just confuse the OCR model.
                if mode == .foodPhoto {
                    HStack(spacing: 8) {
                        TextField("Add context, e.g. \"walnut shrimp\"", text: $promptText)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .focused($isPromptFocused)
                            .submitLabel(.done)
                            .onSubmit { isPromptFocused = false }
                        if !promptText.isEmpty {
                            Button {
                                promptText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                        }
                    }
                    .glassEffect(in: .capsule)
                    .padding(.horizontal, 32)
                }

                // Action buttons
                HStack(spacing: 16) {
                    // Retake — go back to camera
                    Button {
                        withAnimation {
                            capturedImage = nil
                            promptText = ""
                        }
                    } label: {
                        Text("Retake")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    // Send to Gemini
                    Button {
                        isPromptFocused = false
                        let prompt = promptText.isEmpty ? nil : promptText
                        scanService.scanInBackground(image: image, mode: mode, prompt: prompt)
                        dismiss()
                    } label: {
                        Label("Analyze", systemImage: "wand.and.sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Capture

    /// Takes a photo and transitions to the prompt step
    private func capture() async {
        guard !scanService.isScanning else { return }
        let image = await camera.capturePhoto()
        guard let image else { return }
        withAnimation { capturedImage = image }
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
