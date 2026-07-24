import SwiftUI
import Combine

/// Scheduled bookings grouped by weekday, each with a live countdown to the
/// next time its booking *opens* (167h before class). Swipe a row to book that
/// class immediately via a book.yml workflow_dispatch (issue #47).
struct JobsView: View {
    @EnvironmentObject var classes: ClassesRepository
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    @State private var bookTarget: BookingJob?
    @State private var booking = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    /// Derive the next *future* open instant for each class.
    private var jobs: [BookingJob] {
        classes.classes.compactMap { c in
            guard let opens = nextOpen(for: c) else { return nil }
            return BookingJob(classKey: c.key, className: c.name, weekday: c.weekday,
                              classDate: opens.classDate, opensAt: opens.opensAt, state: .queued)
        }
    }

    private func jobs(on day: Weekday) -> [BookingJob] {
        jobs.filter { $0.weekday == day }.sorted { $0.opensAt < $1.opensAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                        Text("Each row counts down to when next week's booking **opens** (167h before class) — that's when the bot books it automatically. Swipe a row to book it now instead.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(weekdays, id: \.self) { day in
                    let dayJobs = jobs(on: day)
                    if !dayJobs.isEmpty {
                        Section(day.fullName) {
                            ForEach(dayJobs) { job in
                                JobRow(job: job, now: now)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            bookTarget = job
                                        } label: {
                                            Label("Book now", systemImage: "bolt.fill")
                                        }
                                        .tint(Theme.accent)
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scheduled Jobs")
            .onReceive(tick) { now = $0 }
            .refreshable { await classes.load() }
            .overlay { if booking { ProgressView("Booking…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .confirmationDialog(
                bookTarget.map { "Book \($0.className) (\($0.weekday.fullName)) now?" } ?? "",
                isPresented: Binding(get: { bookTarget != nil }, set: { if !$0 { bookTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Book now") { if let job = bookTarget { book(job) } }
                Button("Cancel", role: .cancel) { bookTarget = nil }
            } message: {
                Text("This triggers the booking workflow for this class immediately, ignoring any pause dates.")
            }
            .alert("Booking", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private func book(_ job: BookingJob) {
        bookTarget = nil
        booking = true
        Task {
            do {
                try await GitHubClient().dispatchBook(classKey: job.classKey)
                resultIsError = false
                resultMessage = "Requested a booking for \(job.className). It runs on GitHub Actions in a few seconds — check back on the Week view shortly."
            } catch {
                resultIsError = true
                resultMessage = "Couldn't start the booking: \(error). Check the token has Actions (write) permission."
            }
            booking = false
        }
    }

    private func nextOpen(for c: GymClass) -> (classDate: Date, opensAt: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let parts = c.start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = DateComponents()
        comps.weekday = (c.weekday.order + 1) % 7 + 1   // Calendar weekday: Sun=1..Sat=7
        comps.hour = parts[0]; comps.minute = parts[1]
        guard var classDate = cal.nextDate(after: Date(), matching: comps,
                                           matchingPolicy: .nextTime) else { return nil }
        var opensAt = cal.date(byAdding: .hour, value: -Config.bookOpenLeadHours, to: classDate)!
        // Walk forward a week at a time until we find the next open that is still in the future.
        while opensAt <= Date() {
            classDate = cal.date(byAdding: .day, value: 7, to: classDate)!
            opensAt = cal.date(byAdding: .hour, value: -Config.bookOpenLeadHours, to: classDate)!
        }
        return (classDate, opensAt)
    }
}

private struct JobRow: View {
    let job: BookingJob
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.className).font(.body.weight(.medium))
                Spacer()
                Text(countdownText).font(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
            Text("Books \(job.classDate.formatted(.dateTime.weekday().month().day())) · opens \(job.opensAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var countdownText: String {
        let secs = Int(job.opensAt.timeIntervalSince(now))
        if secs <= 0 { return "open" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
