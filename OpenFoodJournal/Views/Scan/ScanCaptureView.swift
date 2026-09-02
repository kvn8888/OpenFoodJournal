// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import AVFoundation
import Combine
import ImageIO
import PhotosUI
import Vision

struct ScanCaptureView: View {
    var logDate: Date = .now

    var body: some View {
        #if DEBUG
        if ScreenshotConfiguration.isEnabled {
            ScreenshotScanCaptureView()
        } else {
            LiveScanCaptureView(logDate: logDate)
        }
        #else
        LiveScanCaptureView(logDate: logDate)
        #endif
    }
}

#if DEBUG
/// Exercises the production controls without constructing CameraController,
/// requesting permissions, opening Photos, or submitting an image for analysis.
private struct ScreenshotScanCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = ScanMode.foodPhoto
    @State private var zoom = CameraZoomLevel.one
    @State private var torchOn = false

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("White camera preview for screenshots")
                .accessibilityIdentifier("scan.screenshot-preview")

            ScanCameraControls(
                mode: $mode,
                zoomLevel: zoom,
                availableZoomLevels: CameraZoomLevel.allCases,
                torchOn: torchOn,
                torchAvailable: true,
                canRetry: false,
                isBusy: false,
                onExit: { dismiss() },
                onRetry: {},
                onZoom: { zoom = $0 },
                onTorch: { torchOn.toggle() },
                onCapture: {},
                onLibrary: {}
            )
        }
    }
}
#endif

private struct LiveScanCaptureView: View {
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
            // Attach the preview layer immediately so the sheet is not waiting
            // on startRunning(). Frames appear when the session queue finishes.
            if cameraPermissionDenied {
                Color.black.ignoresSafeArea()
                CameraPermissionView()
            } else {
                CameraPreviewView(
                    session: camera.session,
                    onVisibleCaptureRectChanged: camera.setVisibleCaptureRect
                )
                .ignoresSafeArea()
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
            zoomLevel: camera.zoomLevel,
            availableZoomLevels: camera.availableZoomLevels,
            torchOn: camera.torchOn,
            torchAvailable: camera.isTorchAvailable,
            canRetry: scanService.lastSubmittedScan != nil,
            isBusy: scanService.isScanning || !camera.isReady,
            onExit: { dismiss() },
            onRetry: retryLastScan,
            onZoom: camera.setZoom,
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
        guard !scanService.isScanning, camera.isReady else { return }
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

/// The scan camera deliberately exposes three predictable system-style steps.
/// 0.5× swaps to the physical ultra-wide input; 1× and 2× share the physical
/// wide input, with 2× applying a 2.0 device zoom factor. The session never
/// holds a virtual multi-camera input or more than one physical lens at once.
enum CameraZoomLevel: Double, CaseIterable, Identifiable, Sendable {
    case half = 0.5
    case one = 1.0
    case two = 2.0

    var id: Double { rawValue }

    var displayLabel: String {
        switch self {
        case .half: "0.5×"
        case .one: "1×"
        case .two: "2×"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .half: "Set camera zoom to 0.5 times"
        case .one: "Set camera zoom to 1 time"
        case .two: "Set camera zoom to 2 times"
        }
    }

    var deviceZoomFactor: CGFloat {
        self == .two ? 2 : 1
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

/// UI-facing camera state. Session graph work runs on `sessionQueue` because
/// `AVCaptureSession.startRunning()` / `stopRunning()` block for hundreds of
/// milliseconds and must not freeze the scan sheet on the main actor.
@MainActor
final class CameraController: NSObject, ObservableObject {
    @Published var isReady = false
    @Published var torchOn = false
    @Published var permissionDenied = false
    @Published private(set) var zoomLevel = CameraZoomLevel.one
    @Published private(set) var availableZoomLevels: [CameraZoomLevel] = [.one]
    @Published private(set) var isTorchAvailable = false

    var session: AVCaptureSession { graph.session }

    private let graph = CameraSessionGraph()
    private let sessionQueue = DispatchQueue(label: "k3vnc.openfoodjournal.camera.session")
    private var visibleCaptureCrop = CameraPreviewCrop.fullFrame
    private var pendingPhotoCapture: PendingPhotoCapture?

    private struct PendingPhotoCapture {
        let crop: CameraPreviewCrop
        let continuation: CheckedContinuation<UIImage?, Never>
    }

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

        let graph = self.graph
        let initialZoom = zoomLevel
        let snapshot = await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: graph.start(initialZoom: initialZoom))
            }
        }
        availableZoomLevels = snapshot.availableZoomLevels
        zoomLevel = snapshot.zoomLevel
        isTorchAvailable = snapshot.isTorchAvailable
        isReady = snapshot.started
    }

    func stop() {
        if let pendingPhotoCapture {
            pendingPhotoCapture.continuation.resume(returning: nil)
            self.pendingPhotoCapture = nil
        }
        let graph = self.graph
        sessionQueue.async {
            graph.stop()
        }
    }

    func setVisibleCaptureRect(_ rect: CGRect) {
        visibleCaptureCrop = CameraPreviewCrop(normalizedRect: rect)
    }

    func toggleTorch() {
        let graph = self.graph
        let shouldEnable = !torchOn
        sessionQueue.async {
            let enabled = graph.setTorch(shouldEnable)
            Task { @MainActor in
                self.torchOn = enabled
            }
        }
    }

