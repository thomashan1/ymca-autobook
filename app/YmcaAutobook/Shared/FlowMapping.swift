import Foundation

/// The `{key: value, key: [a, b]}` entries in pauses.yml, split into fields at
/// the commas that aren't inside a `[...]` list. Used by both platforms' parsers.
enum FlowMapping {
    static func fields(_ inner: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        var depth = 0, current = ""
        func flush() {
            let parts = current.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                out.append((parts[0].trimmingCharacters(in: .whitespaces),
                            parts[1].trimmingCharacters(in: .whitespaces)))
            }
            current = ""
        }
        for ch in inner {
            switch ch {
            case "[": depth += 1; current.append(ch)
            case "]": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0: flush()
            default: current.append(ch)
            }
        }
        flush()
        return out
    }

    /// `[a, b]` -> ["a", "b"]
    static func list(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
