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
    @Published private(set) var history: [FillRecord] = Store.fillHistory()
    /// Away dates and swaps: synced from the private repo, cached locally so a
    /// GitHub outage never stops a booking (the cached copy is used instead).
    @Published private(set) var pauses = Store.pauses()
    @Published private(set) var swaps = Store.swaps()
    @Published private(set) var lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
    @Published private(set) var syncError: String?
    private var lastSyncAttempt: Date?

    /// iCloud mirror for the companion app (#147). Never on the booking path.
    @Published private(set) var lastCloudPush = UserDefaults.standard.object(forKey: "lastCloudPush") as? Date
    @Published private(set) var cloudError: String?
    private var cloudPush: Task<Void, Never>?

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
    /// Pick up pauses.yml / swaps.yml changes this often (and right before every opening).
    private let syncEvery: TimeInterval = 600

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
        pushToCloudSoon()
    }

    // MARK: Away dates and swaps (from the private repo)

    /// Fetch pauses.yml and swaps.yml. Returns true if either changed. On any
    /// failure the cached copy stays in force — same fail-open rule as the
    /// Python engine, so a bad token can't silently stop bookings.
    @discardableResult
    func syncFromRepo() async -> Bool {
        lastSyncAttempt = Date()
        guard RepoSync.isEnabled else { syncError = nil; return false }
        do {
            async let p = RepoSync.fetch("pauses.yml")
            async let w = RepoSync.fetch("swaps.yml")
            let (pText, wText) = try await (p, w)
            guard let pText else { throw RepoSync.Failure.http(404, "pauses.yml") }
            let newPauses = RepoSync.parsePauses(pText)
            let newSwaps = wText.map(RepoSync.parseSwaps) ?? []   // no swaps.yml = no swaps
            let changed = newPauses != pauses || newSwaps != swaps
            if changed {
                pauses = newPauses
                swaps = newSwaps
                Store.save(pauses: newPauses)
                Store.save(swaps: newSwaps)
            }
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: "lastSynced")
            syncError = nil
            if changed { pushToCloudSoon() }
            return changed
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    func syncNow() async {
        if await syncFromRepo() { replanSoon() }
    }

    func setGitHub(repo: String, token: String?) async {
        RepoSync.setRepo(repo)
        if let token, !token.isEmpty { RepoSync.setToken(token) }
        await syncNow()
    }

    /// Why this class won't be booked on this date, if it won't: an away date
    /// (unless the class is in its `except:`), or a skip-only swap.
    func skipReason(_ k: RecurringClass, on date: Date) -> String? {
        if pauses.contains(where: { $0.covers(date, key: k.key) }) { return "away" }
        let day = Pause.day(date)
        if swaps.contains(where: { $0.date == day && $0.skip == k.key && $0.isSkipOnly }) { return "swap: skip" }
        return nil
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

    // MARK: Fill history

    /// Upsert every group class whose booking window has opened. `full_group_at`
    /// arrives for free with the schedule, so history costs no extra requests.
    private func recordHistory(_ occs: [Occurrence], branchId: Int) {
        let now = Date()
        var byId = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        for o in occs where o.capacity >= 5 && o.openAt <= now {
            if var r = byId[o.id] {
                r.fullGroupAt = o.fullGroupAt ?? r.fullGroupAt
                r.waitlist = max(r.waitlist, o.waitlist)
                r.lastSeen = now
                byId[o.id] = r
            } else {
                byId[o.id] = FillRecord(id: o.id, name: o.title, weekday: Slot.weekday(o.occursAt),
                                        start: Slot.hhmm(o.occursAt), branchId: branchId,
                                        occursAt: o.occursAt, openAt: o.openAt, capacity: o.capacity,
                                        fullGroupAt: o.fullGroupAt, waitlist: o.waitlist, lastSeen: now)
            }
        }
        history = Array(byId.values)
    }

    /// One-time: the API still serves the past few weeks (status Completed), so
    /// start with ~4 weeks of history instead of an empty table.
    private func backfillHistory() async {
        status = "Backfilling 4 weeks of class history…"
        let now = Date()
        for branch in [1392, 1388] {
            for week in 1...4 {
                let till = now.addingTimeInterval(-Double(week - 1) * 7 * 86400)
                if let occs = try? await FisikalClient.shared.occurrences(
                    locationIds: [branch], since: till.addingTimeInterval(-7 * 86400), till: till) {
                    recordHistory(occs, branchId: branch)
                }
            }
        }
        Store.save(fillHistory: history)
        UserDefaults.standard.set(true, forKey: "historyBackfilled")
    }

    /// Per weekly slot: how often it fills, how fast, waitlists, and — for your
    /// own classes the Mac has sampled — signups by 10 / 20 / 30 / 60 seconds.
    func slotStats() -> [SlotStats] {
        let curvesBySlot = Dictionary(grouping: log.filter { $0.atOpen != nil && !$0.followUps.isEmpty }) { e in
            classes.first { $0.key == e.classKey }?.slotKey ?? ""
        }
        return Dictionary(grouping: history, by: \.slotKey).map { key, recs in
            let fills = recs.compactMap(\.fillSeconds)
            let curves = curvesBySlot[key] ?? []
            var signups: [Int: Int] = [:]
            for t in [10, 20, 30, 60] {
                let xs = curves.compactMap { $0.signups(by: Double(t)) }.map(Double.init)
                if let m = median(xs) { signups[t] = Int(m.rounded()) }
            }
            let r = recs[0]
            return SlotStats(id: key, name: r.name, weekday: r.weekday, start: r.start, branchId: r.branchId,
                             weeks: recs.count, filledWeeks: fills.count, medianFill: median(fills),
                             fastestFill: fills.min(), filledWithinMinute: fills.filter { $0 <= 60 }.count,
                             medianWaitlist: median(recs.map { Double($0.waitlist) }).map { Int($0.rounded()) },
                             signupsBy: signups, curveWeeks: curves.count)
        }
    }

    func setBooksForReal(_ key: String, _ on: Bool) {
        update(classes: classes.map { k in
            guard k.key == key else { return k }
            var c = k
            c.liveBooking = on
            return c
        })
    }

    /// Has the latest plan found an upcoming opening for this class? Catches typos
    /// in a class name or time — a class that matches nothing is never booked.
    func isOnSchedule(_ k: RecurringClass) -> Bool { openings.contains { $0.klass.key == k.key } }

    // MARK: iCloud

    /// Push to iCloud a few seconds from now, coalescing bursts of changes. Waits
    /// out an opening in progress: the opening second never shares the network.
    func pushToCloudSoon(after delay: TimeInterval = 5) {
        cloudPush?.cancel()
        cloudPush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.isFiring { self.pushToCloudSoon(after: 30); return }
            await self.pushToCloud()
        }
    }

    func pushToCloud() async {
        let snap = CloudStore.Snapshot(
            classes: classes, pauses: pauses, swaps: swaps, log: log, stats: slotStats(),
            status: .init(updatedAt: Date(), status: status, signedInAs: signedInAs,
                          liveClasses: classes.filter(\.booksForReal).count,
                          nextOpening: openings.first?.openAt,
                          nextOpeningClasses: openings.filter { $0.openAt == openings.first?.openAt }.map(\.klass.name),
                          lastSynced: lastSynced, syncError: syncError))
        do {
            _ = try await CloudStore.shared.push(snap)
            lastCloudPush = Date()
            UserDefaults.standard.set(lastCloudPush, forKey: "lastCloudPush")
            cloudError = nil
        } catch {
            cloudError = error.localizedDescription
            // Try again later: iCloud being briefly unavailable (or a brand-new
            // container not yet known to the server) shouldn't wait for the next plan.
            pushToCloudSoon(after: 300)
        }
    }

    // MARK: Main loop

    func start() {
        loop?.cancel()
        loop = Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            if lastSyncAttempt.map({ Date().timeIntervalSince($0) >= syncEvery }) ?? true, !isFiring {
                if await syncFromRepo() { lastPlanned = nil }
            }
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
                let syncAt = (lastSyncAttempt ?? Date()).addingTimeInterval(syncEvery)
                await sleep(until: min(wakeAt, replanAt, syncAt))
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
            if !UserDefaults.standard.bool(forKey: "historyBackfilled") { await backfillHistory() }
            // Both branches every time, not just the ones in your lineup: the same
            // fetch feeds fill history for every class.
            for branch in [1392, 1388] {
                let occs = try await FisikalClient.shared.occurrences(
                    locationIds: [branch], since: now, till: now.addingTimeInterval(horizon))
                recordHistory(occs, branchId: branch)
                for k in classes where k.locationIds.contains(branch) {
                    for o in occs where k.matches(o) && o.openAt > now {
                        found.append(Opening(klass: k, occurrence: o, paused: skipReason(k, on: o.occursAt) != nil))
                    }
                }
            }
            openings = found.sorted { $0.openAt < $1.openAt }
            Store.save(fillHistory: history)
            lastPlanned = Date()
            status = "Planned \(openings.count) upcoming openings"
            pushToCloudSoon()   // fresh stats, next opening, heartbeat
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

    private func fire(_ planned: [Opening]) async {
        // Hold off App Nap and idle sleep from warm-up until the follow-ups are done.
        let urgent = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Class booking window opening")
        isFiring = true
        defer {
            ProcessInfo.processInfo.endActivity(urgent)
            isFiring = false
        }

        // Last look at the away dates and swaps, so a change made minutes ago
        // counts. Bounded by RepoSync's short timeout; on failure the cached copy stands.
        await syncFromRepo()
        let group = planned.map {
            Opening(klass: $0.klass, occurrence: $0.occurrence, paused: skipReason($0.klass, on: $0.occurrence.occursAt) != nil)
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

        // The opening second. Classes switched to "book for real" send the join
        // first, then read back; shadow-only classes just take the read.
        await withTaskGroup(of: (Int, ShadowEntry.BookingLog?).self) { tg in
            for (i, o) in group.enumerated() where !o.paused && entries[i].error == nil && o.klass.booksForReal {
                tg.addTask { (i, await Self.book(o)) }
            }
            for await (i, log) in tg { entries[i].booking = log }
        }
        await withTaskGroup(of: (Int, ShadowEntry.Sample?, Date?, String?).self) { tg in
            for (i, o) in group.enumerated() where !o.paused && entries[i].error == nil {
                tg.addTask { await Self.sample(o, index: i) }
            }
            for await (i, s, fullAt, err) in tg {
                entries[i].firedAt = s?.at ?? Date()
                entries[i].atOpen = s
                entries[i].fullGroupAt = fullAt
                entries[i].error = entries[i].booking == nil ? err : nil
            }
        }
        record(entries)
        // The booking is decided; send the result to iCloud now (the phone's alert
        // comes from it) rather than after the follow-up reads ~5 minutes later.
        Task { await pushToCloud() }
        for e in entries where e.booking != nil {
            Notifier.post("\(e.booking!.booked ? "✅" : "❌") \(e.className) · \(e.occursAt.formatted(.dateTime.weekday().month().day()))",
                          e.booking!.outcome)
        }

        // Watch it fill: every 3 s for the first minute, then +2 m and +5 m. These
        // reads only measure. They start 2 s after the opening so they never
        // compete with the booking itself, which is decided in the first second.
        let dense = Array(stride(from: 2.0, through: 59.0, by: 3.0))
        for delay in dense + [120, 300] {
            let live = group.indices.filter { i in
                !group[i].paused && entries[i].error == nil
                    // Once full, stop the 3 s polling; the +2 m / +5 m checks still track the waitlist.
                    && (delay > 60 || !(entries[i].followUps.last?.isFull ?? entries[i].atOpen?.isFull ?? false))
            }
            if live.isEmpty { continue }
            await sleep(until: openAt.addingTimeInterval(delay))
            for i in live {
                let (_, s, fullAt, _) = await Self.sample(group[i], index: i)
                if let s { entries[i].followUps.append(s) }
                if let fullAt { entries[i].fullGroupAt = fullAt }
            }
            if delay > 60 || delay == dense.last { record(entries) }
        }
        for e in entries { Notifier.post("\(e.className) · \(e.occursAt.formatted(.dateTime.weekday().month().day()))", summary(e)) }
        lastPlanned = nil   // re-plan to pick up next week's occurrence of these classes
        pushToCloudSoon()
    }

    /// A real booking attempt at the opening second, mirroring src/main.py's book():
    /// retry "not open yet" (clock skew) and lock conflicts (with a fresh
    /// lock_version), stop on full/terminal errors, and treat "taken" as success
    /// only if a re-read shows the seat is ours (another trigger won the race).
    private nonisolated static func book(_ o: Opening) async -> ShadowEntry.BookingLog {
        var log = ShadowEntry.BookingLog()
        var lock = o.occurrence.lockVersion
        let retryable: Set<String> = ["advance_time_restriction", "lock_version_conflict", "stale_object", "optimistic_lock"]
        let lockConflict: Set<String> = ["lock_version_conflict", "stale_object", "optimistic_lock"]
        let race: Set<String> = ["taken", "already_joined"]
        let terminal: Set<String> = ["spare_schedule_violation", "already_joined", "full", "no_spaces", "group_is_full", "taken"]

        for attempt in 1...6 {
            let r: FisikalClient.JoinResult
            do {
                r = try await FisikalClient.shared.join(occurrenceId: o.occurrence.id, lockVersion: lock)
            } catch {
                log.attempts.append(.init(sentAt: Date(), repliedAt: nil, result: error.localizedDescription))
                if case FisikalClient.Failure.sessionExpired = error { _ = try? await FisikalClient.shared.ensureSession() }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            log.attempts.append(.init(sentAt: r.sentAt, repliedAt: r.repliedAt, result: r.message))
            let types = Set(r.errorTypes)
            if r.ok {
                log.booked = true
                log.outcome = "BOOKED by the Mac (attempt \(attempt))"
                return log
            }
            if !types.isDisjoint(with: race) {
                let (_, s, _, _) = await sample(o, index: 0)
                log.booked = s?.isJoined ?? false
                log.outcome = log.booked ? "already booked — another trigger got there first"
                                         : "taken by someone else (\(r.message))"
                return log
            }
            if !types.isDisjoint(with: terminal) {
                log.outcome = "not booked — \(r.message)"
                return log
            }
            if !types.isDisjoint(with: lockConflict) {
                let (_, s, _, _) = await sample(o, index: 0)
                if let v = s?.lockVersion { lock = v }
                continue
            }
            // "Not open yet" (our clock a hair ahead of theirs) or something unknown: brief pause, retry.
            try? await Task.sleep(nanoseconds: types.isDisjoint(with: retryable) ? 1_000_000_000 : 250_000_000)
        }
        log.outcome = "not booked — gave up after \(log.attempts.count) attempts (last: \(log.attempts.last?.result ?? "?"))"
        return log
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
