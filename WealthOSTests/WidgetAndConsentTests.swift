import Foundation
import Testing
@testable import WealthOS

private let riga: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Riga")!
    return calendar
}()

private func at(_ text: String, hour: Int = 12, minute: Int = 0) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    return riga.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute))!
}

private func connection(until: Date?, status: BankConnectionStatus = .active) -> BankConnection {
    let connection = BankConnection(aspspName: "Swedbank", aspspCountry: "LV", backendConnectionID: "c", validUntil: until)
    connection.status = status
    return connection
}

@Suite("Bank consent reminders")
@MainActor
struct BankConsentReminderTests {
    @Test func remindsSevenDaysAndOneDayBeforeAtTen() {
        let reminders = PlanningMonitor.consentReminders([connection(until: at("2027-02-15", hour: 14))],
                                                         now: at("2026-11-18"), calendar: riga)
        #expect(reminders.map(\.at) == [at("2027-02-08", hour: 10), at("2027-02-14", hour: 10)])
        #expect(reminders.allSatisfy { $0.id.hasPrefix("consent.") })
        #expect(reminders[1].body.contains("tomorrow"))
        // Texts never contain amounts or account numbers.
        #expect(reminders.allSatisfy { !$0.body.contains("€") })
    }

    @Test func skipsPastTimesAndInactiveConnections() {
        let until = at("2027-02-15", hour: 14)
        let soon = PlanningMonitor.consentReminders([connection(until: until)], now: at("2027-02-10"), calendar: riga)
        #expect(soon.map(\.at) == [at("2027-02-14", hour: 10)])
        #expect(PlanningMonitor.consentReminders([connection(until: until)], now: at("2027-02-15"), calendar: riga).isEmpty)
        #expect(PlanningMonitor.consentReminders([connection(until: until, status: .revoked)], now: at("2026-11-18"), calendar: riga).isEmpty)
        #expect(PlanningMonitor.consentReminders([connection(until: nil)], now: at("2026-11-18"), calendar: riga).isEmpty)
    }

    @Test func reminderBeforeAnEarlyMorningExpiryStillComesFirst() {
        // Access ends at 08:00 — the "1 day before" reminder at 10:00 the previous day is still before it.
        let reminders = PlanningMonitor.consentReminders([connection(until: at("2027-02-15", hour: 8))],
                                                         now: at("2027-02-13"), calendar: riga)
        #expect(reminders.map(\.at) == [at("2027-02-14", hour: 10)])
    }

    @Test func remindersAreOnUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "consent-\(UUID().uuidString)")!
        #expect(PlanningMonitor.consentRemindersEnabled(defaults))
        defaults.set(false, forKey: SettingsKey.bankConsentReminders)
        #expect(!PlanningMonitor.consentRemindersEnabled(defaults))
    }

    @Test func bannerShowsTheMostUrgentConnectionWithinAWeek() {
        let now = at("2027-02-10")
        #expect(BankConsentBanner.notice(for: [connection(until: at("2027-03-01"))], now: now, calendar: riga) == nil)
        let notice = BankConsentBanner.notice(for: [connection(until: at("2027-02-16")), connection(until: at("2027-02-12", hour: 9))],
                                              now: now, calendar: riga)
        #expect(notice?.daysLeft == 2)
        #expect(BankConsentBanner.notice(for: [connection(until: at("2027-02-11"))], now: now, calendar: riga)?.title.contains("tomorrow") == true)
        #expect(BankConsentBanner.notice(for: [connection(until: at("2027-02-09"))], now: now, calendar: riga)?.daysLeft == -1)
        #expect(BankConsentBanner.notice(for: [connection(until: nil, status: .expired)], now: now, calendar: riga)?.daysLeft == -1)
        #expect(BankConsentBanner.notice(for: [connection(until: at("2027-02-11"), status: .revoked)], now: now, calendar: riga) == nil)
    }
}

@Suite("Widget snapshot")
@MainActor
struct WidgetSnapshotTests {
    func snapshot(updated: Date) -> WidgetSnapshot {
        WidgetSnapshot(currencyCode: "EUR", netWorth: 1_000, isComplete: true, spentToday: 12, spentThisMonth: 300,
                       budgetLimit: 500, budgetSpent: 300, bankAccessUntil: at("2027-02-15", hour: 14),
                       hidesAmounts: false, updatedAt: updated)
    }

    @Test func dayAndMonthFiguresResetWhenStale() {
        let s = snapshot(updated: at("2026-11-18", hour: 9))
        #expect(s.spentToday(asOf: at("2026-11-18", hour: 23), calendar: riga) == 12)
        #expect(s.spentToday(asOf: at("2026-11-19", hour: 0, minute: 1), calendar: riga) == 0)
        #expect(s.spentThisMonth(asOf: at("2026-11-30"), calendar: riga) == 300)
        #expect(s.spentThisMonth(asOf: at("2026-12-01", hour: 0, minute: 1), calendar: riga) == 0)
        #expect(s.budget(asOf: at("2026-12-01"), calendar: riga)! == (500, 0))
        #expect(s.budget(asOf: at("2026-11-20"), calendar: riga)! == (500, 300))
    }

