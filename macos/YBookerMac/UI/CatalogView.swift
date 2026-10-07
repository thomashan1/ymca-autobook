import SwiftUI

/// The YMCA's live schedule for both branches, grouped into weekly slots, with
/// filters and one-click add/remove. Slots already in your lineup are ticked.
struct CatalogView: View {
    @ObservedObject var engine: Engine
    @State private var slots: [CatalogSlot] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var day = "All"
    @State private var branch = 0
    @State private var timeOfDay = "Any"
    @State private var onlyMine = false

    private let days = ["All", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filters
            Table(filtered) {
                TableColumn("") { s in
                    let mine = isMine(s)
                    Button {
                        if mine { engine.remove(s) }
                        else { engine.addClass(name: s.name, weekday: s.weekday, start: s.start, branchId: s.branchId) }
                    } label: {
                        Image(systemName: mine ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(mine ? .green : .accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help(mine ? "In your lineup — click to remove" : "Add to your lineup")
                }
                .width(28)
                TableColumn("Class") { s in Text(s.name).bold(isMine(s)) }
                    .width(min: 140, ideal: 170)
                TableColumn("Day") { s in Text(s.weekday) }.width(40)
                TableColumn("Time") { s in Text("\(s.start)–\(s.end)").monospacedDigit() }.width(90)
                TableColumn("Branch") { s in Text(s.branch) }.width(80)
                TableColumn("Room") { s in Text(s.rooms.joined(separator: ", ")).foregroundStyle(.secondary) }
                    .width(min: 100, ideal: 150)
                TableColumn("Instructor") { s in Text(s.trainers.joined(separator: ", ")).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 110)
                TableColumn("Spots") { s in Text("\(s.capacity)").monospacedDigit() }.width(45)
                TableColumn("Fills in") { s in
                    Text(fill(s.fastestFill)).monospacedDigit()
                        .foregroundStyle((s.fastestFill ?? .infinity) < 300 ? .red : .primary)
                        .help("Quickest fill seen in the last two weeks, after its booking window opened")
                }
                .width(70)
            }
            .overlay {
                if loading { ProgressView("Reading the YMCA schedule…") }
                else if let error { Text(error).foregroundStyle(.red) }
                else if filtered.isEmpty && !slots.isEmpty { Text("No classes match these filters.").foregroundStyle(.secondary) }
            }
            Text("Live from the YMCA, next two weeks. \(filtered.count) of \(slots.count) slots shown · red = fills within 5 minutes of opening.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if slots.isEmpty { await load() } }
    }

    private var filters: some View {
        HStack {
            TextField("Search classes, rooms, instructors", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Picker("", selection: $day) { ForEach(days, id: \.self) { Text($0) } }.frame(width: 80)
            Picker("", selection: $branch) {
                Text("Both branches").tag(0)
                Text("Southwest").tag(1392)
                Text("Northwest").tag(1388)
            }.frame(width: 130)
            Picker("", selection: $timeOfDay) {
                ForEach(["Any", "Morning", "Afternoon", "Evening"], id: \.self) { Text($0) }
            }.frame(width: 100)
            Toggle("Only mine", isOn: $onlyMine)
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload from the YMCA").disabled(loading)
        }
    }

    private var filtered: [CatalogSlot] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return slots.filter { s in
            (day == "All" || s.weekday == day)
                && (branch == 0 || s.branchId == branch)
                && (!onlyMine || isMine(s))
                && matchesTime(s)
                && (q.isEmpty || s.name.lowercased().contains(q)
                    || s.rooms.joined().lowercased().contains(q) || s.trainers.joined().lowercased().contains(q))
        }
        .sorted { (order.firstIndex(of: $0.weekday) ?? 9, $0.start, $0.name) < (order.firstIndex(of: $1.weekday) ?? 9, $1.start, $1.name) }
    }

    private func matchesTime(_ s: CatalogSlot) -> Bool {
        switch timeOfDay {
        case "Morning": return s.hour < 12
        case "Afternoon": return (12..<17).contains(s.hour)
        case "Evening": return s.hour >= 17
        default: return true
        }
    }

    private func isMine(_ s: CatalogSlot) -> Bool { engine.classes.contains { s.isSame(as: $0) } }

    private func fill(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        if s < 120 { return "\(Int(s))s" }
        if s < 7200 { return "\(Int(s / 60)) min" }
        return String(format: "%.0f h", s / 3600)
    }

    private func load() async {
        loading = true
        error = nil
        do { slots = try await engine.loadCatalog() }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}
