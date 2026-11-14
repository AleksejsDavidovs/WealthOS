import Foundation

/// SplitMix64 — small, fast, well-distributed, and fully reproducible from a seed.
nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in the open interval (0, 1).
    mutating func nextUnitInterval() -> Double {
        (Double(next() >> 11) + 0.5) * 0x1.0p-53
    }

    /// Standard normal sample via the Box–Muller transform.
    mutating func nextGaussian() -> Double {
        let u1 = nextUnitInterval()
        let u2 = nextUnitInterval()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

nonisolated struct PercentileBand: Identifiable, Sendable, Equatable {
    let year: Int
    let date: Date
    let p10: Double
    let p50: Double
    let p90: Double
    var id: Int { year }
}

nonisolated struct MonteCarloResult: Sendable, Equatable {
    let bands: [PercentileBand]
    let runs: Int
    let seed: UInt64
    let target: Decimal
    /// Share of paths whose final nominal net worth is at or above `target`.
    let probabilityOfTarget: Double
    /// Share of paths that ran out of money (negative net worth) at any point.
    let probabilityOfShortfall: Double

    var final: PercentileBand? { bands.last }
}

/// Monte Carlo projection of investment returns.
///
/// Cash flows are identical to `SimulationEngine` (same schedule and ordering).
/// Only the monthly investment return is random: each month's growth factor is
/// lognormal, exp(μ_m + σ_m·Z), with σ_m = σ/√12 and μ_m = ln(1 + r)/12 − σ_m²/2,
/// so the median annual growth is close to (1 + r) · exp(−σ²/2) and with σ = 0 the
/// result equals the deterministic projection. Statistics use Double precision;
/// they are estimates, not accounting figures.
nonisolated enum MonteCarloEngine {
    static let defaultRuns = 1_000
    static let defaultSeed: UInt64 = 20_261_106

    static func run(_ p: SimulationParameters, runs: Int = defaultRuns, seed: UInt64 = defaultSeed,
                    target: Decimal, startDate: Date = .now, calendar: Calendar = .current) -> MonteCarloResult? {
        let months = max(1, p.years) * 12
        let runs = max(1, runs)
        let flows = SimulationEngine.schedule(for: p, startDate: startDate, calendar: calendar)
        let income = flows.income.map(\.doubleValue)
        let outflow = zip(flows.expenses, flows.recurring).map { ($0 + $1).doubleValue }
        let planned = flows.plannedContribution.map(\.doubleValue)
        let purchases = flows.purchases.map(\.doubleValue)

        let sigmaMonthly = p.volatility.doubleValue / 12.0.squareRoot()
        let muMonthly = log(1 + p.annualReturn.doubleValue) / 12.0 - sigmaMonthly * sigmaMonthly / 2
        let cashRate = pow(1 + p.cashInterest.doubleValue, 1.0 / 12.0) - 1
        let targetValue = target.doubleValue

        var generator = SeededGenerator(seed: seed)
        // yearEnd[year][path]
        var yearEnd = [[Double]](repeating: [Double](repeating: 0, count: runs), count: p.years + 1)
        var hits = 0
        var shortfalls = 0

        for path in 0..<runs {
            if path % 100 == 0 && Task.isCancelled { return nil }
            var cash = p.startingCash.doubleValue
            var investments = p.startingInvestments.doubleValue
            var hadShortfall = false
            yearEnd[0][path] = cash + investments

            for month in 1...months {
                if investments > 0 {
                    investments *= exp(muMonthly + sigmaMonthly * generator.nextGaussian())
                }
                if cash > 0 { cash *= 1 + cashRate }
                let surplus = income[month] - outflow[month]
                let contribution = max(0, min(planned[month], surplus))
                cash += surplus - contribution
                investments += contribution
                cash -= purchases[month]
                if cash < 0 && investments > 0 {
                    let draw = min(-cash, investments)
                    investments -= draw
                    cash += draw
                }
                if cash + investments < 0 { hadShortfall = true }
                if month % 12 == 0 { yearEnd[month / 12][path] = cash + investments }
            }
            if yearEnd[p.years][path] >= targetValue { hits += 1 }
            if hadShortfall { shortfalls += 1 }
        }

        let monthStart = calendar.dateInterval(of: .month, for: startDate)?.start ?? startDate
        let bands = yearEnd.enumerated().map { year, values -> PercentileBand in
            let sorted = values.sorted()
            let date = year == 0 ? startDate : (calendar.date(byAdding: .month, value: year * 12, to: monthStart) ?? startDate)
            return PercentileBand(year: year, date: date,
                                  p10: percentile(sorted, 0.10),
                                  p50: percentile(sorted, 0.50),
                                  p90: percentile(sorted, 0.90))
        }
        return MonteCarloResult(bands: bands, runs: runs, seed: seed, target: target,
                                probabilityOfTarget: Double(hits) / Double(runs),
                                probabilityOfShortfall: Double(shortfalls) / Double(runs))
    }

    /// Runs off the caller's actor so the UI stays responsive. Cancellation propagates.
    @concurrent
    static func runInBackground(_ p: SimulationParameters, runs: Int, seed: UInt64, target: Decimal,
                                startDate: Date) async -> MonteCarloResult? {
        run(p, runs: runs, seed: seed, target: target, startDate: startDate)
    }

    /// Linear-interpolated percentile of a sorted array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
