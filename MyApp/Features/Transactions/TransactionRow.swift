import SwiftUI

struct TransactionRow: View {
    let transaction: TransactionRecord
    let engine: FinanceEngine
    let categories: [TransactionCategory]
    /// Lists grouped by day already show the date in the section header.
    var showsDate = true

    private var category: TransactionCategory? {
        transaction.categoryID.flatMap { id in categories.first { $0.id == id } }
    }
    private var account: Account? { engine.accountsByID[transaction.accountID] }
    private var destination: Account? { transaction.destinationAccountID.flatMap { engine.accountsByID[$0] } }
    private var isScheduled: Bool { transaction.date > Calendar.current.startOfDay(for: .now).addingTimeInterval(86_399) }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if transaction.recurringRuleID != nil {
                        Image(systemName: "repeat").accessibilityLabel("Recurring")
                    }
                    if isScheduled {
                        Text("Scheduled").foregroundStyle(Theme.warning)
                    }
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .opacity(isScheduled ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch transaction.kind {
        case .income, .expense:
            IconBadge(symbol: category?.symbol ?? "tag.fill", color: Theme.color(named: category?.colorName ?? "gray"))
        case .transfer:
            IconBadge(symbol: "arrow.left.arrow.right", color: .indigo)
        case .adjustment:
            IconBadge(symbol: "slider.horizontal.3", color: .gray)
        }
    }

    private var title: String {
        if !transaction.note.isEmpty { return transaction.note }
        switch transaction.kind {
        case .income, .expense: return category?.name ?? transaction.kind.title
        case .transfer: return "Transfer"
        case .adjustment: return "Balance adjustment"
        }
    }

    private var subtitle: String {
        let date = showsDate ? transaction.date.formatted(.dateTime.day().month(.abbreviated)) : nil
        switch transaction.kind {
        case .transfer:
            return ["\(account?.name ?? "?") → \(destination?.name ?? "?")", date].compactMap { $0 }.joined(separator: " · ")
        default:
            let categoryName = transaction.note.isEmpty ? nil : category?.name
            return [categoryName, account?.name, date].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var code: String { account?.currencyCode ?? "EUR" }

    private var amountText: String {
        switch transaction.kind {
        case .income: MoneyFormat.string(transaction.amount, code: code, showSign: true)
        case .expense: MoneyFormat.string(-transaction.amount, code: code, showSign: true)
        case .transfer: MoneyFormat.string(transaction.amount, code: code)
        case .adjustment: MoneyFormat.string(transaction.amount, code: code, showSign: true)
        }
    }

    private var amountColor: Color {
        switch transaction.kind {
        case .income: Theme.positive
        case .expense: .primary
        case .transfer: .secondary
        case .adjustment: .secondary
        }
    }
}

struct AccountRow: View {
    let account: Account
    let balance: Decimal

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: account.kind.symbol, color: Theme.color(named: account.colorName))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body.weight(.medium)).lineLimit(1)
                Text([account.kind.title, account.institution.isEmpty ? nil : account.institution].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.string(account.kind.isLiability ? -balance : balance, code: account.currencyCode))
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(account.kind.isLiability ? Theme.negative : (balance < 0 ? Theme.negative : .primary))
                if account.kind.isLiability {
                    Text("owed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
