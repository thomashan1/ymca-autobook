#if os(macOS)
import AppKit
import Foundation

/// Shadow-mode booking engine. Works out each class's opening instant from the
/// YMCA's own data, and at that second does everything a real booking would —
/// fresh session, fresh read of the occurrence — except the join itself.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var signedInAs: String? = FisikalClient.username
    @Published private(set) var openings: [Opening] = []
    /// What the YMCA has us booked into, refreshed with every plan (and so right
    /// after each opening, which clears lastPlanned).
    private(set) var bookings: [CloudStore.Booking]?
    @Published private(set) var log: [ShadowEntry] = Store.shadowLog()
    @Published private(set) var status = "Starting…"
    @Published private(set) var lastPlanned: Date?

    @Published private(set) var classes = Store.classes()
    @Published private(set) var history: [FillRecord] = Store.fillHistory()
    /// Away dates, kept here (and in iCloud). `swaps` are hand-written one-day
    /// swaps carried over from the private repo's swaps.yml before 10/14.
    @Published private(set) var pauses = Store.pauses()
    @Published private(set) var swaps = Store.swaps()
    /// When the GitHub backup's copy was last brought up to date, and why not.
    @Published private(set) var lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
    @Published private(set) var syncError: String?
    private var lastRepoCheck: Date?
    private var repoPush: Task<Void, Never>?
    /// Lineup sessions' class keys by occurrence id, from the last plan.
    private var lineupKeys: [Int: String] = [:]
    /// Modification dates of the JSON files as the app last read or wrote them.
    private var diskStamps: [String: Date] = ["classes.json": Store.modified("classes.json"),
                                              "pauses.json": Store.modified("pauses.json")].compactMapValues { $0 }

    /// Sessions picked to book outside the lineup, here or from the iPhone.
    @Published private(set) var picks = Store.picks()
    /// Lineup sessions not to book this time ("skip this one").
    @Published private(set) var skips = Store.skips()
    /// Bookings being cancelled right now.
    @Published private(set) var cancelling: Set<Int> = []
    /// Every upcoming group class at both branches, from the last plan; nil
    /// until the first plan since launch.
    @Published private(set) var schedule: [ScheduleItem]?
    /// Picks being booked right now (their window was already open).
    @Published private(set) var bookingNow: Set<Int> = []
    private var inboxLoop: Task<Void, Never>?
    /// How often to look for requests from the iPhone.
    private let inboxEvery: TimeInterval = 30

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
    /// Check the GitHub backup's copy is current this often (and retry a failed write).
    private let syncEvery: TimeInterval = 600

    init() {
        Notifier.requestPermission()
        LoginItem.registerIfWanted()
        if signedInAs != nil { start(); startInbox() }
    }

    // MARK: Account

    func signIn(username: String, password: String) async throws {
        try await FisikalClient.shared.signIn(username: username, password: password)
        signedInAs = username
        start()
        startInbox()
    }

    func signOut() async {
        loop?.cancel()
        inboxLoop?.cancel()
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
        noteOwnWrite("classes.json")
        replanSoon()
        pushToCloudSoon()
        publishToRepoSoon()
    }

    // MARK: Picked sessions (one-off bookings)

    /// Book this session: now if its window is open, otherwise at the second it opens.
    func pick(_ p: ClassPick) {
        guard !picks.contains(where: { $0.id == p.id }) else { return }
        update(picks: picks + [p])
    }

    func unpick(_ id: Int) {
        update(picks: picks.filter { $0.id != id })
    }

    /// Don't book this session of a lineup class. With a GitHub repo set, the
    /// skip is also written to its swaps.yml so the GitHub backup skips it too.
    func skip(_ p: ClassPick) {
        guard !skips.contains(where: { $0.id == p.id }) else { return }
        setSkips(skips + [p])
        replanSoon()
    }

    func unskip(_ id: Int) {
        setSkips(skips.filter { $0.id != id })
        replanSoon()
    }

    private func setSkips(_ new: [ClassPick]) {
        let kept = new.filter { $0.occursAt > Date() }.sorted { $0.occursAt < $1.occursAt }
        guard kept != skips else { return }
        skips = kept
        Store.save(skips: skips)
        pushToCloudSoon()
        publishToRepoSoon()
    }

    func isSkipped(_ occurrenceId: Int) -> Bool { skips.contains { $0.id == occurrenceId } }

    /// What this session is to us: booked, queued, open… and so what can be done.
    func state(of i: ScheduleItem) -> SessionState {
        if cancelling.contains(i.id) { return .booking }
        return SessionState(i, picked: picks.contains { $0.id == i.id } || bookingNow.contains(i.id),
                            skipped: isSkipped(i.id))
    }

    /// Do a session's action, from the Mac's own window or from the iPhone.
    func perform(_ action: Cloud.Request.Action, on p: ClassPick) {
        switch action {
        case .book: setSkips(skips.filter { $0.id != p.id }); pick(p)
        case .withdraw: unpick(p.id)
        case .skip: skip(p)
        case .unskip: unskip(p.id)
        case .cancel: Task { await cancelBooking(p) }
        }
    }

    /// Give a booked seat back, then read the session again to be sure.
    func cancelBooking(_ p: ClassPick) async {
        guard !cancelling.contains(p.id) else { return }
        cancelling.insert(p.id)
        defer { cancelling.remove(p.id) }
        while isFiring { await sleep(until: Date().addingTimeInterval(5)) }
        var outcome: String
        var ok = false
        do {
            _ = try await FisikalClient.shared.ensureSession()
            var r = try await FisikalClient.shared.cancel(occurrenceId: p.occurrenceId)
            if !r.ok, try await isJoined(p) != false {
                // One retry with a fresh session: the stored one may have just expired.
                _ = try await FisikalClient.shared.ensureSession()
                r = try await FisikalClient.shared.cancel(occurrenceId: p.occurrenceId)
            }
            let still = try await isJoined(p)
            ok = still == false
            outcome = ok ? "cancelled" : "not cancelled — \(r.message)"
        } catch {
            outcome = "not cancelled — \(error.localizedDescription)"
        }
        // A lineup class would otherwise be booked again if its window is still ahead.
        if ok, p.openAt > Date() { setSkips(skips + [p]) }
        Notifier.post("\(ok ? "🗑" : "❌") \(p.name) · \(p.occursAt.formatted(.dateTime.weekday().month().day()))", outcome)
        replanSoon()   // refreshes the booking list and pushes it to the phone
    }

    private func isJoined(_ p: ClassPick) async throws -> Bool? {
        let occs = try await FisikalClient.shared.occurrences(
            locationIds: [p.branchId], since: p.occursAt.addingTimeInterval(-60), till: p.occursAt.addingTimeInterval(60))
        return occs.first { $0.id == p.occurrenceId }?.isJoined
    }

    private func update(picks new: [ClassPick]) {
        setPicks(new)
        // The plan sorts them out: an opening to wait for, or a booking right now.
        replanSoon()
    }

    private func setPicks(_ new: [ClassPick]) {
        guard new != picks else { return }
        picks = new.sorted { $0.openAt < $1.openAt }
        Store.save(picks: picks)
        pushToCloudSoon()
        publishToRepoSoon()
    }

    private func dropPicks(_ ids: some Collection<Int>) {
        setPicks(picks.filter { !ids.contains($0.id) })
    }

    /// Book a picked session whose window is already open: the same join and
    /// read-back as at an opening, just not timed to the second.
    func bookNow(_ p: ClassPick) async {
        guard !bookingNow.contains(p.id) else { return }
        bookingNow.insert(p.id)
        defer { bookingNow.remove(p.id) }
        while isFiring { await sleep(until: Date().addingTimeInterval(5)) }

        let k = RecurringClass.oneOff(p)
        var entry = ShadowEntry(classKey: k.key, className: p.name, occurrenceId: p.occurrenceId,
                                occursAt: p.occursAt, openAt: p.openAt, paused: false)
        do {
            entry.sessionPath = try await FisikalClient.shared.ensureSession()
            entry.sessionReadyAt = Date()
            let occs = try await FisikalClient.shared.occurrences(
                locationIds: [p.branchId], since: p.occursAt.addingTimeInterval(-60), till: p.occursAt.addingTimeInterval(60))
            guard let o = occs.first(where: { $0.id == p.occurrenceId }) else {
                throw PickFailure.notOnSchedule
            }
            entry.capacity = o.capacity
            if o.isJoined {   // booked already, by hand or another trigger
                dropPicks([p.id])
                return
            }
            let opening = Opening(klass: k, occurrence: o, paused: false)
            entry.booking = await Self.book(opening)
            let (_, s, fullAt, _) = await Self.sample(opening, index: 0)
            entry.firedAt = s?.at ?? Date()
            entry.atOpen = s
            entry.fullGroupAt = fullAt ?? o.fullGroupAt
        } catch {
            entry.error = error.localizedDescription
        }
        record([entry])
        dropPicks([p.id])
        Notifier.post("\(entry.booking?.booked == true ? "✅" : "❌") \(p.name) · \(p.occursAt.formatted(.dateTime.weekday().month().day()))",
                      entry.verdict)
        replanSoon()   // refreshes the booking list, then pushes it
        pushToCloudSoon(after: 1)   // the phone's alert comes from this result
    }

    enum PickFailure: LocalizedError {
        case notOnSchedule
        var errorDescription: String? { "That session is no longer on the YMCA schedule" }
    }

    private func startInbox() {
        inboxLoop?.cancel()
        inboxLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkInbox()
                try? await Task.sleep(nanoseconds: UInt64((self?.inboxEvery ?? 30) * 1_000_000_000))
            }
        }
    }

    /// Act on requests from the iPhone: add or remove picks, then delete them.
    private func checkInbox() async {
        guard !isFiring, signedInAs != nil else { return }
        guard let requests = try? await CloudStore.shared.inbox(), !requests.isEmpty else { return }
        let (newPicks, newSkips) = PickTriage.apply(requests, picks: picks, skips: skips)
        setSkips(newSkips)
        update(picks: newPicks)
        for q in requests where q.action == .cancel { Task { await cancelBooking(q.pick) } }
        await CloudStore.shared.delete(requests: requests)
    }

    // MARK: Away dates

    func addPause(_ p: Pause) {
        setPauses(pauses.filter { $0.id != p.id } + [p])
    }

    func removePause(_ p: Pause) {
        setPauses(pauses.filter { $0.id != p.id })
    }

    private func setPauses(_ new: [Pause]) {
        pauses = new.sorted { $0.start < $1.start }
        Store.save(pauses: pauses)
        noteOwnWrite("pauses.json")
        replanSoon()
        pushToCloudSoon()
        publishToRepoSoon()
    }

    // MARK: The GitHub backup's copy (one way: Mac → repo)

    /// Before 10/14 the private repo was where away dates and swaps were edited
    /// and the Mac read them from it. On the first launch since, read them one
    /// last time so nothing edited there is lost; from then on the Mac only writes.
    private func importFromRepoOnce() async {
        guard RepoSync.isEnabled, !UserDefaults.standard.bool(forKey: "repoImported") else { return }
        do {
            async let p = RepoSync.fetch("pauses.yml")
            async let w = RepoSync.fetch("swaps.yml")
            let (pText, wText) = try await (p, w)
            if let pText { pauses = RepoSync.parsePauses(pText); Store.save(pauses: pauses); noteOwnWrite("pauses.json") }
            swaps = wText.map(RepoSync.parseSwaps)?.filter { !$0.isPast && $0.note != "Skipped in YMCA Booker" } ?? []
            Store.save(swaps: swaps)
            UserDefaults.standard.set(true, forKey: "repoImported")
            replanSoon()
        } catch {
            syncError = "Couldn't read away dates from GitHub one last time: \(error.localizedDescription)"
        }
    }

    /// Write classes.yml, pauses.yml and swaps.yml into the repo where they differ
    /// from what was last written. Cheap when nothing changed (no network).
    func publishToRepo(force: Bool = false) async {
        guard RepoSync.isEnabled, !isFiring else { return }
        await importFromRepoOnce()
        guard UserDefaults.standard.bool(forKey: "repoImported") else { return }   // never overwrite unread edits
        let skipPairs = skips.compactMap { s in lineupKeys[s.id].map { (date: Pause.day(s.occursAt), key: $0) } }
        let files = [
            "classes.yml": RepoMirror.classesYAML(classes, timeZone: FisikalClient.zone.identifier),
            "pauses.yml": RepoMirror.pausesYAML(pauses),
            "swaps.yml": RepoMirror.swapsYAML(swaps: swaps, skips: skipPairs, picks: picks),
        ]
        var written = UserDefaults.standard.dictionary(forKey: "repoWritten") as? [String: String] ?? [:]
        do {
            for path in RepoMirror.paths {
                guard let text = files[path], force || written[path] != text else { continue }
                try await RepoSync.update(path, message: "YMCA Booker: update \(path)") { _ in text }
                written[path] = text
                UserDefaults.standard.set(written, forKey: "repoWritten")
            }
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: "lastSynced")
            syncError = nil
        } catch {
            syncError = "GitHub backup not updated: \(error.localizedDescription)"
        }
    }

    private func publishToRepoSoon() {
        repoPush?.cancel()
        repoPush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.publishToRepo()
        }
    }

    func setGitHub(repo: String, token: String?) async {
        RepoSync.setRepo(repo)
        if let token, !token.isEmpty { RepoSync.setToken(token) }
        await publishToRepo(force: true)
    }

    /// Stop writing the backup copy and forget the repo and token. The files
    /// already in the repo stay as they are.
    func turnOffGitHub() {
        repoPush?.cancel()
        RepoSync.setRepo("")
        RepoSync.setToken("")
        UserDefaults.standard.removeObject(forKey: "repoWritten")
        syncError = nil
        lastSynced = nil
        UserDefaults.standard.removeObject(forKey: "lastSynced")
    }

    // MARK: Edits made to the JSON files on disk (e.g. by Claude)

    /// classes.json and pauses.json can be edited in place while the app runs;
    /// the loop picks a change up on its next pass. The app's own saves are noted
    /// so they don't count as outside edits.
    private func noteOwnWrite(_ name: String) { diskStamps[name] = Store.modified(name) }

    private func reloadEditedFiles() {
        var changed = false
        if Store.modified("classes.json") != diskStamps["classes.json"] {
            noteOwnWrite("classes.json")
            let c = Store.classes()
            if c != classes { classes = c; changed = true }
        }
        if Store.modified("pauses.json") != diskStamps["pauses.json"] {
            noteOwnWrite("pauses.json")
            let p = Store.pauses()
            if p != pauses { pauses = p; changed = true }
        }
        if changed { lastPlanned = nil; pushToCloudSoon(); publishToRepoSoon() }
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
            classes: classes, pauses: pauses, swaps: swaps, log: log, stats: slotStats(), bookings: bookings,
            picks: picks, skips: skips, schedule: schedule,
            status: .init(updatedAt: Date(), status: status, signedInAs: signedInAs,
                          liveClasses: classes.count,
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
            reloadEditedFiles()
            if lastRepoCheck.map({ Date().timeIntervalSince($0) >= syncEvery }) ?? true, !isFiring {
                lastRepoCheck = Date()
                await publishToRepo()
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
                let syncAt = (lastRepoCheck ?? Date()).addingTimeInterval(syncEvery)
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
            var joined: [CloudStore.Booking] = []
            var upcoming: [ScheduleItem] = []
            var byId: [Int: Occurrence] = [:]
            if !UserDefaults.standard.bool(forKey: "historyBackfilled") { await backfillHistory() }
            // Both branches every time, not just the ones in your lineup: the same
            // fetch feeds fill history for every class.
            for branch in [1392, 1388] {
                let occs = try await FisikalClient.shared.occurrences(
                    locationIds: [branch], since: now, till: now.addingTimeInterval(horizon))
                recordHistory(occs, branchId: branch)
                joined += occs.filter(\.isJoined).map {
                    .init(occurrenceId: $0.id, name: $0.title, occursAt: $0.occursAt, minutes: $0.durationMinutes,
                          branchId: branch, room: $0.room, trainer: $0.trainer)
                }
                for k in classes where k.locationIds.contains(branch) {
                    for o in occs where k.matches(o) && o.openAt > now {
                        found.append(Opening(klass: k, occurrence: o,
                                             paused: skipReason(k, on: o.occursAt) != nil || isSkipped(o.id)))
                    }
                }
                for o in occs where o.capacity >= 5 && o.occursAt > now {
                    byId[o.id] = o
                    upcoming.append(ScheduleItem(
                        id: o.id, name: o.title, occursAt: o.occursAt, openAt: o.openAt, minutes: o.durationMinutes,
                        branchId: branch, room: o.room, trainer: o.trainer, capacity: o.capacity,
                        full: o.isFull, joined: o.isJoined, autoBook: false))
                }
            }
            // Picked sessions: wait for the opening, book now, or let go.
            let lineup = Set(found.filter { !$0.paused }.map(\.occurrence.id))
            let triage = PickTriage.run(picks, seen: byId.mapValues { ($0.isJoined, $0.openAt) }, lineup: lineup, now: now)
            for p in picks where triage.atOpening.contains(p.id) {
                if let o = byId[p.id] { found.append(Opening(klass: .oneOff(p), occurrence: o, paused: false)) }
            }
            dropPicks(triage.drop)
            setSkips(skips)   // let past ones go
            lineupKeys = Dictionary(found.map { ($0.occurrence.id, $0.klass.key) }) { a, _ in a }
                .filter { !$0.value.hasPrefix(RecurringClass.oneOffPrefix) }
            publishToRepoSoon()
            for p in picks where triage.now.contains(p.id) { Task { await bookNow(p) } }

            schedule = upcoming
                .map { i in ScheduleItem(id: i.id, name: i.name, occursAt: i.occursAt, openAt: i.openAt,
                                         minutes: i.minutes, branchId: i.branchId, room: i.room, trainer: i.trainer,
                                         capacity: i.capacity, full: i.full, joined: i.joined,
                                         autoBook: lineup.contains(i.id)) }
                .sorted { ($0.occursAt, $0.id) < ($1.occursAt, $1.id) }
            openings = found.sorted { $0.openAt < $1.openAt }
            bookings = joined.sorted { $0.occursAt < $1.occursAt }
            Store.save(fillHistory: history)
            lastPlanned = Date()
            status = "Planned \(openings.count) upcoming openings"
            pushToCloudSoon()   // fresh stats, next opening, heartbeat
        } catch {
            status = "Planning failed: \(error.localizedDescription)"
            // Once an hour at most: a flaky YMCA server shouldn't spam the Mac.
            if lastFailureNotice.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                lastFailureNotice = Date()
                Notifier.post("YMCA Booker can't reach the YMCA", error.localizedDescription)
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

        // An away date written into pauses.json a minute ago still counts.
        reloadEditedFiles()
        let group = planned.map {
            Opening(klass: $0.klass, occurrence: $0.occurrence,
                    paused: !$0.klass.isOneOff && (skipReason($0.klass, on: $0.occurrence.occursAt) != nil
                                                   || isSkipped($0.occurrence.id)))
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

        // The opening second: send the join first, then read back.
        await withTaskGroup(of: (Int, ShadowEntry.BookingLog?).self) { tg in
            for (i, o) in group.enumerated() where !o.paused && entries[i].error == nil {
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
        dropPicks(group.filter(\.klass.isOneOff).map(\.occurrence.id))
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
#endif
