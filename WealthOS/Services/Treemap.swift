import CoreGraphics

/// Squarified treemap (Bruls, Huizing & van Wijk): splits a rectangle into tiles whose areas are
/// proportional to the values, keeping tiles as close to square as possible.
nonisolated enum Treemap {
    /// Returns one rectangle per value, in the same order. Values ≤ 0 get an empty rect.
    /// Pass values sorted largest first for the best layout.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let items = values.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }

        var remaining = rect
        var row: [(index: Int, area: Double)] = []
        var position = 0
        while position < items.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [items[position]]
            if row.isEmpty || worst(candidate.map(\.area), side: side) <= worst(row.map(\.area), side: side) {
                row = candidate
                position += 1
            } else {
                place(row, in: &remaining, into: &result)
                row = []
            }
        }
        if !row.isEmpty { place(row, in: &remaining, into: &result) }
        return result
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst(_ areas: [Double], side: Double) -> Double {
        guard let largest = areas.max(), let smallest = areas.min(), smallest > 0, side > 0 else { return .infinity }
        let sum = areas.reduce(0, +)
        let sideSquared = side * side
        return max(sideSquared * largest / (sum * sum), (sum * sum) / (sideSquared * smallest))
    }

    /// Lays a row along the shorter side of `remaining` and shrinks it.
    private static func place(_ row: [(index: Int, area: Double)], in remaining: inout CGRect, into result: inout [CGRect]) {
        let sum = row.reduce(0) { $0 + $1.area }
        if remaining.width >= remaining.height {
            // Column on the left.
            let width = CGFloat(sum) / remaining.height
            var y = remaining.minY
            for item in row {
                let height = CGFloat(item.area) / width
                result[item.index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                y += height
            }
            remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                               width: max(0, remaining.width - width), height: remaining.height)
        } else {
            // Row along the top.
            let height = CGFloat(sum) / remaining.width
            var x = remaining.minX
            for item in row {
                let width = CGFloat(item.area) / height
                result[item.index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                x += width
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                               width: remaining.width, height: max(0, remaining.height - height))
        }
    }
}
