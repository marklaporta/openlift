import Foundation

enum CycleOrdering {
    static func sortedDays(_ days: [CycleDay]) -> [CycleDay] {
        days
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.position != rhs.element.position {
                    return lhs.element.position < rhs.element.position
                }

                // Legacy templates may have default position for every day.
                // In that case, use semantic label ordering when possible.
                if lhs.element.position == 0, rhs.element.position == 0 {
                    let lhsRank = inferredDayRank(lhs.element.label)
                    let rhsRank = inferredDayRank(rhs.element.label)
                    if let lhsRank, let rhsRank, lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func sortedSlots(_ slots: [CycleSlot]) -> [CycleSlot] {
        // Preserve original order for equal positions to keep legacy imported cycles stable.
        slots
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.position != rhs.element.position {
                    return lhs.element.position < rhs.element.position
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func inferredDayRank(_ label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("upper ") || trimmed.hasPrefix("lower ") {
            let isUpper = trimmed.hasPrefix("upper ")
            let suffix = String(trimmed.dropFirst(isUpper ? 6 : 6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = suffixOrdinal(suffix) else { return nil }
            return index * 2 + (isUpper ? 0 : 1)
        }

        if trimmed.hasPrefix("day ") {
            let suffix = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return suffixOrdinal(suffix)
        }

        return suffixOrdinal(trimmed)
    }

    private static func suffixOrdinal(_ token: String) -> Int? {
        let upper = token.uppercased()
        if let value = Int(upper) {
            return value
        }

        if upper.count == 1, let scalar = upper.unicodeScalars.first {
            let value = Int(scalar.value)
            if value >= 65 && value <= 90 {
                return value - 65
            }
        }

        return nil
    }
}