    @Test func bankDaysLeft() {
        let s = snapshot(updated: .now)
        #expect(s.bankAccessDaysLeft(asOf: at("2027-02-08"), calendar: riga) == 7)
        #expect(s.bankAccessDaysLeft(asOf: at("2027-02-15", hour: 9), calendar: riga) == 0)
        #expect(s.bankAccessDaysLeft(asOf: at("2027-02-15", hour: 15), calendar: riga) == -1)
    }

    @Test func roundTripsThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { WidgetSnapshot.remove(at: url) }
        let s = snapshot(updated: at("2026-11-18"))
        #expect(s.save(to: url))
        #expect(WidgetSnapshot.load(from: url) == s)
        var later = s
        later.updatedAt = at("2026-11-19")
        #expect(later.hasSameValues(as: s))
        later.netWorth = 1_001
        #expect(!later.hasSameValues(as: s))
    }

    @Test func bankAccessUsesEarliestActiveConsent() {
        let early = connection(until: at("2027-01-10")), late = connection(until: at("2027-02-10"))
        let revoked = connection(until: at("2026-12-01"), status: .revoked)
        #expect(WidgetPublisher.bankAccessUntil([late, early, revoked]) == at("2027-01-10"))
        #expect(WidgetPublisher.bankAccessUntil([revoked]) == nil)
    }

    @Test func tapRevealShowsAmountsOnlyUntilItEnds() {
        var s = snapshot(updated: .now)
        let now = at("2026-11-18")
        #expect(s.showsAmounts(at: now, revealUntil: nil))
        s.hidesAmounts = true
        #expect(!s.showsAmounts(at: now, revealUntil: nil))
        #expect(s.showsAmounts(at: now, revealUntil: now.addingTimeInterval(30)))
        #expect(!s.showsAmounts(at: now.addingTimeInterval(30), revealUntil: now.addingTimeInterval(30)))
        let defaults = UserDefaults(suiteName: "reveal-\(UUID().uuidString)")!
        #expect(WidgetPublisher.hidesAmounts(defaults))
        defaults.set(false, forKey: SettingsKey.widgetHidesAmounts)
        #expect(!WidgetPublisher.hidesAmounts(defaults))
    }

    @Test func topCategoriesAreThisMonthsLargestExpenses() {
        let food = TransactionCategory(name: "Food", kind: .expense, symbol: "tag", colorName: "blue")
        let car = TransactionCategory(name: "Car", kind: .expense, symbol: "tag", colorName: "blue")
        let fun = TransactionCategory(name: "Fun", kind: .expense, symbol: "tag", colorName: "blue")
        func e(_ d: String, _ amount: Decimal, _ c: UUID?, _ kind: TransactionKind = .expense) -> CashFlowEntry {
            CashFlowEntry(id: UUID(), date: at(d), kind: kind, categoryID: c, amount: amount)
        }
        let entries = [e("2026-11-02", 40, food.id), e("2026-11-10", 35, food.id), e("2026-11-05", 60, car.id),
                       e("2026-11-06", 10, fun.id), e("2026-11-07", 20, nil), e("2026-10-30", 500, fun.id),
                       e("2026-11-03", 3_000, food.id, .income)]
        let month = riga.dateInterval(of: .month, for: at("2026-11-18"))!
        let top = WidgetPublisher.topCategories(entries, in: month, categories: [food, car, fun])
        #expect(top == [.init(name: "Food", amount: 75), .init(name: "Car", amount: 60), .init(name: "Uncategorized", amount: 20)])
    }

    @Test func monthChangeComparesWithTheEndOfLastMonth() {
        let history = [NetWorthSnapshot(date: at("2026-10-15"), netWorth: 900, source: .automatic, currencyCode: "EUR"),
                       NetWorthSnapshot(date: at("2026-10-31", hour: 20), netWorth: 950, source: .automatic, currencyCode: "EUR"),
                       NetWorthSnapshot(date: at("2026-10-31", hour: 21), netWorth: 9_999, source: .automatic, currencyCode: "USD"),
                       NetWorthSnapshot(date: at("2026-11-02"), netWorth: 990, source: .automatic, currencyCode: "EUR")]
        let start = riga.dateInterval(of: .month, for: at("2026-11-18"))!.start
        #expect(WidgetPublisher.monthStart(history, before: start, currency: "EUR") == 950)
        #expect(WidgetPublisher.monthStart([], before: start, currency: "EUR") == nil)
        var s = snapshot(updated: at("2026-11-18"))
        s.netWorthMonthStart = 950
        #expect(s.monthChange(asOf: at("2026-11-20"), calendar: riga) == 50)
        #expect(s.monthChange(asOf: at("2026-12-01"), calendar: riga) == nil)
    }
}
