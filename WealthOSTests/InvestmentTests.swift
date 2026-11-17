import Foundation
import Testing
@testable import WealthOS

@Suite("Investment calculations")
struct InvestmentTests {
    let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func trade(_ kind: TradeKind, _ q: Decimal, _ p: Decimal, fee: Decimal = 0, offset: Double) -> TradeInput {
        TradeInput(kind: kind, date: day.addingTimeInterval(offset * 86_400), quantity: q, price: p, fee: fee)
    }

    @Test func averageCostIncludesBuyFees() throws {
        let result = try InvestmentCalculator.position(for: [
            trade(.buy, 10, 100, fee: 5, offset: 0),
            trade(.buy, 10, 120, fee: 5, offset: 1),
        ])
        #expect(result.quantity == 20)
        #expect(result.costBasis == 2_210)
        #expect(result.averageCost == Decimal(string: "110.5"))
        #expect(result.totalFees == 10)
    }

    @Test func realizedProfitUsesAverageCost() throws {
        let result = try InvestmentCalculator.position(for: [
            trade(.buy, 10, 100, offset: 0),
            trade(.buy, 10, 200, offset: 1),
            trade(.sell, 5, 180, fee: 2, offset: 2),
        ])
        // Average cost 150; sold 5 × 180 − 2 − 5 × 150 = 148.
        #expect(result.realizedProfit == 148)
        #expect(result.quantity == 15)
        #expect(result.costBasis == 2_250)
    }

    @Test func sellingEverythingClearsCostBasisExactly() throws {
        let result = try InvestmentCalculator.position(for: [
            trade(.buy, 3, Decimal(string: "33.33")!, offset: 0),
            trade(.sell, 3, 40, offset: 1),
        ])
        #expect(result.quantity == 0)
        #expect(result.costBasis == 0)
        #expect(result.realizedProfit == Decimal(string: "20.01"))
    }

    @Test func oversellingThrows() {
        #expect(throws: InvestmentError.self) {
            try InvestmentCalculator.position(for: [
                trade(.buy, 1, 100, offset: 0),
                trade(.sell, 2, 100, offset: 1),
            ])
        }
    }

    @Test func sellBeforeBuyIsRejectedByDate() {
        #expect(throws: InvestmentError.self) {
            try InvestmentCalculator.position(for: [
                trade(.buy, 5, 100, offset: 2),
                trade(.sell, 5, 100, offset: 1),
            ])
        }
    }

    @Test func cashImpact() {
        #expect(InvestmentCalculator.cashImpact(kind: .buy, quantity: 2, price: 50, fee: 1) == 101)
        #expect(InvestmentCalculator.cashImpact(kind: .sell, quantity: 2, price: 50, fee: 1) == 99)
    }

    @Test func negativePriceIsRejectedAtCalculationBoundary() {
        #expect(throws: InvestmentError.invalidPrice) {
            try InvestmentCalculator.position(for: [trade(.buy, 1, -100, offset: 0)])
        }
    }

    @Test func negativeFeeIsRejectedAtCalculationBoundary() {
        #expect(throws: InvestmentError.invalidFee) {
            try InvestmentCalculator.position(for: [trade(.buy, 1, 100, fee: -1, offset: 0)])
        }
    }
}

@Suite("Goal math")
struct GoalMathTests {
    @Test func progressAndCompletion() {
        #expect(GoalMath.progress(allocated: 2_500, target: 10_000) == 0.25)
        #expect(GoalMath.progress(allocated: 12_000, target: 10_000) == 1)
        #expect(GoalMath.monthsToComplete(allocated: 2_500, target: 10_000, monthly: 1_000) == 8)
        #expect(GoalMath.monthsToComplete(allocated: 2_500, target: 10_000, monthly: 0) == nil)
        #expect(GoalMath.monthsToComplete(allocated: 10_000, target: 10_000, monthly: 0) == 0)
    }

    @Test func requiredMonthly() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let target = calendar.date(byAdding: .month, value: 10, to: start)!
        #expect(GoalMath.requiredMonthly(allocated: 0, target: 1_000, targetDate: target, from: start, calendar: calendar) == 100)
    }
}
