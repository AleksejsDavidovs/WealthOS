import Foundation

nonisolated struct TradeInput: Sendable, Equatable {
    var kind: TradeKind
    var date: Date
    var quantity: Decimal
    var price: Decimal
    var fee: Decimal
    /// Tie-breaker for trades on the same date.
    var createdAt: Date = .distantPast
}

nonisolated struct PositionResult: Sendable, Equatable {
    var quantity: Decimal = 0
    /// Remaining cost of open units, including buy fees (average-cost method).
    var costBasis: Decimal = 0
    var realizedProfit: Decimal = 0
    var totalFees: Decimal = 0
    var totalInvested: Decimal = 0

    var averageCost: Decimal? { quantity > 0 ? costBasis / quantity : nil }
}

nonisolated enum InvestmentError: LocalizedError, Equatable {
    case oversell(available: Decimal)
    case invalidQuantity
    case invalidPrice
    case invalidFee

    var errorDescription: String? {
        switch self {
        case .oversell(let available):
            "You can't sell more than you hold at that date (\(MoneyFormat.quantity(available)) available)."
        case .invalidQuantity:
            "Quantity must be greater than zero."
        case .invalidPrice:
            "Price can't be negative."
        case .invalidFee:
            "Fee can't be negative."
        }
    }
}

/// Position accounting using the average-cost method.
/// - Buy: quantity += q; cost += q·price + fee.
/// - Sell: cost of sold units = cost · q / quantity; realized P/L = q·price − fee − cost of sold units.
nonisolated enum InvestmentCalculator {
    static func position(for trades: [TradeInput]) throws -> PositionResult {
        var result = PositionResult()
        let ordered = trades.sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
        for trade in ordered {
            guard trade.quantity > 0 else { throw InvestmentError.invalidQuantity }
            guard trade.price >= 0 else { throw InvestmentError.invalidPrice }
            guard trade.fee >= 0 else { throw InvestmentError.invalidFee }
            result.totalFees += trade.fee
            switch trade.kind {
            case .buy:
                let cost = trade.quantity * trade.price + trade.fee
                result.quantity += trade.quantity
                result.costBasis += cost
                result.totalInvested += cost
            case .sell:
                guard trade.quantity <= result.quantity else {
                    throw InvestmentError.oversell(available: result.quantity)
                }
                let costOfSold: Decimal
                if trade.quantity == result.quantity {
                    costOfSold = result.costBasis
                } else {
                    costOfSold = result.costBasis * trade.quantity / result.quantity
                }
                result.realizedProfit += trade.quantity * trade.price - trade.fee - costOfSold
                result.costBasis -= costOfSold
                result.quantity -= trade.quantity
            }
        }
        return result
    }

    /// Cash moved by a trade, in the holding's currency: buys cost q·p + fee, sells return q·p − fee.
    static func cashImpact(kind: TradeKind, quantity: Decimal, price: Decimal, fee: Decimal) -> Decimal {
        switch kind {
        case .buy: quantity * price + fee
        case .sell: quantity * price - fee
        }
    }
}
