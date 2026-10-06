import AppKit
import Foundation

/// Shadow-mode booking engine. Works out each class's opening instant from the
/// YMCA's own data, and at that second does everything a real booking would —
/// fresh session, fresh read of the occurrence — except the join itself.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var signedInAs: String? = FisikalClient.username
    @Published private(set) var openings: [Opening] = []
    @Published private(set) var log: [ShadowEntry] = Store.shadowLog()
    @Published private(set) var status = "Starting…"
    @Published private(set) var lastPlanned: Date?

    let classes = Store.classes()
    let pauses = Store.pauses()

    private var loop: Task<Void, Never>?
    /// Keeps App Nap from stretching our timers while we sit in the menu bar.
    private let background = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Waiting for class booking windows")

    /// Look ahead this far for occurrences (the Python engine uses 16 days).
    private let horizon: TimeInterval = 16 * 86400
    /// Re-plan this often even if nothing fired (classes get renamed, rescheduled…).
    private let replanEvery: TimeInterval = 3 * 3600
    /// Start waking up and warming the session this long before an opening.
    private let warmup: TimeInterval = 90

    init() {
        if signedInAs != nil { start() }
    }

    // MARK: Account

    func signIn(username: String, password: String) async throws {
        try await FisikalClient.shared.signIn(username: username, password: password)
        signedInAs = username
        start()
    }

    func signOut() async {
        loop?.cancel()
        await FisikalClient.shared.signOut()
        signedInAs = nil
        openings = []
        status = "Signed out"
    }

    func clearLog() {
        log = []
        Store.save(shadowLog: log)
    }

    // MARK: Main loop

    func start() {
        loop?.cancel()
        loop = Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            if lastPlanned.map({ Date().timeIntervalSince($0) > replanEvery }) ?? true || openings.isEmpty {
                await plan()
            }
            guard let next = openings.first else {
                status = "No upcoming openings found — retrying in 10 min"
                await sleep(until: Date().addingTimeInterval(600))
                continue
            }
            let group = openings.filter { $0.openAt == next.openAt }
            // Coarse wait in short hops so a Mac sleep/wake or a re-plan can't strand us.
            let wakeAt = next.openAt.addingTimeInterval(-warmup)
            let replanAt = (lastPlanned ?? Date()).addingTimeInterval(replanEvery)
            if Date() < wakeAt {
                status = "Next: \(group.map(\.klass.name).joined(separator: " + ")) opens \(next.openAt.formatted(date: .abbreviated, time: .standard))"
                await sleep(until: min(wakeAt, replanAt))
                continue
            }
            await fire(group)
            openings.removeAll { o in group.contains { $0.id == o.id } }
        }
    }

    /// Fetch occurrences per branch and turn every class into its upcoming opening instants.
    func plan() async {
        status = "Planning…"
        do {
            _ = try await FisikalClient.shared.ensureSession()
            let now = Date()
            var found: [Opening] = []
            for branch in Set(classes.flatMap(\.locationIds)).sorted() {
                let occs = try await FisikalClient.shared.occurrences(
                    locationIds: [branch], since: now, till: now.addingTimeInterval(horizon))
                for k in classes where k.locationIds.contains(branch) {
                    for o in occs where k.matches(o) && o.openAt > now {
                        let paused = pauses.contains { $0.covers(o.occursAt, key: k.key) }
                        found.append(Opening(klass: k, occurrence: o, paused: paused))
                    }
                }
            }
            openings = found.sorted { $0.openAt < $1.openAt }
            lastPlanned = Date()
            status = "Planned \(openings.count) upcoming openings"
        } catch {
            status = "Planning failed: \(error.localizedDescription)"
        }
    }

    // MARK: The opening second

    private func fire(_ group: [Opening]) async {
        // Hold off App Nap and idle sleep from warm-up until the follow-ups are done.
        let urgent = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Class booking window opening")
        defer { ProcessInfo.processInfo.endActivity(urgent) }

        var entries = group.map {
            ShadowEntry(classKey: $0.klass.key, className: $0.klass.name, occurrenceId: $0.occurrence.id,
                        occursAt: $0.occurrence.occursAt, openAt: $0.openAt, paused: $0.paused,
                        capacity: $0.occurrence.capacity)
        }
        let live = group.filter { !$0.paused }
        status = "Opening soon: \(group.map(\.klass.name).joined(separator: " + "))"

        // Warm the session now, so the opening second is a single request.
        if !live.isEmpty {
            do {
                let path = try await FisikalClient.shared.ensureSession()
                for i in entries.indices where !entries[i].paused {
                    entries[i].sessionPath = path
                    entries[i].sessionReadyAt = Date()
                }
            } catch {
                for i in entries.indices where !entries[i].paused { entries[i].error = error.localizedDescription }
            }
        }

        // Spin the last stretch so the read lands on the opening instant, not up to a hop late.
        let openAt = group[0].openAt
        while Date() < openAt.addingTimeInterval(-1) { try? await Task.sleep(nanoseconds: 200_000_000) }
        while Date() < openAt { try? await Task.sleep(nanoseconds: 5_000_000) }

        // This is where a real booking would send the join.
        await withTaskGroup(of: (Int, ShadowEntry.Sample?, Date?, String?).self) { tg in
            for (i, o) in group.enumerated() where !o.paused && entries[i].error == nil {
                tg.addTask { await Self.sample(o, index: i) }
            }
            for await (i, s, fullAt, err) in tg {
                entries[i].firedAt = s?.at ?? Date()
                entries[i].atOpen = s
                entries[i].fullGroupAt = fullAt
                entries[i].error = err
            }
        }
        record(entries)

        // Watch how fast it fills: these reads only measure, they never book.
        for delay in [30.0, 120, 300] {
            await sleep(until: openAt.addingTimeInterval(delay))
            for (i, o) in group.enumerated() where !o.paused {
                let (_, s, fullAt, _) = await Self.sample(o, index: i)
                if let s { entries[i].followUps.append(s) }
                if let fullAt { entries[i].fullGroupAt = fullAt }
            }
            record(entries)
        }
        lastPlanned = nil   // re-plan to pick up next week's occurrence of these classes
    }

    /// One fresh read of a single occurrence, the way a booking would read it first.
    private nonisolated static func sample(_ o: Opening, index: Int)
        async -> (Int, ShadowEntry.Sample?, Date?, String?) {
        do {
            let around = o.occurrence.occursAt
            let occs = try await FisikalClient.shared.occurrences(
                locationIds: o.klass.locationIds,
                since: around.addingTimeInterval(-60), till: around.addingTimeInterval(60))
            guard let fresh = occs.first(where: { $0.id == o.occurrence.id }) else {
                return (index, nil, nil, "occurrence \(o.occurrence.id) not found at the opening")
            }
            let s = ShadowEntry.Sample(at: Date(), isFull: fresh.isFull, isJoined: fresh.isJoined,
                                       lockVersion: fresh.lockVersion, waitlist: fresh.waitlist)
            return (index, s, fresh.fullGroupAt, nil)
        } catch {
            return (index, nil, nil, error.localizedDescription)
        }
    }

    private func record(_ entries: [ShadowEntry]) {
        for e in entries {
            if let i = log.firstIndex(where: { $0.id == e.id }) { log[i] = e } else { log.append(e) }
        }
        Store.save(shadowLog: log)
    }

    private func sleep(until date: Date) async {
        while !Task.isCancelled {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
        }
    }
}
