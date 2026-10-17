#if os(iOS)
import SwiftUI

/// One row of small capsule filters, the same on every list that has them
/// (Book, Fill speed), so filters take one line instead of a card.
struct ChipRow<Content: View>: View {
    /// A chip id to keep in view (e.g. the selected day), if any.
    var scrollTo: AnyHashable? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content }.padding(.horizontal, 20).padding(.vertical, 2)
            }
            .onChange(of: scrollTo) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

struct Chip: View {
    let title: String
    var systemImage: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChipLabel(title: title, systemImage: systemImage, selected: selected) }
            .buttonStyle(.plain)
    }
}

/// A chip that opens a menu of choices, e.g. the branch.
struct MenuChip<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    /// Highlighted when it narrows the list (not on its "everything" choice).
    let active: Bool

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
        } label: {
            ChipLabel(title: options.first { $0.0 == selection }?.1 ?? "", systemImage: "chevron.down",
                      trailingImage: true, selected: active)
        }
        .buttonStyle(.plain)
    }
}

/// A chip that opens a menu of branches to tick, any number of them. Stays
/// open while ticking so choosing three branches is three taps, not three trips.
struct BranchesMenuChip: View {
    /// Stored as "1392,1388"; empty means every branch.
    @Binding var stored: String

    var body: some View {
        let chosen = Branch.parse(stored)
        Menu {
            Button {
                stored = ""
            } label: {
                if chosen.isEmpty { Label("All branches", systemImage: "checkmark") } else { Text("All branches") }
            }
            Divider()
            ForEach(Branch.all) { b in
                Toggle(b.name, isOn: Binding(
                    get: { chosen.contains(b.id) },
                    set: { _ in stored = Branch.store(Branch.toggled(b.id, in: chosen)) }))
            }
        } label: {
            ChipLabel(title: Branch.label(chosen), systemImage: "chevron.down", trailingImage: true,
                      selected: !chosen.isEmpty)
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.plain)
    }
}

private struct ChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var trailingImage = false
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage, !trailingImage { Image(systemName: systemImage).font(.caption.weight(.semibold)) }
            Text(title)
            if let systemImage, trailingImage { Image(systemName: systemImage).font(.caption2.weight(.bold)) }
        }
        .font(.subheadline.weight(selected ? .semibold : .regular))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? Theme.accent : Color(.secondarySystemFill), in: Capsule())
        .foregroundStyle(selected ? .white : .primary)
        .fixedSize()
    }
}
#endif
