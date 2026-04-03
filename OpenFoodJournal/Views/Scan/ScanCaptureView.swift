// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import AVFoundation
import PhotosUI
import Vision

struct ScanCaptureView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(OpenFoodFactsService.self) private var offService
    @Environment(\.dismiss) private var dismiss

    /// The date the scanned entry will be logged to (passed from DailyLogView)
    var logDate: Date = .now

    @AppStorage("scan.useProModel") private var useProModel: Bool = false

    @State private var mode: ScanMode = .label
    @State private var hasSelectedMode = false
    @State private var cameraPermissionDenied = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: PhotosPickerItem?

    // After capture/selection, holds the image for the prompt step
    @State private var capturedImage: UIImage?
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    // CameraController manages the AVCaptureSession lifetime
    @State private var camera = CameraController()

    // Barcode scanning state
    @State private var barcodeProduct: OFFProduct?
    @State private var isLookingUpBarcode = false

    var body: some View {
        ZStack {
            // Live camera preview — full screen (starts loading immediately)
            if camera.isReady {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                if cameraPermissionDenied {
                    CameraPermissionView()
                }
            }

            if !hasSelectedMode {
                // Mode selection screen — two large cards over the camera preview
                modeSelectionOverlay
                    .transition(.opacity)
            } else if let image = capturedImage {
                // After capturing/selecting a photo, show confirmation with prompt field
                promptOverlay(image: image)
                    .transition(.opacity)
            } else {
                // Camera UI overlay — only visible after mode selected, before capture
                cameraOverlay
                    .transition(.opacity)
            }

            // Error banner — show scan errors or OFF lookup errors
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

            if let offError = offService.errorMessage {
                VStack {
                    Spacer()
                    Text(offError)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .glassEffect(.regular.tint(.red.opacity(0.4)), in: .rect(cornerRadius: 16))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                }
            }

            // Loading overlay for barcode lookups
            if isLookingUpBarcode {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Looking up product…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.5))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: capturedImage != nil)
        .animation(.easeInOut(duration: 0.3), value: hasSelectedMode)
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
        // Sheet for barcode lookup results — pre-fills ManualEntryView with OFF product data
        .sheet(item: $barcodeProduct) { product in
            ManualEntryView(defaultDate: logDate, prefillProduct: product)
        }
    }

    // MARK: - Mode Selection Overlay

    /// Full-screen overlay with two large cards for choosing scan mode.
    /// Shown before the camera UI. Selecting a card sets the mode and transitions to camera.
    private var modeSelectionOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar — close button only
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
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 16) {
                    Text("What would you like to scan?")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    // Scan Label card
                    Button {
                        mode = .label
                        withAnimation { hasSelectedMode = true }
                    } label: {
                        ScanModeCard(
                            icon: "doc.viewfinder",
                            title: "Scan Label",
                            description: "Point at a nutrition facts label for accurate readings",
                            color: .green,
                            iconColor: .white
                        )
                    }
                    .buttonStyle(.plain)

                    // Scan Food card
                    Button {
                        mode = .foodPhoto
                        withAnimation { hasSelectedMode = true }
                    } label: {
                        ScanModeCard(
                            icon: "fork.knife.circle",
                            title: "Scan Food",
                            description: "Take a photo of your food for an AI-powered estimate",
                            color: .blue,
                            iconColor: .white
                        )
                    }
                    .buttonStyle(.plain)

                    // Scan Barcode card — uses camera to scan a barcode,
                    // then looks up nutrition on Open Food Facts
                    Button {
                        mode = .barcode
                        withAnimation { hasSelectedMode = true }
                    } label: {
                        ScanModeCard(
                            icon: "barcode.viewfinder",
                            title: "Scan Barcode",
                            description: "Scan a product barcode to look up nutrition from Open Food Facts",
                            color: .orange,
                            iconColor: .white
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    // MARK: - Camera Overlay

    /// The live camera UI: mode toggle, torch, capture button, gallery
    private var cameraOverlay: some View {
        VStack {
            // Top bar
            HStack {
                Button {
                    withAnimation { hasSelectedMode = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)

                Spacer()

                // Mode toggle — reflects the user's selection from the cards
                GlassEffectContainer(spacing: 0) {
                    Picker("Scan mode", selection: $mode) {
                        Text("Label").tag(ScanMode.label)
                        Text("Photo").tag(ScanMode.foodPhoto)
                        Text("Barcode").tag(ScanMode.barcode)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
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
            Text(modeHintText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .glassEffect(in: .capsule)
                .padding(.bottom, 24)
                .animation(.easeInOut, value: mode)

            // Bottom bar: gallery (left), shutter (center), spacer (right for balance)
            HStack {
                // Photo library button — bottom left near shutter
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)

                Spacer()

                // Capture button — center
                CaptureButton(isScanning: scanService.isScanning) {
                    Task { await capture() }
                }

                Spacer()

                // Invisible spacer to balance the gallery button
                Color.clear
                    .frame(width: 48, height: 48)
            }
            .padding(.horizontal, 32)
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

                    if mode == .barcode {
                        // Barcode mode — detect barcode from photo, look up on OFF
                        Button {
                            Task { await detectAndLookupBarcode(from: image) }
                        } label: {
                            Label("Look Up", systemImage: "barcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(isLookingUpBarcode)
                    } else {
                        // Label/Food Photo mode — send to Gemini
                        Button {
                            isPromptFocused = false
                            let prompt = promptText.isEmpty ? nil : promptText
                            scanService.scanInBackground(image: image, mode: mode, prompt: prompt, useProModel: useProModel)
                            dismiss()
                        } label: {
                            Label("Analyze", systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Mode Hint Text

    /// Context-sensitive camera instruction text
    private var modeHintText: String {
        switch mode {
        case .label: return "Point at a nutrition facts label"
        case .foodPhoto: return "Point at your food for an estimate"
        case .barcode: return "Point at a product barcode"
        case .manual: return ""
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

    // MARK: - Barcode Detection

    /// Detects a barcode from the captured image using Vision framework,
    /// then looks up the product on Open Food Facts.
    /// If found, opens ManualEntryView pre-filled with the product data.
    private func detectAndLookupBarcode(from image: UIImage) async {
        guard let cgImage = image.cgImage else {
            offService.errorMessage = "Could not process image"
            return
        }

        isLookingUpBarcode = true
        defer { isLookingUpBarcode = false }

        // Step 1: Detect barcodes using Vision framework
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            offService.errorMessage = "Barcode detection failed"
            return
        }

        // Get the first detected barcode's payload
        guard let observations = request.results,
              let firstBarcode = observations.first,
              let barcodeValue = firstBarcode.payloadStringValue,
              !barcodeValue.isEmpty else {
            offService.errorMessage = "No barcode detected in the photo. Try again with the barcode clearly visible."
            return
        }

        // Step 2: Look up the barcode on Open Food Facts
        let product = try? await offService.lookupBarcode(barcodeValue)

        guard let product else {
            // lookupBarcode already sets errorMessage if not found
            if offService.errorMessage == nil {
                offService.errorMessage = "Product not found for barcode \(barcodeValue)"
            }
            return
        }

        // Step 3: Open ManualEntryView pre-filled with the product
        barcodeProduct = product
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

// MARK: - Scan Mode Card

/// Large selection card for the mode picker screen.
/// Shows an icon, title, and description with a tinted glass background.
private struct ScanModeCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    var iconColor: Color? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(iconColor ?? color)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.clear.tint(color.opacity(0.25)), in: .rect(cornerRadius: 16))
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
