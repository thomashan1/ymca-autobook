import SwiftUI

/// LAB — Spike A surface: set up the unattended trigger, then read what happened.
///
/// The measurement that matters isn't "did it run when I tapped it" — it's "did
/// it run at the scheduled minute, while the phone was locked, and still finish
/// the network call." The history below records exactly that per fire.
struct LabTriggerView: View {
    @EnvironmentObject var classes: ClassesRepository
    @State private var fires: [LabFireLog.Entry] = LabFireLog.load()
    @State private var busy = false

    /// Booking opens 167h before a class — one week minus one hour, so it lands
    /// on the same weekday one hour *later* in the day than the class starts.
    private var openTimes: [(label: String, minutes: Int)] {
        classes.classes.compactMap { c in
            let p = c.start.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2 else { return nil }
            let mins = p[0] * 60 + p[1] + 60
            return ("\(c.weekday.rawValue) \(String(format: "%02d:%02d", mins / 60, mins % 60))  \(c.name)", mins)
        }
        .sorted { $0.minutes < $1.minutes }
    }

    /// Sweep on the hour, from the hour of the earliest open through the hour
    /// after the latest — every class is then picked up within the hour.
    private var suggestedSweeps: [String] {
        guard let first = openTimes.first?.minutes, let last = openTimes.last?.minutes else { return [] }
        let startHour = first / 60
        let endHour = (last % 60 == 0) ? last / 60 : last / 60 + 1
        return (startHour...endHour).map { h in
            let display = h > 12 ? h - 12 : h
            return String(format: "%d:00 %@", display, h >= 12 ? "PM" : "AM")
        }
    }

    private var lockedSuccesses: Int {
        fires.filter { $0.fullySucceeded && $0.lockedAtFire }.count
    }

    var body: some View {
        List {
            verdictSection
            if !suggestedSweeps.isEmpty { scheduleSection }
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

    /// Computed from the real classes.yml rather than hardcoded, so it stays
    /// right when the schedule changes.
    private var scheduleSection: some View {
        Section {
            ForEach(suggestedSweeps, id: \.self) { t in
                HStack {
                    Image(systemName: "clock").foregroundStyle(Theme.accent)
                    Text(t).font(.body.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text("Mon–Fri").font(.caption).foregroundStyle(.secondary)
                }
            }
            Link(destination: URL(string: "shortcuts://")!) {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("Create \(suggestedSweeps.count) automations at these times")
        } footer: {
            Text("Each run books everything whose window has opened — it's a sweep, not one alarm per class, so these times don't change when you add or remove a class.\n\nYour booking windows open at:\n" + openTimes.map(\.label).joined(separator: "\n") + "\n\niOS gives apps no way to create automations, so these have to be added by hand — once.")
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
