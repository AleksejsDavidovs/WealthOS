import CoreGraphics
import Foundation
import Testing
@testable import WealthOS

@Suite("Portfolio map")
struct PortfolioMapTests {
    let bounds = CGRect(x: 0, y: 0, width: 360, height: 340)

    @Test func tileAreasAreProportionalAndFillTheRect() {
        let values: [Double] = [1400, 1310, 490, 368, 330, 198, 5]
        let rects = Treemap.layout(values, in: bounds)
        let total = values.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        for (value, rect) in zip(values, rects) {
            #expect(abs(Double(rect.width * rect.height) - value / total * area) < 0.5)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        #expect(abs(rects.reduce(0) { $0 + Double($1.width * $1.height) } - area) < 1)
    }

    @Test func tilesNeverOverlap() {
        let rects = Treemap.layout([50, 30, 20, 10, 8, 5, 3, 2, 1], in: bounds)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func tilesStayReasonablySquare() {
        let rects = Treemap.layout([30, 25, 20, 15, 10], in: bounds)
        for rect in rects {
            #expect(max(rect.width / rect.height, rect.height / rect.width) < 4)
        }
    }

    @Test func emptyAndZeroValues() {
        #expect(Treemap.layout([], in: bounds).isEmpty)
        let rects = Treemap.layout([10, 0, -3, 5], in: bounds)
        #expect(rects[1] == .zero && rects[2] == .zero)
        #expect(rects[0].width > 0 && rects[3].width > 0)
        #expect(Treemap.layout([1, 2], in: .zero) == [.zero, .zero])
    }

    @Test func logoURLsOnlyCarryAPlainTicker() {
        #expect(LogoCache.url(for: "AAPL_US_EQ")?.absoluteString == "https://trading212equities.s3.eu-central-1.amazonaws.com/AAPL_US_EQ.png")
        #expect(LogoCache.url(for: "VUSAl_EQ") != nil)
        #expect(LogoCache.url(for: "../secret") == nil)
        #expect(LogoCache.url(for: "A/B") == nil)
        #expect(LogoCache.url(for: "AAPL?x=1") == nil)
        #expect(LogoCache.url(for: "") == nil)
        #expect(LogoCache.url(for: String(repeating: "A", count: 40)) == nil)
    }

    @MainActor
    @Test func smallPositionsAreGroupedIntoOther() {
        let items = (1...25).map { index in
            PortfolioMapItem(id: "\(index)", symbol: "S\(index)", name: "S\(index)", logoTicker: nil, value: Decimal(100 - index),
                             gain: 1, fraction: nil, quantity: 1, source: "Manual")
        }
        let grouped = PortfolioMapCard.grouped(items)
        #expect(grouped.count == PortfolioMapCard.maximumTiles)
        #expect(grouped.last?.id == "other")
        let restValue = items.dropFirst(PortfolioMapCard.maximumTiles - 1).reduce(Decimal(0)) { $0 + $1.value }
        #expect(grouped.last?.value == restValue)
        #expect(grouped.last?.gain == Decimal(items.count - PortfolioMapCard.maximumTiles + 1))
        #expect(PortfolioMapCard.grouped(Array(items.prefix(5))).count == 5)
    }

    @Test func monogramFallback() {
        #expect(TickerLogo.monogram("btc") == "BTC")
        #expect(TickerLogo.monogram("BRK.B") == "BRKB")
        #expect(TickerLogo.monogram("") == "?")
    }
}
