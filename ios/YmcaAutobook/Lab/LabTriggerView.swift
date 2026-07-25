import SwiftUI

/// LAB — Spike A surface: set up the unattended trigger, then read what happened.
///
/// The measurement that matters isn't "did it run when I tapped it" — it's "did
/// it run at the scheduled minute, while the phone was locked, and still finish
/// the network call." The history below records exactly that per fire.
struct LabTriggerView: View {
    @State private var fires: [LabFireLog.Entry] = LabFireLog.load()
    @State private var busy = false

    private var lockedSuccesses: Int {
        fires.filter { $0.fullySucceeded && $0.lockedAtFire }.count
    }

    var body: some View {
        List {
            verdictSection
            setupSection
            manualSection
            if !fires.isEmpty { historySection }
        }
        .navigationTitle("Lab · Trigger")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView("Running…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .refreshable { fires = LabFireLog.load() }
    }

    private var verdictSection: some View {
        Section("Verdict") {
            LabeledContent("Fires recorded", value: "\(fires.count)")
            LabeledContent("Completed while locked", value: "\(lockedSuccesses)")
            if lockedSuccesses > 0 {
                Label("Unattended execution confirmed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.booked)
            } else if !fires.isEmpty {
                Label("No locked run has completed yet", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.queued)
            }
        }
    }

    private var setupSection: some View {
        Section {
            step(1, "Open Shortcuts → Automation → New (+).")
            step(2, "Choose Time of Day, pick a time a few minutes out, set it to Daily.")
            step(3, "Turn OFF “Ask Before Running”. This is the critical setting — with it on, the automation waits for a tap and proves nothing.")
            step(4, "Add action → search “Run YMCA session check” → add it.")
            step(5, "Leave Wait seconds at 5. Measured budget: 0–20s completes, 30s and 60s fail (30s fails unlocked too, so it's a hard runtime limit, not a lock-state effect).")
            step(6, "Lock the phone and leave it. Come back after the scheduled time and pull to refresh here.")
        } header: {
            Text("Set up the automation")
        } footer: {
            Text("A Time of Day automation is minute-accurate and runs while locked, which no background-task API guarantees. The wait is what tests whether iOS lets the app keep running long enough to reach an exact booking instant.")
        }
    }

    private var manualSection: some View {
        Section {
            Button {
                runNow(wait: 0)
            } label: {
                Label("Run now (no wait)", systemImage: "play.circle")
            }
            Button {
                runNow(wait: 20)
            } label: {
                Label("Run now (20s wait — near the limit)", systemImage: "clock.arrow.circlepath")
            }
            Button(role: .destructive) {
                LabFireLog.clear(); fires = []
            } label: {
                Label("Clear history", systemImage: "trash")
            }
        } header: {
            Text("Manual check")
        } footer: {
            Text("Running it here only proves the code path works — the phone is unlocked and the app is in front of you. Only a fire from the automation, with the phone locked, answers the real question.")
        }
    }

    private var historySection: some View {
        Section("History") {
            ForEach(fires) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: f.fullySucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(f.fullySucceeded ? Theme.booked : Theme.accent)
                        Text(f.firedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline.weight(.medium))
                        if f.lockedAtFire {
                            Text("LOCKED").font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.weekDivider.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.weekDivider)
                        }
                    }
                    Text(detailLine(f)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detailLine(_ f: LabFireLog.Entry) -> String {
        var bits: [String] = []
        bits.append(f.sleepSurvived ? "held \(f.waitSeconds)s" : "suspended during wait")
        if let n = f.occurrences { bits.append("\(n) occurrences") }
        if f.reAuthed { bits.append("re-authed") }
        bits.append(f.detail)
        return bits.joined(separator: " · ")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runNow(wait: Int) {
        busy = true
        Task {
            await LabFireLog.run(waitSeconds: wait)
            fires = LabFireLog.load()
            busy = false
        }
    }
}
