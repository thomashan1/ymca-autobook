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

    @Parameter(title: "Wait seconds before checking", default: 60)
    var waitSeconds: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await LabFireLog.run(waitSeconds: waitSeconds)

        let last = LabFireLog.load().first
        let verdict: String
        if let last {
            verdict = last.fullySucceeded
                ? "Completed\(last.lockedAtFire ? " while locked" : "")."
                : "Incomplete: \(last.detail)"
        } else {
            verdict = "No result recorded."
        }
        return .result(dialog: IntentDialog(stringLiteral: verdict))
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
