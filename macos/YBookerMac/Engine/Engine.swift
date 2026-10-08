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

    @Published private(set) var classes = Store.classes()
    @Published private(set) var pauses = Store.pauses()

    private var loop: Task<Void, Never>?
    /// True from warm-up through the follow-up reads; edits must not cancel that.
    private var isFiring = false
    private var lastFailureNotice: Date?
    /// Keeps App Nap off and the Mac out of idle sleep for as long as the app runs
    /// (the display can still sleep). A Mac that's asleep at an opening can't wake
    /// itself in time — the process is frozen — so holding this only around each
    /// opening isn't enough. Quitting the app releases it.
    private let background = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "Waiting for class booking windows")

    /// Look ahead this far for occurrences (the Python engine uses 16 days).
    private let horizon: TimeInterval = 16 * 86400
    /// Re-plan this often even if nothing fired (classes get renamed, rescheduled…).
    private let replanEvery: TimeInterval = 3 * 3600
    /// Start waking up and warming the session this long before an opening.
    private let warmup: TimeInterval = 90

    init() {
        Notifier.requestPermission()
        LoginItem.enableOnFirstLaunch()
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

    // MARK: Editing

    func update(classes: [RecurringClass]) {
        self.classes = classes
        Store.save(classes: classes)
        replanSoon()
    }

    func update(pauses: [Pause]) {
        self.pauses = pauses
        Store.save(pauses: pauses)
        replanSoon()
    }

    /// Re-plan right away — unless an opening is in progress, in which case the
    /// loop re-plans as soon as it finishes (cancelling it mid-opening would lose it).
    private func replanSoon() {
        lastPlanned = nil
        if !isFiring, signedInAs != nil { start() }
    }

    func addClass(name: String, weekday: String, start: String, branchId: Int) {
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        var key = "\(slug)-\(weekday.lowercased())"
        var n = 2
        while classes.contains(where: { $0.key == key }) { key = "\(slug)-\(weekday.lowercased())-\(n)"; n += 1 }
        update(classes: classes + [RecurringClass(key: key, name: name, weekday: weekday, start: start,
                                                  locationIds: [branchId])])
    }

    func remove(_ slot: CatalogSlot) {
        update(classes: classes.filter { !slot.isSame(as: $0) })
    }

    /// Every weekly class slot at both branches, from the next two weeks of the
    /// live schedule. Personal-training style one-person slots are dropped.
    func loadCatalog() async throws -> [CatalogSlot] {
        _ = try await FisikalClient.shared.ensureSession()
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = FisikalClient.zone
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func hhmm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        var groups: [String: (branch: Int, occs: [Occurrence])] = [:]
        for branch in [1392, 1388] {
            // Two weeks covers each weekly slot twice; this week's sessions have
            // already opened for booking, so they carry fill-speed data.
            let occs = try await FisikalClient.shared.occurrences(
                locationIds: [branch], since: now.addingTimeInterval(-86400), till: now.addingTimeInterval(14 * 86400))
            for o in occs where o.capacity >= 5 {
                let wd = days[cal.component(.weekday, from: o.occursAt) - 1]
                let id = "\(o.title.lowercased())|\(wd)|\(hhmm(o.occursAt))|\(branch)"
                groups[id, default: (branch, [])].occs.append(o)
            }
        }
        return groups.values.compactMap { g -> CatalogSlot? in
            guard let first = g.occs.min(by: { $0.occursAt < $1.occursAt }) else { return nil }
            let upcoming = g.occs.filter { $0.occursAt > now }.min { $0.occursAt < $1.occursAt } ?? first
            let fills = g.occs.compactMap { o in o.fullGroupAt.map { $0.timeIntervalSince(o.openAt) } }.filter { $0 >= 0 }
            return CatalogSlot(
                name: first.title,
                weekday: days[cal.component(.weekday, from: first.occursAt) - 1],
                start: hhmm(first.occursAt),
                end: hhmm(first.occursAt.addingTimeInterval(Double(first.durationMinutes) * 60)),
                branchId: g.branch,
                rooms: Array(Set(g.occs.map(\.room).filter { !$0.isEmpty })).sorted(),
                trainers: Array(Set(g.occs.map(\.trainer).filter { !$0.isEmpty })).sorted(),
                capacity: g.occs.map(\.capacity).max() ?? 0,
                fastestFill: fills.min(),
                nextSession: upcoming.occursAt)
        }
    }

    /// Has the latest plan found an upcoming opening for this class? Catches typos
    /// in a class name or time — a class that matches nothing is never booked.
    func isOnSchedule(_ k: RecurringClass) -> Bool { openings.contains { $0.klass.key == k.key } }

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
            // Once an hour at most: a flaky YMCA server shouldn't spam the Mac.
            if lastFailureNotice.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                lastFailureNotice = Date()
                Notifier.post("Y Booker can't reach the YMCA", error.localizedDescription)
            }
        }
    }

    // MARK: The opening second

    private func fire(_ group: [Opening]) async {
        // Hold off App Nap and idle sleep from warm-up until the follow-ups are done.
        let urgent = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Class booking window opening")
        isFiring = true
        defer {
            ProcessInfo.processInfo.endActivity(urgent)
            isFiring = false
        }

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
        for e in entries { Notifier.post("\(e.className) · \(e.occursAt.formatted(.dateTime.weekday().month().day()))", summary(e)) }
        lastPlanned = nil   // re-plan to pick up next week's occurrence of these classes
    }

    /// One fresh read of a single occurrence, the way a booking would read it first.
    private nonisolated static func sample(_ o: Opening, index: Int)
        async -> (Int, ShadowEntry.Sample?, Date?, String?) {
        do {
            let around = o.occurrence.occursAt
            let sent = Date()
            let occs = try await FisikalClient.shared.occurrences(
                locationIds: o.klass.locationIds,
                since: around.addingTimeInterval(-60), till: around.addingTimeInterval(60))
            guard let fresh = occs.first(where: { $0.id == o.occurrence.id }) else {
                return (index, nil, nil, "occurrence \(o.occurrence.id) not found at the opening")
            }
            let s = ShadowEntry.Sample(at: Date(), sentAt: sent, isFull: fresh.isFull, isJoined: fresh.isJoined,
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