    func setZoom(_ level: CameraZoomLevel) {
        guard availableZoomLevels.contains(level) else { return }
        let graph = self.graph
        let torchOn = self.torchOn
        sessionQueue.async {
            graph.setZoom(level, torchOn: torchOn)
            let zoom = graph.zoomLevel
            let torchAvailable = graph.isTorchAvailable
            Task { @MainActor in
                self.zoomLevel = zoom
                self.isTorchAvailable = torchAvailable
                if !torchAvailable { self.torchOn = false }
            }
        }
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard pendingPhotoCapture == nil else {
                continuation.resume(returning: nil)
                return
            }

            pendingPhotoCapture = PendingPhotoCapture(
                crop: visibleCaptureCrop,
                continuation: continuation
            )
            let output = graph.photoOutput
            sessionQueue.async {
                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }
}

/// Capture graph owned by `CameraController`. `@unchecked Sendable` because
/// every mutation is serialized on the controller's session queue.
private final class CameraSessionGraph: @unchecked Sendable {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    private(set) var zoomLevel = CameraZoomLevel.one
    private(set) var availableZoomLevels: [CameraZoomLevel] = [.one]
    private var currentVideoInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?

    var isTorchAvailable: Bool { activeDevice?.hasTorch ?? false }

    struct StartSnapshot: Sendable {
        var started: Bool
        var zoomLevel: CameraZoomLevel
        var availableZoomLevels: [CameraZoomLevel]
        var isTorchAvailable: Bool
    }

    func start(initialZoom: CameraZoomLevel) -> StartSnapshot {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        refreshAvailableZoomLevels()
        if !availableZoomLevels.contains(initialZoom) {
            zoomLevel = availableZoomLevels.contains(.one) ? .one : availableZoomLevels[0]
        } else {
            zoomLevel = initialZoom
        }

        let started = configureVideoInput(for: zoomLevel, torchOn: false)
        if started {
            session.startRunning()
        }
        return StartSnapshot(
            started: started && session.isRunning,
            zoomLevel: zoomLevel,
            availableZoomLevels: availableZoomLevels,
            isTorchAvailable: isTorchAvailable
        )
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    @discardableResult
    func setTorch(_ enabled: Bool) -> Bool {
        guard let device = activeDevice, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            return enabled
        } catch {
            return false
        }
    }

    func setZoom(_ level: CameraZoomLevel, torchOn: Bool) {
        guard availableZoomLevels.contains(level) else { return }
        guard let targetDevice = device(for: level) else { return }

        if activeDevice?.uniqueID == targetDevice.uniqueID {
            applyZoom(level, to: targetDevice, torchOn: torchOn)
            return
        }

        _ = configureVideoInput(for: level, torchOn: torchOn)
    }

    private func refreshAvailableZoomLevels() {
        var levels: [CameraZoomLevel] = []
        if device(for: .half) != nil { levels.append(.half) }
        if let wide = device(for: .one) {
            levels.append(.one)
            if wide.maxAvailableVideoZoomFactor >= CameraZoomLevel.two.deviceZoomFactor {
                levels.append(.two)
            }
        }
        availableZoomLevels = levels.isEmpty ? [.one] : levels
    }

    private func configureVideoInput(for level: CameraZoomLevel, torchOn: Bool) -> Bool {
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

        applyZoom(level, to: device, torchOn: torchOn)
        return true
    }

    private func device(for level: CameraZoomLevel) -> AVCaptureDevice? {
        switch level {
        case .half:
            AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .one, .two:
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    private func applyZoom(_ level: CameraZoomLevel, to device: AVCaptureDevice, torchOn: Bool) {
        let factor = min(
            max(level.deviceZoomFactor, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor
        )
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            if torchOn, device.hasTorch {
                device.torchMode = .on
            }
            device.unlockForConfiguration()
            zoomLevel = level
        } catch {
            return
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
        let capturedImage = error == nil ? photo.cgImageRepresentation() : nil
        let orientationValue = (
            photo.metadata[String(kCGImagePropertyOrientation)] as? NSNumber
        )?.uint32Value ?? 1

        Task { @MainActor [weak self] in
            guard let self, let pendingPhotoCapture = self.pendingPhotoCapture else {
                return
            }
            self.pendingPhotoCapture = nil

            guard let capturedImage,
                  let pixelRect = pendingPhotoCapture.crop.pixelRect(
                    forWidth: capturedImage.width,
                    height: capturedImage.height
                  ),
                  let croppedImage = capturedImage.cropping(to: pixelRect)
            else {
                pendingPhotoCapture.continuation.resume(returning: nil)
                return
            }

            let image = UIImage(
                cgImage: croppedImage,
                scale: 1,
                orientation: UIImage.Orientation(exifOrientation: orientationValue)
            )
            pendingPhotoCapture.continuation.resume(returning: image)
        }
    }
}

private extension UIImage.Orientation {
    /// EXIF orientation values do not share UIKit's raw-value ordering.
    init(exifOrientation: UInt32) {
        switch exifOrientation {
        case 2: self = .upMirrored
        case 3: self = .down
        case 4: self = .downMirrored
        case 5: self = .leftMirrored
        case 6: self = .right
        case 7: self = .rightMirrored
        case 8: self = .left
        default: self = .up
        }
    }
}

#Preview {
    ScanCaptureView()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(ScanService())
}
