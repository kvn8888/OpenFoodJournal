// OpenFoodJournal — Build Environment Identity
// AGPL-3.0 License

import Foundation

/// Compile-time deployment lane for the active binary.
///
/// Keeping environment identity in a dedicated enum lets Debug unit tests
/// validate Debug, Preview, and Release isolation rules without needing three
/// separate test hosts, while `current` stays compile-time bound to Xcode's
/// active build configuration.
enum OFJBuildEnvironment: String, CaseIterable, Sendable {
    case debug
    case preview
    case release

    static var current: Self {
        #if DEBUG
        return .debug
        #elseif PREVIEW
        return .preview
        #else
        return .release
        #endif
    }

    var displayName: String {
        switch self {
        case .debug: "OFJ Dev (Debug)"
        case .preview: "OFJ Preview (UAT)"
        case .release: "Production"
        }
    }

    var shortBadge: String? {
        switch self {
        case .debug: "DEV"
        case .preview: "PREVIEW"
        case .release: nil
        }
    }

    /// Separate CloudKit containers guarantee Preview and Dev builds can never
    /// read or write the production iCloud private database, even though Apple
    /// routes TestFlight builds to a container's CloudKit Production environment.
    var cloudKitContainerIdentifier: String {
        switch self {
        case .debug: "iCloud.k3vnc.OpenFoodJournal.dev"
        case .preview: "iCloud.k3vnc.OpenFoodJournal.preview"
        case .release: "iCloud.k3vnc.OpenFoodJournal"
        }
    }

    var expectedBundleIdentifier: String {
        switch self {
        case .debug: "k3vnc.OpenFoodJournal.dev"
        case .preview: "k3vnc.OpenFoodJournal.preview"
        case .release: "k3vnc.OpenFoodJournal"
        }
    }

    /// Preview omits the Apple Health step from Onboarding so routine UAT
    /// installs stay off the shared device Health store by default.
    var showsHealthKitInOnboarding: Bool {
        self != .preview
    }

    /// Enabling Apple Health in Preview requires confirming a warning because
    /// iOS shares one Health store across every app on the phone.
    var requiresHealthKitOptInWarning: Bool {
        self == .preview
    }

    /// Preview permits Turso mirroring for debugging, with a reminder to point
    /// only at a dedicated preview database.
    var showsTursoPreviewWarning: Bool {
        self == .preview
    }

    var showsEnvironmentDiagnosticsInSettings: Bool {
        self != .release
    }
}
