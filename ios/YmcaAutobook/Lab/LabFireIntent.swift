import AppIntents

/// LAB — Spike A: the unattended trigger.
///
/// Exposed to the Shortcuts app so a **Time of Day** automation can invoke it
/// with *Ask Before Running* off. That combination is the only mechanism in
/// #59's table that is both minute-accurate and genuinely unattended —
/// `BGTaskScheduler` treats its start date as a hint and can be hours late or
/// skipped, and silent push is throttled and dropped when the app is force-quit.
///
/// `openAppWhenRun = false` is the whole point: if this needs to foreground the
/// app it proves nothing, because a locked phone in a pocket has nobody to
/// unlock it.
struct LabFireIntent: AppIntent {
    static var title: LocalizedStringResource = "Run YMCA session check"
    static var description = IntentDescription("Lab spike: waits a set number of seconds, then makes an authenticated check, to measure whether iOS lets the app run unattended while locked. Books nothing.")
    static var openAppWhenRun: Bool = false

    // No parameters by design. The wait existed only to measure how long iOS
    // lets a Shortcuts-invoked action run (answer: 20s completes, 30s is
    // killed). With a sweep design — each run books whatever has opened —
    // there is nothing to wait for, so the action checks immediately and keeps
    // its runtime as short as possible. The Lab's manual buttons still exercise
    // waits when we want to re-measure.

    /// Never throws. A thrown error surfaces in Shortcuts as a generic failure
    /// and — worse for a diagnostic — leaves no record of what happened, which
    /// is exactly the case we most need to inspect.
    ///
    /// No `ProvidesDialog`: an automation launches this in the background with
    /// no window, and asking to present something there is itself a failure mode.
    func perform() async throws -> some IntentResult {
        // Background launch: no window exists, so the WebView-based re-auth
        // cannot run here. It would stall until its watchdog and overrun the
        // runtime an automation gets.
        await LabFireLog.run(waitSeconds: 0, allowWebViewReAuth: false)
        return .result()
    }
}

/// Makes the intent discoverable in Shortcuts without the user hunting for it.
struct LabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LabFireIntent(),
            phrases: ["Run \(.applicationName) session check"],
            shortTitle: "Session check",
            systemImageName: "bolt.badge.clock"
        )
    }
}
