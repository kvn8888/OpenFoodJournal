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

    @State private var mode: ScanMode = .label
    @State private var hasSelectedMode = false
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

            if !hasSelectedMode {
                // Mode selection screen — two large cards over the camera preview
                modeSelectionOverlay
                    .transition(.opacity)
            } else if !capturedPhotos.isEmpty && !isCapturingAdditionalPhoto {
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

                    if let lastScan = scanService.lastSubmittedScan {
                        Button {
                            scanService.redoLastScanInBackground()
                            dismiss()
                        } label: {
                            ScanModeCard(
                                icon: "arrow.clockwise",
                                title: "Redo Last Scan",
                                description: redoScanDescription(lastScan),
                                color: .indigo,
                                iconColor: .white
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(scanService.isScanning)
                    }
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
                    returnFromCamera()
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
                    .onChange(of: mode) { _, _ in
                        resetCapturedPhotos()
                    }
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

            zoomSelector
                .padding(.top, 10)

            Spacer()

            // Mode hint
            Text(cameraHintText)
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

    private var zoomSelector: some View {
        HStack(spacing: 8) {
            ForEach(CameraZoomLevel.allCases) { level in
                let isAvailable = camera.availableZoomLevels.contains(level)
                Button {
                    camera.setZoom(level)
                } label: {
                    Text(level.label)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(camera.zoomLevel == level ? .black : .white)
                        .frame(width: 48, height: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .opacity(isAvailable ? 1 : 0.35)
                .glassEffect(
                    camera.zoomLevel == level
                        ? .regular.tint(.white.opacity(0.85))
                        : .regular.tint(.black.opacity(0.25)),
                    in: .capsule
                )
                .accessibilityLabel(level.accessibilityLabel)
            }
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

    private var cameraHintText: String {
        if isCapturingAdditionalPhoto {
            return "Capture another angle (\(capturedPhotos.count) of \(ScanService.maxImagesPerScan))"
        }
        return modeHintText
    }

    private var analyzeButtonTitle: String {
        capturedPhotos.count > 1 ? "Analyze \(capturedPhotos.count) Photos" : "Analyze"
    }

    private func redoScanDescription(_ request: ScanRedoRequest) -> String {
        let photoLabel = request.photoCount == 1 ? "photo" : "photos"
        return "Re-analyze \(request.photoCount) previous \(photoLabel)"
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

    private func returnFromCamera() {
        withAnimation {
            if isCapturingAdditionalPhoto && !capturedPhotos.isEmpty {
                isCapturingAdditionalPhoto = false
            } else {
                resetCapturedPhotos()
                hasSelectedMode = false
            }
        }
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

enum CameraZoomLevel: Double, CaseIterable, Identifiable {
    case half = 0.5
    case one = 1.0
    case two = 2.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half: "0.5x"
        case .one: "1x"
        case .two: "2x"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .half: "Set camera zoom to 0.5 times"
        case .one: "Set camera zoom to 1 times"
        case .two: "Set camera zoom to 2 times"
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
@MainActor
final class CameraController: NSObject, ObservableObject {
    @Published var isReady = false
    @Published var torchOn = false
    @Published var permissionDenied = false
    @Published var zoomLevel: CameraZoomLevel = .one
    @Published var availableZoomLevels: [CameraZoomLevel] = [.one]

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

        refreshAvailableZoomLevels()
        guard configureVideoInput(for: zoomLevel) else { return }

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

    func setZoom(_ level: CameraZoomLevel) {
        guard availableZoomLevels.contains(level) else { return }
        zoomLevel = level
        guard isReady else { return }
        _ = configureVideoInput(for: level)
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func refreshAvailableZoomLevels() {
        var levels: [CameraZoomLevel] = []
        for level in CameraZoomLevel.allCases where device(for: level) != nil {
            levels.append(level)
        }
        availableZoomLevels = levels.isEmpty ? [.one] : levels
        if !availableZoomLevels.contains(zoomLevel) {
            zoomLevel = availableZoomLevels.contains(.one) ? .one : availableZoomLevels[0]
        }
    }

    private func configureVideoInput(for level: CameraZoomLevel) -> Bool {
        guard let device = device(for: level),
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
        session.commitConfiguration()

        applyZoom(level, to: device)
        return true
    }

    private func device(for level: CameraZoomLevel) -> AVCaptureDevice? {
        switch level {
        case .half:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .one, .two:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    private func applyZoom(_ level: CameraZoomLevel, to device: AVCaptureDevice) {
        let requestedZoom: CGFloat = level == .two ? 2.0 : 1.0
        let clampedZoom = min(max(requestedZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedZoom
            if torchOn {
                if device.hasTorch {
                    device.torchMode = .on
                } else {
                    torchOn = false
                }
            }
            device.unlockForConfiguration()
        } catch {
            torchOn = false
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
