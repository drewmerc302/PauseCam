import AppIntents

/// Compiled into BOTH the app and the controls extension. The type must exist
/// in the app's AppIntents metadata so the system runs perform() in the app
/// process when the Control Center button fires — `openAppWhenRun` is rejected
/// with LNContextErrorDomain 2001 when an intent is hosted only in a widget
/// extension.
struct LaunchPauseCamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PauseCam"
    static let description = IntentDescription("Opens PauseCam, the pause/resume camera.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
