import Foundation
import SwiftData

// Read-only bank account information (PSD2 AIS) via Enable Banking, through the WealthOS
// banking backend. Nothing here can initiate a payment: the backend exposes no such endpoint
// and the app has no code path that could construct one.
//
// Accounting model (see FinanceEngine):
// - A bank account the user links is always represented by exactly one existing WealthOS
//   `Account`. Its balance is the last *confirmed* booked bank balance instead of the ledger
//   balance, so the same money is never counted twice and a failed sync never zeroes it.
// - Booked bank transactions enter the normal ledger as `TransactionRecord`s tagged with an
//   `eb:` import fingerprint (so they show up in Transactions, statistics and backups). Pending
//   transactions never enter the ledger. Uncertain items wait in a review queue.

/// One Enable Banking consent for one bank. Device-local; never part of a backup.
@Model
final class BankConnection {
    var id: UUID = UUID()
    var aspspName: String = ""
    var aspspCountry: String = ""
    /// Opaque handle issued by the WealthOS banking backend. Useless without the client
    /// secret in the Keychain; the Enable Banking session itself never leaves the backend.
    var backendConnectionID: String = ""
    var validUntil: Date?
    var statusRaw: String = BankConnectionStatus.active.rawValue
    var createdAt: Date = Date()
    var lastCheckedAt: Date?

    init(aspspName: String, aspspCountry: String, backendConnectionID: String, validUntil: Date?, createdAt: Date = .now) {
        self.aspspName = aspspName
        self.aspspCountry = aspspCountry
        self.backendConnectionID = backendConnectionID
        self.validUntil = validUntil
        self.createdAt = createdAt
    }

