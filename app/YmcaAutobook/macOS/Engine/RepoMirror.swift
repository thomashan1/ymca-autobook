#if os(macOS)
import Foundation

/// The Mac is where classes, away dates and one-day changes are kept and edited
/// (since 2026-10-14), synced to the iPhone through iCloud. With a GitHub repo
/// set, the Mac also writes them into that repo as classes.yml, pauses.yml and
/// swaps.yml after every change, so the GitHub booker can act as a backup. One
/// way only: the Mac never reads these files back.
enum RepoMirror {
    static let paths = ["classes.yml", "pauses.yml", "swaps.yml"]

    private static let header = """
        # Written by YMCA Booker on the Mac, where this is edited (or from the iPhone).
        # Edits made here are overwritten the next time the Mac's copy changes.

        """

    static func classesYAML(_ classes: [RecurringClass], timeZone: String) -> String {
        var out = header + """

            timezone: \(timeZone)

            # Branches --list / browse query: Southwest = 1392, Northwest = 1388.
            list_location_ids: [1392, 1388]

            classes:
            """
        let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        for c in classes.filter({ !$0.isOneOff })
            .sorted(by: { (order.firstIndex(of: $0.weekday) ?? 9, $0.start) < (order.firstIndex(of: $1.weekday) ?? 9, $1.start) }) {
            out += """

                  - key: \(c.key)
                    name: \(quote(c.name))
                    weekday: \(c.weekday)
                    start: "\(c.start)"
                    location_ids: \(list(c.locationIds))
                """
            if let leads = c.extraLeads, !leads.isEmpty { out += "\n    extra_leads: \(list(leads))" }
        }
        return out + "\n"
    }

    static func pausesYAML(_ pauses: [Pause]) -> String {
        var out = header + "\npauses:"
        if pauses.isEmpty { return out + " []\n" }
        for p in pauses.sorted(by: { $0.start < $1.start }) {
            var line = "  - {start: \(p.start), end: \(p.end)"
            if let ex = p.except, !ex.isEmpty { line += ", except: [\(ex.joined(separator: ", "))]" }
            line += "}"
            if let note = p.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                line += "  # " + note.replacingOccurrences(of: "\n", with: " ")
            }
            out += "\n" + line
        }
        return out + "\n"
    }

    /// One-day changes, in the swaps.yml shape GitHub's engine reads:
    /// - `swaps`: entries carried over from when swaps.yml was edited by hand;
    /// - `skips`: lineup sessions not to book, as (class date, class key);
    /// - `picks`: single sessions queued to book, as book-only swaps, so the
    ///   GitHub swap-check books them if the Mac doesn't.
    static func swapsYAML(swaps: [Swap], skips: [(date: String, key: String)], picks: [ClassPick]) -> String {
        var entries: [(date: String, text: String)] = []
        for w in swaps where !w.isPast {
            var t = "  - date: \(w.date)"
            if let s = w.skip { t += "\n    skip: \(s)" }
            if let n = w.bookName {
                t += "\n    book:\n      name: \(quote(n))"
                if let s = w.bookStart { t += "\n      start: \"\(s)\"" }
                if let l = w.bookLocationIds, !l.isEmpty { t += "\n      location_ids: \(list(l))" }
            }
            if let note = w.note { t += "\n    note: \(quote(note))" }
            entries.append((w.date, t))
        }
        for s in skips {
            entries.append((s.date, "  - date: \(s.date)\n    skip: \(s.key)\n    note: \"Skipped in YMCA Booker\""))
        }
        for p in picks {
            let date = Pause.day(p.occursAt)
            entries.append((date, """
                  - date: \(date)
                    book:
                      name: \(quote(p.name))
                      start: "\(Slot.hhmm(p.occursAt))"
                      location_ids: [\(p.branchId)]
                    note: "Booked in YMCA Booker"
                """))
        }
        if entries.isEmpty { return header + "\nswaps: []\n" }
        return header + "\nswaps:\n" + entries.sorted { $0.date < $1.date }.map(\.text).joined(separator: "\n\n") + "\n"
    }

    /// The files to write: those that differ from what was last written (all
    /// of them when forced), in `paths` order.
    static func pendingWrites(_ files: [String: String], written: [String: String], force: Bool) -> [String] {
        paths.filter { p in files[p].map { force || written[p] != $0 } ?? false }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func list(_ xs: [Int]) -> String { "[" + xs.map(String.init).joined(separator: ", ") + "]" }
}
#endif
