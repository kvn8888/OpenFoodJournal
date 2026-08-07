// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import AVFoundation
import Combine
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

    @State private var mode: ScanMode = .foodPhoto
    @State private var cameraPermissionDenied = false
    @State private var showPhotoPicker = false
    @State private var photoSelections: [PhotosPickerItem] = []

    // After capture/selection, holds the photos for the review and prompt step.
    @State private var capturedPhotos: [CapturedScanPhoto] = []
    @State private var selectedPhotoID: CapturedScanPhoto.ID?
    @State private var isCapturingAdditionalPhoto = false
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    // CameraController manages the AVCaptureSession lifetime
    @StateObject private var camera = CameraController()

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

            if !capturedPhotos.isEmpty && !isCapturingAdditionalPhoto {
                // After capturing/selecting photos, show confirmation with prompt field
                promptOverlay
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
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelections,
            maxSelectionCount: pickerSelectionLimit,
            matching: .images
        )
        .onChange(of: photoSelections) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        withAnimation { addCapturedPhoto(image) }
                    }
                }
                photoSelections = []
            }
        }
        // Sheet for barcode lookup results — pre-fills ManualEntryView with OFF product data
        .sheet(item: $barcodeProduct) { product in
            ManualEntryView(defaultDate: logDate, prefillProduct: product)
        }
    }

    // MARK: - Camera Overlay

    /// The live camera is also the mode-selection screen. This keeps all three
    /// capture paths one tap away without duplicating a separate chooser.
    private var cameraOverlay: some View {
        ScanCameraControls(
            mode: $mode,
            zoomFactor: camera.zoomFactor,
            zoomConfiguration: camera.zoomConfiguration,
            torchOn: camera.torchOn,
            torchAvailable: camera.isTorchAvailable,
            canRetry: scanService.lastSubmittedScan != nil,
            isBusy: scanService.isScanning,
            onExit: { dismiss() },
            onRetry: retryLastScan,
            onZoom: camera.setZoomFactor,
            onTorch: camera.toggleTorch,
            onCapture: { Task { await capture() } },
            onLibrary: { showPhotoPicker = true }
        )
        .onChange(of: mode) {
            resetCapturedPhotos()
        }
    }

    // MARK: - Prompt Overlay

    /// Shown after capture/selection. Displays the selected photo and the full
    /// set of angles before sending them to Gemini together.
    private var promptOverlay: some View {
        ZStack {
            // Dim the camera preview behind
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Photo preview
                if let photo = selectedCapturedPhoto {
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxHeight: supportsMultiplePhotos ? 230 : 300)
                        .padding(.horizontal, 24)
                }

                if supportsMultiplePhotos {
                    VStack(spacing: 12) {
                        HStack {
                            Text("\(capturedPhotos.count) of \(ScanService.maxImagesPerScan) photos")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)

                            Spacer()

                            if capturedPhotos.count > 1 {
                                Button {
                                    removeSelectedPhoto()
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.glass)
                                .accessibilityLabel("Remove selected photo")
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(capturedPhotos.enumerated()), id: \.element.id) { index, photo in
                                    Button {
                                        selectedPhotoID = photo.id
                                    } label: {
                                        Image(uiImage: photo.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(photo.id == selectedPhotoID ? .white : .clear, lineWidth: 2)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Photo \(index + 1)")
                                }
                            }
                        }

                        if canAddAnotherPhoto {
                            HStack(spacing: 12) {
                                Button {
                                    withAnimation { isCapturingAdditionalPhoto = true }
                                } label: {
                                    Label("Add Angle", systemImage: "camera")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)

                                Button {
                                    showPhotoPicker = true
                                } label: {
                                    Label("Library", systemImage: "photo.on.rectangle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                }

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
                            resetCapturedPhotos()
                        }
                    } label: {
                        Text(capturedPhotos.count > 1 ? "Start Over" : "Retake")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    if mode == .barcode {
                        // Barcode mode — detect barcode from photo, look up on OFF
                        Button {
                            if let photo = selectedCapturedPhoto {
                                Task { await detectAndLookupBarcode(from: photo.image) }
                            }
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
                            scanService.scanInBackground(
                                images: capturedPhotos.map(\.image),
                                mode: mode,
                                prompt: prompt,
                                useProModel: useProModel
                            )
                            dismiss()
                        } label: {
                            Label(analyzeButtonTitle, systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
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
        withAnimation { addCapturedPhoto(image) }
    }

    // MARK: - Captured Photos

    private var selectedCapturedPhoto: CapturedScanPhoto? {
        capturedPhotos.first(where: { $0.id == selectedPhotoID }) ?? capturedPhotos.last
    }

    private var supportsMultiplePhotos: Bool {
        mode == .label || mode == .foodPhoto
    }

    private var canAddAnotherPhoto: Bool {
        supportsMultiplePhotos && capturedPhotos.count < ScanService.maxImagesPerScan
    }

    private var pickerSelectionLimit: Int {
        guard supportsMultiplePhotos else { return 1 }
        return max(1, ScanService.maxImagesPerScan - capturedPhotos.count)
    }

    private var analyzeButtonTitle: String {
        capturedPhotos.count > 1 ? "Analyze \(capturedPhotos.count) Photos" : "Analyze"
    }

    private func addCapturedPhoto(_ image: UIImage) {
        let photo = CapturedScanPhoto(image: image)
        if supportsMultiplePhotos {
            guard capturedPhotos.count < ScanService.maxImagesPerScan else { return }
            capturedPhotos.append(photo)
        } else {
            capturedPhotos = [photo]
        }
        selectedPhotoID = photo.id
        isCapturingAdditionalPhoto = false
    }

    private func removeSelectedPhoto() {
        guard let selectedPhotoID else { return }
        capturedPhotos.removeAll(where: { $0.id == selectedPhotoID })
        self.selectedPhotoID = capturedPhotos.last?.id
    }

    private func resetCapturedPhotos() {
        capturedPhotos.removeAll()
        selectedPhotoID = nil
        isCapturingAdditionalPhoto = false
        promptText = ""
    }

    private func retryLastScan() {
        guard scanService.lastSubmittedScan != nil else { return }
        scanService.redoLastScanInBackground()
        dismiss()
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

private struct CapturedScanPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Maps AVFoundation's device zoom values to the factors people recognize from
/// Apple's camera interfaces. Virtual cameras often report 1.0 while showing
/// 0.5x; `displayVideoZoomFactorMultiplier` is the system-provided conversion.
struct CameraZoomConfiguration: Equatable, Sendable {
    static let fallback = CameraZoomConfiguration(
        range: 1.0...2.0,
        displayMultiplier: 1.0
    )

    let range: ClosedRange<Double>
    let displayMultiplier: Double

    init(range: ClosedRange<Double>, displayMultiplier: Double) {
        self.range = range
        self.displayMultiplier = max(displayMultiplier, 0.01)
    }

    var isAdjustable: Bool {
        range.upperBound - range.lowerBound > 0.001
    }

    var neutralFactor: Double {
        clampedFactor(1.0 / displayMultiplier)
    }

    func clampedFactor(_ factor: Double) -> Double {
        min(max(factor, range.lowerBound), range.upperBound)
    }

    func displayFactor(for factor: Double) -> Double {
        clampedFactor(factor) * displayMultiplier
    }

    func displayLabel(for factor: Double) -> String {
        let displayed = displayFactor(for: factor)
        let precision = displayed.rounded() == displayed ? 0 : 1
        return displayed.formatted(
            .number.precision(.fractionLength(precision))
        ) + "×"
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
@MainActor
final class CameraController: NSObject, ObservableObject {
    @Published var isReady = false
    @Published var torchOn = false
    @Published var permissionDenied = false
    @Published private(set) var zoomFactor = 1.0
    @Published private(set) var zoomConfiguration = CameraZoomConfiguration.fallback
    @Published private(set) var isTorchAvailable = false

    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var currentVideoInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
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

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        guard configureVideoInput() else { return }

        session.startRunning()
        isReady = true
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func toggleTorch() {
        guard let device = activeDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        torchOn.toggle()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    func setZoomFactor(_ factor: Double) {
        let clampedFactor = zoomConfiguration.clampedFactor(factor)
        guard let activeDevice else {
            zoomFactor = clampedFactor
            return
        }

        do {
            try activeDevice.lockForConfiguration()
            activeDevice.videoZoomFactor = CGFloat(clampedFactor)
            activeDevice.unlockForConfiguration()
            zoomFactor = Double(activeDevice.videoZoomFactor)
        } catch {
            zoomFactor = Double(activeDevice.videoZoomFactor)
        }
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureVideoInput() -> Bool {
        guard let device = preferredBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        if let currentVideoInput {
            session.removeInput(currentVideoInput)
        }

        guard session.canAddInput(input) else {
            if let currentVideoInput, session.canAddInput(currentVideoInput) {
                session.addInput(currentVideoInput)
            }
            session.commitConfiguration()
            return false
        }

        session.addInput(input)
        currentVideoInput = input
        activeDevice = device
        isTorchAvailable = device.hasTorch
        session.commitConfiguration()

        configureZoom(for: device)
        return true
    }

    /// A virtual rear camera lets AVFoundation perform seamless constituent-lens
    /// switching while one native slider drives a continuous zoom range.
    private func preferredBackCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]

        for type in preferredTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Apple uses this same recommended range for `AVCaptureSystemZoomSlider`.
    /// That control belongs to the physical Camera Control overlay, so the
    /// visible scan UI uses SwiftUI's native `Slider` with the identical range.
    /// https://developer.apple.com/documentation/avfoundation/avcapturesystemzoomslider
    private func configureZoom(for device: AVCaptureDevice) {
        let availableRange = Double(device.minAvailableVideoZoomFactor)...Double(device.maxAvailableVideoZoomFactor)
        let recommendedRange = device.activeFormat.systemRecommendedVideoZoomRange
            .map { Double($0.lowerBound)...Double($0.upperBound) }
            ?? availableRange
        let lowerBound = min(
            max(recommendedRange.lowerBound, availableRange.lowerBound),
            availableRange.upperBound
        )
        let upperBound = max(
            lowerBound,
            min(recommendedRange.upperBound, availableRange.upperBound)
        )
        let configuration = CameraZoomConfiguration(
            range: lowerBound...upperBound,
            displayMultiplier: Double(device.displayVideoZoomFactorMultiplier)
        )
        let initialFactor = configuration.neutralFactor

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(initialFactor)
            if torchOn {
                if device.hasTorch {
                    device.torchMode = .on
                } else {
                    torchOn = false
                }
            }
            device.unlockForConfiguration()
            zoomConfiguration = configuration
            zoomFactor = Double(device.videoZoomFactor)
        } catch {
            torchOn = false
            zoomConfiguration = configuration
            zoomFactor = configuration.clampedFactor(Double(device.videoZoomFactor))
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