    var status: BankConnectionStatus {
        get { BankConnectionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    func isUsable(now: Date = .now) -> Bool {
        status == .active && (validUntil.map { $0 > now } ?? true)
    }

    var title: String { BankingConstants.displayName(aspsp: aspspName, country: aspspCountry) }
}

nonisolated enum BankConnectionStatus: String, Sendable {
    case active
    /// The consent's `valid_until` passed or the bank reports it expired.
    case expired
    /// Revoked, closed or rejected by the bank or the user.
    case revoked
}

/// One bank account seen in a consent. Linking it to a WealthOS account is always the user's
/// explicit decision; an unlinked row is shown but never counted.
@Model
final class BankAccountLink {
    var id: UUID = UUID()
    /// Stable identity across consents: the backend's SHA-256 of the normalized IBAN (or of the
    /// bank's account identification). Raw IBANs are never sent to or stored on the iPhone.
    var accountKey: String = ""
    var aspspName: String = ""
    var aspspCountry: String = ""
    /// `BankConnection.id` of the consent currently providing data; nil = not connected.
    var connectionID: UUID?
    /// Enable Banking account uid. Scoped to one consent, so it changes on reconnect.
    var providerAccountUID: String = ""
    /// The WealthOS account this bank account is counted as. nil = not linked, not counted.
    var localAccountID: UUID?
    var displayName: String = ""
    var maskedIdentifier: String = ""
    var currencyCode: String = ""
    /// ISO 20022 cash account type reported by the bank (CACC, SVGS, CARD, LOAN…).
    var cashAccountType: String = ""
    var product: String = ""
    var creditLimit: Decimal?

    /// Last confirmed balance, in `currencyCode`. Only replaced by a later confirmed balance.
    var balanceAmount: Decimal?
    var balanceTypeRaw: String = ""
    var balanceReferenceDate: Date?
    /// When WealthOS last read and saved this account's balance and transactions successfully.
    var lastSuccessfulSyncAt: Date?
    /// Booked transactions dated before this day are never imported (the manual balance and
    /// history already cover them).
    var importStartDate: Date?
    /// Start of the last fully read transaction window; the next sync overlaps it.
    var transactionsSyncedFrom: Date?
    var lastErrorRaw: String = ""
    var lastAttemptAt: Date?
    /// Came from a backup and hasn't been re-synced since; the balance is last known, not verified.
    var restoredFromBackup: Bool = false
    var createdAt: Date = Date()

    init(accountKey: String, aspspName: String, aspspCountry: String, createdAt: Date = .now) {
        self.accountKey = accountKey
        self.aspspName = aspspName
        self.aspspCountry = aspspCountry
        self.createdAt = createdAt
    }

    var balanceType: BankBalanceType? { BankBalanceType(rawValue: balanceTypeRaw) }
    var isLinked: Bool { localAccountID != nil }
    var isConnected: Bool { connectionID != nil && !providerAccountUID.isEmpty }
    var bankTitle: String { BankingConstants.displayName(aspsp: aspspName, country: aspspCountry) }
    var title: String { displayName.isEmpty ? (maskedIdentifier.isEmpty ? "Bank account" : maskedIdentifier) : displayName }
    /// Only current/savings accounts can be linked in this version; card and loan accounts have
    /// sign conventions that aren't confirmed by the documentation.
    var isLinkable: Bool { BankingConstants.linkableCashAccountTypes.contains(cashAccountType.uppercased()) || cashAccountType.isEmpty }
    /// Swedbank Latvia reports multi-currency accounts (one IBAN, several currencies) with the
    /// ISO 4217 "no currency" code XXX; their balances and transactions carry real currencies.
    var isMultiCurrency: Bool { currencyCode.uppercased() == BankingConstants.multiCurrencyCode }
    /// Whether a WealthOS account in `currency` can represent this bank account. A multi-currency
    /// bank account is counted in the linked WealthOS account's currency.
    func accepts(_ currency: String) -> Bool {
        guard BankAmount.isCurrency(currency), currency != BankingConstants.multiCurrencyCode else { return false }
        return isMultiCurrency || currency == currencyCode
    }
    /// The currency balances are read and shown in: the bank's own, or for a multi-currency
    /// account the linked WealthOS account's (nil while it isn't linked).
    func countingCurrency(linkedAccountCurrency: String?) -> String? {
        isMultiCurrency ? linkedAccountCurrency : currencyCode
    }
}

nonisolated enum BankTransactionResolution: String, Sendable, CaseIterable {
    /// Not booked yet. Never in the ledger; replaced by the booked entry later.
    case pending
    /// Booked, waiting for the user's decision. Not in the ledger.
    case needsReview
    /// A ledger record was created for it (`ledgerRecordID`).
    case imported
    /// Represented by an existing ledger record (`ledgerRecordID`), e.g. a manual entry.
    case matched
    /// The user decided it must not be recorded (e.g. already tracked elsewhere).
    case ignored
}

nonisolated enum BankReviewReason: String, Sendable {
    case none = ""
    case possibleDuplicate
    case unclassified
    case foreignCurrency
    case identicalTwin
    case missingDirection
    case refundLike
    case ownTransferCurrency

    var message: String {
        switch self {
        case .none: ""
        case .possibleDuplicate: "May already be recorded manually — confirm it's the same, or add it."
        case .unclassified: "Is this income, spending, or a transfer between your own accounts?"
        case .foreignCurrency: "The amount is in a different currency than the account."
        case .identicalTwin: "Another identical transaction on the same day has no bank ID. Confirm both are real."
        case .missingDirection: "The bank didn't say whether money came in or went out."
        case .refundLike: "Looks like a card refund. Refunds aren't income."
        case .ownTransferCurrency: "Transfer between your accounts in different currencies."
        }
    }
}

/// Provenance and reconciliation state of one bank transaction. Never deleted by a sync once
/// booked, so a booked transaction can't be imported twice — even if the ledger record was
/// later edited or deleted by the user.
@Model
final class BankTransaction {
    var id: UUID = UUID()
    /// `accountKey|identity`. Unique per bank account.
    var key: String = ""
    var accountKey: String = ""
    /// "tid" (bank transaction_id), "ref" (entry_reference) or "fp" (content fingerprint).
    var identityKind: String = ""
    var providerTransactionID: String = ""
    var entryReference: String = ""
    var statusRaw: String = BankEntryStatus.booked.rawValue
    /// Signed: positive = money in, negative = money out. In `currencyCode`.
    var amount: Decimal = 0
    var currencyCode: String = ""
    var directionKnown: Bool = true
    var bookingDate: Date?
    var valueDate: Date?
    var transactionDate: Date?
    var counterpartyName: String = ""
    var counterpartyAccountHash: String = ""
    var counterpartyAccountMasked: String = ""
    var remittance: String = ""
    var referenceNumber: String = ""
    var bankTransactionCode: String = ""
    var merchantCategoryCode: String = ""
    /// Hash of amount, currency, direction and day; a change after import is flagged, never applied.
    var contentHash: String = ""
    var bankDataChanged: Bool = false
    var resolutionRaw: String = BankTransactionResolution.pending.rawValue
    var reviewReasonRaw: String = ""
    var ledgerRecordID: UUID?
    /// Comma-separated ids of manual records that may represent the same money.
    var candidateRecordIDs: String = ""
    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()

    init(key: String, accountKey: String, firstSeenAt: Date) {
        self.key = key
        self.accountKey = accountKey
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
    }

    var status: BankEntryStatus { BankEntryStatus(rawValue: statusRaw) ?? .other }
    var resolution: BankTransactionResolution {
        get { BankTransactionResolution(rawValue: resolutionRaw) ?? .needsReview }
        set { resolutionRaw = newValue.rawValue }
    }
    var reviewReason: BankReviewReason {
        get { BankReviewReason(rawValue: reviewReasonRaw) ?? .unclassified }
        set { reviewReasonRaw = newValue.rawValue }
    }
    var candidates: [UUID] { candidateRecordIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
    var day: Date? { bookingDate ?? valueDate ?? transactionDate }
    var title: String {
        if !counterpartyName.isEmpty { return counterpartyName }
        if let line = remittance.split(separator: "\n").first, !line.isEmpty { return String(line) }
        return amount < 0 ? "Bank payment" : "Bank deposit"
    }
}

/// The user's standing decision for a counterparty ("salary from ACME is income"), applied to
/// future imports so recurring items don't need review. Never applied retroactively.
@Model
final class BankCounterpartyRule {
    var id: UUID = UUID()
    /// "acct:<hash>" or "name:<normalized name>".
    var matchKey: String = ""
    /// "in" or "out".
    var direction: String = ""
    var actionRaw: String = BankRuleAction.expense.rawValue
    var categoryID: UUID?
    /// The other own account for transfers (source for "in", destination for "out").
    var otherAccountID: UUID?
    var label: String = ""
    var createdAt: Date = Date()

    init(matchKey: String, direction: String, action: BankRuleAction, categoryID: UUID?, otherAccountID: UUID?,
         label: String, createdAt: Date = .now) {
        self.matchKey = matchKey
        self.direction = direction
        self.actionRaw = action.rawValue
        self.categoryID = categoryID
        self.otherAccountID = otherAccountID
        self.label = label
        self.createdAt = createdAt
    }

    var action: BankRuleAction { BankRuleAction(rawValue: actionRaw) ?? .expense }
}

nonisolated enum BankRuleAction: String, Sendable, CaseIterable {
    case income, expense, transfer, refund, ignore
}

nonisolated enum BankingConstants {
    static let swedbankName = "Swedbank"
    static let latvia = "LV"
    static let callbackScheme = "wealthos"
    static let callbackHost = "bank-callback"
    /// ISO 4217 code for "no currency", used by Swedbank for multi-currency accounts.
    static let multiCurrencyCode = "XXX"
    /// ISO 20022 ExternalCashAccountType1Code values WealthOS links as cash accounts.
    static let linkableCashAccountTypes: Set<String> = ["CACC", "SVGS", "CASH", "TRAN", "SALA"]

    static func displayName(aspsp: String, country: String) -> String {
        country.isEmpty ? aspsp : "\(aspsp) (\(country))"
    }
}
