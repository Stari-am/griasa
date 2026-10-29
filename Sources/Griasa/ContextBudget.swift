import Foundation

/// Fits a context pack into what an assistant asked for. Sections come in the
/// order they matter — open promises before old meetings — and each section's
/// items newest first, so trimming takes the oldest items of the least important
/// section first and never a whole section while a less important one still has
/// something to give. Foundation only, so the rule is checked.
enum ContextBudget {
    struct Section {
        var key: String
        /// Each item already rendered as the text the assistant will read.
        var items: [String]
    }

    /// The sections with items dropped until their total length is within
    /// `budget` characters, plus how many items were left out.
    static func fit(_ sections: [Section], budget: Int) -> (sections: [Section], omitted: Int) {
        var kept = sections
        var omitted = 0
        func size() -> Int { kept.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.count } } }
        var total = size()
        var index = kept.count - 1
        while total > budget, index >= 0 {
            if let last = kept[index].items.popLast() {
                total -= last.count
                omitted += 1
            } else {
                index -= 1
            }
        }
        return (kept, omitted)
    }
}
