// OpenFoodJournal — Onboarding Flow
// Shown once on first launch to introduce the app, set macro goals,
// and request permissions (camera, HealthKit).
// AGPL-3.0 License

import SwiftUI
import AVFoundation

// MARK: - Onboarding Container

/// The root onboarding view that manages a multi-page TabView.
/// Uses @AppStorage("hasCompletedOnboarding") to track whether the user
/// has finished onboarding — once true, this view is never shown again.
struct OnboardingView: View {
    @Environment(UserGoals.self) private var userGoals
    @Environment(HealthKitService.self) private var healthKit
    @Environment(\.dismiss) private var dismiss

    // Persists across launches — once set to true, onboarding is skipped
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // Tracks which page the user is on (0-indexed)
    @State private var currentPage = 0

    // Temporary goal values — written to UserGoals on completion
    @State private var calorieGoal: Double = 2000
    @State private var proteinGoal: Double = 150
    @State private var carbsGoal: Double = 250
    @State private var fatGoal: Double = 65

    // Permission states
    @State private var cameraGranted = false
    @State private var healthKitEnabled = false

    // API key input during onboarding
    @State private var onboardingAPIKey: String = ""
    @State private var apiKeySaved = false

    // Total number of onboarding pages
    private let pageCount = 6

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 0: Welcome
            welcomePage
                .tag(0)

            // Page 1: Gemini API Key
            apiKeyPage
                .tag(1)

            // Page 2: Set macro goals
            goalsPage
                .tag(2)

            // Page 3: Camera permission
            cameraPage
                .tag(3)

            // Page 4: How to use the radial menu
            radialMenuTutorialPage
                .tag(4)

            // Page 5: HealthKit + finish
            healthKitPage
                .tag(5)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .interactiveDismissDisabled()
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(radius: 8, y: 4)

            Text("OpenFoodJournal")
                .font(.largeTitle.bold())

            Text("Track your nutrition with AI-powered label scanning, a personal food bank, and smart macro tracking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Feature highlights
            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "camera.viewfinder", title: "Scan Labels & Food", subtitle: "AI reads nutrition labels or estimates from food photos")
                featureRow(icon: "chart.bar.fill", title: "Track Macros", subtitle: "Daily calories, protein, carbs, and fat at a glance")
                featureRow(icon: "icloud.fill", title: "Sync Across Devices", subtitle: "Your data syncs via iCloud automatically")
            }
            .padding(.horizontal, 24)

            Spacer()

            nextButton
        }
        .padding()
    }

    // MARK: - Page 1: Gemini API Key

    /// Prompts the user to enter their Gemini API key.
    /// This is required for food scanning — without it, the app can't analyze images.
    private var apiKeyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)

            Text("Gemini API Key")
                .font(.largeTitle.bold())

            Text("OpenFoodJournal uses Google's Gemini AI to analyze food photos and nutrition labels. You'll need a free API key.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // App Store 5.1.2(i) disclosure: clearly state what data goes to Google
            // Using footnote + primary color so it's prominent enough for App Store review
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("When you scan food, your photo is sent to Google's Gemini API for analysis. No other personal data is shared.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if apiKeySaved {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                VStack(spacing: 12) {
                    // Link to get an API key
                    Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                        Label("Get a free API key", systemImage: "safari")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)

                    // API key text field
                    HStack {
                        SecureField("Paste your API key here", text: $onboardingAPIKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if !onboardingAPIKey.isEmpty {
                            Button("Save") {
                                let trimmed = onboardingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                KeychainService.save(trimmed, for: KeychainService.geminiAPIKeyAccount)
                                apiKeySaved = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }

            Spacer()

            nextButton
        }
        .padding()
        .onAppear {
            // Check if key was already saved (e.g. from a previous partial onboarding)
            apiKeySaved = KeychainService.hasGeminiAPIKey
        }
    }

    // MARK: - Page 2: Goals

    private var goalsPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "target")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)

            Text("Set Your Goals")
                .font(.largeTitle.bold())

            Text("You can always change these later in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Goal sliders
            VStack(spacing: 20) {
                goalSlider(label: "Calories", value: $calorieGoal, range: 1000...5000, step: 50, unit: "kcal")
                goalSlider(label: "Protein", value: $proteinGoal, range: 30...400, step: 5, unit: "g")
                goalSlider(label: "Carbs", value: $carbsGoal, range: 30...600, step: 5, unit: "g")
                goalSlider(label: "Fat", value: $fatGoal, range: 20...250, step: 5, unit: "g")
            }
            .padding(.horizontal, 24)

            Spacer()

            nextButton
        }
        .padding()
    }

    // MARK: - Page 3: Camera

    private var cameraPage: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)

            Text("Camera Access")
                .font(.largeTitle.bold())

            Text("OpenFoodJournal uses your camera to scan nutrition labels and photograph food for AI analysis.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if cameraGranted {
                Label("Camera access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Button {
                    requestCameraAccess()
                } label: {
                    Text("Allow Camera Access")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
            }

            Spacer()

            nextButton
        }
        .padding()
        .onAppear {
            // Check if already granted (e.g. user granted from Settings)
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    // MARK: - Page 4: Radial Menu Tutorial

    /// Teaches the press-and-drag gesture for the floating "+" button.
    /// Shows a looping animation of a finger pressing and dragging to the Scan option.
    private var radialMenuTutorialPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Quick Actions")
                .font(.largeTitle.bold())

            Text("Press and drag the + button to quickly select an action. Or just tap it to see your options.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // The animated demo of the radial menu gesture
            RadialMenuDemo()
                .frame(height: 260)

            Spacer()

            nextButton
        }
        .padding()
    }

    // MARK: - Page 5: HealthKit + Finish

    private var healthKitPage: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "heart.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Apple Health")
                .font(.largeTitle.bold())

            Text("Optionally write your nutrition data to Apple Health for a complete picture of your wellness.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Toggle(isOn: $healthKitEnabled) {
                Label("Write to Apple Health", systemImage: "heart.circle")
                    .font(.headline)
            }
            .padding(.horizontal, 32)

            Spacer()

            // Finish button instead of next
            Button {
                completeOnboarding()
            } label: {
                Text("Get Started")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .padding()
    }

    // MARK: - Shared Components

    /// A "Next" button that advances to the next page
    private var nextButton: some View {
        Button {
            withAnimation {
                currentPage += 1
            }
        } label: {
            Text("Next")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    /// A single feature highlight row with icon, title, and subtitle
    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A slider for setting a macro goal with label, value display, and unit
    private func goalSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.headline)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.accentColor)
        }
    }

    // MARK: - Actions

    /// Request camera permission via the system prompt
    private func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                cameraGranted = granted
            }
        }
    }

    /// Save goals, enable HealthKit if toggled, and dismiss onboarding
    private func completeOnboarding() {
        // Write goals to UserGoals (which uses @AppStorage internally)
        userGoals.dailyCalories = calorieGoal
        userGoals.dailyProtein = proteinGoal
        userGoals.dailyCarbs = carbsGoal
        userGoals.dailyFat = fatGoal

        // Enable HealthKit if user opted in
        if healthKitEnabled {
            UserDefaults.standard.set(true, forKey: "healthkit.enabled")
            Task { await healthKit.requestAuthorization() }
        }

        // Mark onboarding as complete — this flag prevents showing onboarding again
        withAnimation {
            hasCompletedOnboarding = true
        }

        // Also dismiss the view (needed when opened from Settings as a sheet/fullScreenCover)
        dismiss()
    }
}
