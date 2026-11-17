import CryptoKit
import Foundation
import SwiftData

// MARK: - Parsing

nonisolated enum BankDay {
    /// "YYYY-MM-DD" only; anything else is rejected rather than guessed.
    static func isValid(_ text: String) -> Bool {
        text.count == 10 && text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil && date(text, calendar: Calendar(identifier: .gregorian)) != nil
    }

    /// Noon of that calendar day, so it never shifts to a neighbouring day in any time zone shown.
    static func date(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        components.calendar = calendar
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    static func string(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    static func distance(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? .max)
    }
}

nonisolated enum BankAmount {
    /// Strict decimal parsing: digits with an optional sign and fraction. No exponents, no
    /// grouping, never via Double — "0.1" stays exactly 0.1.
    static func parse(_ text: String?) -> Decimal? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 40,
              text.wholeMatch(of: /[+-]?\d+(\.\d+)?/) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isCurrency(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }
}

nonisolated struct ParsedBankTransaction: Sendable, Equatable {
    enum IdentityKind: String, Sendable { case transactionID = "tid", entryReference = "ref", fingerprint = "fp" }

    var identityKind: IdentityKind
    var identity: String
    /// For fingerprint identities: 0 for the first of several identical rows, 1 for the next…
    var occurrence: Int = 0
    var providerTransactionID: String
    var entryReference: String
    var status: BankEntryStatus
    /// Signed: positive = in, negative = out.
    var amount: Decimal
    var directionKnown: Bool
    var currency: String
    var bookingDay: String?
    var valueDay: String?
    var transactionDay: String?
    var counterpartyName: String
    var counterpartyAccountHash: String
    var counterpartyAccountMasked: String
    var remittance: String
    var referenceNumber: String
    var bankCode: String
    var merchantCategoryCode: String

    var effectiveDay: String? { bookingDay ?? valueDay ?? transactionDay }
    var identityString: String { "\(identityKind.rawValue):\(identity)" }
    func key(accountKey: String) -> String { "\(accountKey)|\(identityString)" }

    var contentHash: String {
        BankHash.hex([amount.description, currency, directionKnown ? "1" : "0", effectiveDay ?? ""].joined(separator: "|"))
    }
}

nonisolated enum BankHash {
    static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedName(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

nonisolated enum BankParsing {
    struct Result: Sendable, Equatable {
        var transactions: [ParsedBankTransaction]
        /// Rows WealthOS couldn't read safely (no amount, no date, status OTHR…). Reported, never guessed.
        var skipped: Int
    }

    static func parse(_ rows: [BankTransactionDTO]) -> Result {
        var parsed: [ParsedBankTransaction] = []
        var skipped = 0
        for row in rows {
            guard let raw = BankAmount.parse(row.amount), BankAmount.isCurrency(row.currency),
                  let status = row.status.flatMap(BankEntryStatus.init(rawValue:)), status != .other else {
                skipped += 1
                continue
            }
            let days = [row.bookingDate, row.valueDate, row.transactionDate].map { $0.flatMap { BankDay.isValid($0) ? $0 : nil } }
            guard days.contains(where: { $0 != nil }) else { skipped += 1; continue }
            // Enable Banking states direction with credit_debit_indicator; the magnitude is used
            // regardless of how the amount is signed. Without an indicator a negative amount can
            // only mean "out"; a positive one is ambiguous and goes to review.
            let magnitude = raw < 0 ? -raw : raw
            let signed: Decimal
            let known: Bool
            switch row.creditDebitIndicator?.uppercased() {
            case "CRDT": signed = magnitude; known = true
            case "DBIT": signed = -magnitude; known = true
            default: signed = raw; known = raw < 0
            }
            let tid = clean(row.transactionID)
            let ref = clean(row.entryReference)
            let item = ParsedBankTransaction(
                identityKind: !tid.isEmpty ? .transactionID : (!ref.isEmpty ? .entryReference : .fingerprint),
                identity: !tid.isEmpty ? tid : ref,
                providerTransactionID: tid, entryReference: ref, status: status, amount: signed, directionKnown: known,
                currency: row.currency ?? "", bookingDay: days[0], valueDay: days[1], transactionDay: days[2],
                counterpartyName: String(clean(row.counterpartyName).prefix(140)),
                counterpartyAccountHash: clean(row.counterpartyAccountHash),
                counterpartyAccountMasked: String(clean(row.counterpartyAccountMasked).prefix(40)),
                remittance: String((row.remittance ?? []).map(clean).filter { !$0.isEmpty }.joined(separator: "\n").prefix(500)),
                referenceNumber: String(clean(row.referenceNumber).prefix(70)),
                bankCode: String(clean(row.bankTransactionCode).prefix(120)),
                merchantCategoryCode: String(clean(row.merchantCategoryCode).prefix(4)))
            parsed.append(item)
        }
        return Result(transactions: assignIdentities(parsed), skipped: skipped)
    }

    /// Rows without a bank identifier get a content fingerprint plus an occurrence number, so two
    /// genuinely identical payments on one day stay two (and the second is flagged for review).
    /// A bank id seen twice with *different* content can't be trusted as unique either, so those
    /// rows fall back to fingerprints too. Exact repeats (e.g. page overlap) collapse to one.
    static func assignIdentities(_ rows: [ParsedBankTransaction]) -> [ParsedBankTransaction] {
        var byID: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() where row.identityKind != .fingerprint {
            byID[row.identityString + "|" + row.status.rawValue, default: []].append(index)
        }
        var result = rows
        var dropped: Set<Int> = []
        for (_, indices) in byID where indices.count > 1 {
            let first = rows[indices[0]]
            if indices.allSatisfy({ rows[$0] == first }) {
                dropped.formUnion(indices.dropFirst())
            } else {
                for index in indices { result[index].identityKind = .fingerprint; result[index].identity = "" }
            }
        }
        // A booked row supersedes a pending row with the same bank id within one fetch.
        let bookedIDs = Set(result.enumerated().filter { !dropped.contains($0.offset) && $0.element.status == .booked
            && $0.element.identityKind != .fingerprint }.map(\.element.identityString))
        for (index, row) in result.enumerated() where row.status == .pending && row.identityKind != .fingerprint
            && bookedIDs.contains(row.identityString) {
            dropped.insert(index)
        }
        var counts: [String: Int] = [:]
        for index in result.indices where !dropped.contains(index) && result[index].identityKind == .fingerprint {
            let row = result[index]
            let base = BankHash.hex([row.status.rawValue, row.effectiveDay ?? "", row.amount.description, row.currency,
                                     row.counterpartyAccountHash, BankHash.normalizedName(row.counterpartyName),
                                     BankHash.normalizedName(row.remittance), row.referenceNumber].joined(separator: "|"))
            let n = counts[base, default: 0]
            counts[base] = n + 1
            result[index].identity = "\(base)#\(n)"
            result[index].occurrence = n
        }
        return result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    private static func clean(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline || $0 == "\n" }
    }
}

// MARK: - Balance selection

nonisolated struct SelectedBankBalance: Sendable, Equatable {
    var amount: Decimal
    var type: BankBalanceType
    var referenceDay: String?
}

nonisolated enum BankBalanceSelection {
    /// Booked balances are what the account actually holds; "expected" adds pending items.
    /// Available balances can include an overdraft/credit limit, which is not the user's money,
    /// so they're used only when the bank explicitly reports a zero credit limit.
    static let preference: [BankBalanceType] = [.interimBooked, .closingBooked, .expected, .openingBooked]
    static let availableTypes: [BankBalanceType] = [.interimAvailable, .closingAvailable]

    /// `otherCurrencies: true` for multi-currency accounts, whose balance list legitimately holds one
    /// entry per currency; for single-currency accounts any other currency is an error.
    static func select(_ balances: [BankBalanceDTO], currency: String, creditLimit: Decimal?,
                       otherCurrencies: Bool = false) throws -> SelectedBankBalance {
        struct Candidate { var amount: Decimal; var type: BankBalanceType; var day: String?; var changed: String? }
        var candidates: [Candidate] = []
        for balance in balances {
            guard let type = balance.balanceType.flatMap(BankBalanceType.init(rawValue:)),
                  let amount = BankAmount.parse(balance.amount) else { continue }
            guard (balance.currency ?? "").uppercased() == currency.uppercased() else {
                if preference.contains(type), !otherCurrencies { throw BankingError.currencyMismatch }
                continue
            }
            candidates.append(Candidate(amount: amount, type: type,
                                        day: balance.referenceDate.flatMap { BankDay.isValid($0) ? $0 : nil },
                                        changed: balance.lastChangeDateTime))
        }
        var usable = preference
        if creditLimit == 0 { usable += availableTypes }
        let ranked = candidates.filter { usable.contains($0.type) }.sorted { a, b in
            // Most recent first (reference day, then change time); then by preference order.
            let ad = a.day ?? "", bd = b.day ?? ""
            if ad != bd { return ad > bd }
            let ac = a.changed ?? "", bc = b.changed ?? ""
            if ac != bc { return ac > bc }
            return (usable.firstIndex(of: a.type) ?? 99) < (usable.firstIndex(of: b.type) ?? 99)
        }
        // A booked type always beats "expected"/"available" when one is present.
        let booked = ranked.first { [.interimBooked, .closingBooked, .openingBooked].contains($0.type) }
        guard let pick = booked ?? ranked.first else { throw BankingError.noConfirmedBalance }
        return SelectedBankBalance(amount: pick.amount, type: pick.type, referenceDay: pick.day)
    }
}

// MARK: - Reconciliation

enum BankReconciler {
    struct Outcome: Equatable {
        var newRows = 0
        var imported = 0
        var matched = 0
        var needsReview = 0
        var pendingRemoved = 0
        var skipped = 0
        var changedAfterImport = 0
    }

    static func ledgerFingerprint(for key: String) -> String { "eb:" + String(BankHash.hex(key).prefix(40)) }
    static func isBankImport(_ record: TransactionRecord) -> Bool { record.importFingerprint?.hasPrefix("eb:") == true }

    /// Stores the confirmed balance. Only called with a balance that passed `BankBalanceSelection`.
    static func applyBalance(_ balance: SelectedBankBalance, to link: BankAccountLink, calendar: Calendar) {
        link.balanceAmount = balance.amount
        link.balanceTypeRaw = balance.type.rawValue
        link.balanceReferenceDate = balance.referenceDay.flatMap { BankDay.date($0, calendar: calendar) }
        link.restoredFromBackup = false
    }

    /// Idempotent merge of one fully read transaction window into the store. Booked rows are
    /// keyed by `accountKey|identity` and never deleted, so re-reading overlapping windows,
    /// retrying failed syncs or a pending entry turning booked can't create a second record.
    /// Callers wrap this in `Persistence.commit` (all-or-nothing per account).
    static func apply(_ parsed: BankParsing.Result, link: BankAccountLink, now: Date, calendar: Calendar,
                      in context: ModelContext) throws -> Outcome {
        guard let localID = link.localAccountID,
              let account = try context.fetch(FetchDescriptor<Account>()).first(where: { $0.id == localID }) else {
            throw BankingError.notFound
        }
        var outcome = Outcome(skipped: parsed.skipped)
        let importStart = calendar.startOfDay(for: link.importStartDate ?? now)
        let accountKey = link.accountKey
        let existing = try context.fetch(FetchDescriptor<BankTransaction>(predicate: #Predicate { $0.accountKey == accountKey }))
        var byKey: [String: BankTransaction] = [:]
        for row in existing { byKey[row.key] = row }
        var seen: Set<String> = []
        var toResolve: [BankTransaction] = []

        for item in parsed.transactions {
            guard let dayText = item.effectiveDay, let day = BankDay.date(dayText, calendar: calendar) else {
                outcome.skipped += 1
                continue
            }
            if day < importStart { continue }
            let key = item.key(accountKey: accountKey)
            seen.insert(key)
            if let row = byKey[key] {
                row.lastSeenAt = now
                if row.status == .pending {
                    fill(row, with: item, calendar: calendar)
                    if item.status == .booked { toResolve.append(row) }
                } else if item.status == .booked, row.contentHash != item.contentHash {
                    // The bank changed a booked entry. Never rewrite the ledger silently.
                    row.bankDataChanged = true
                    outcome.changedAfterImport += 1
                }
            } else {
                let row = BankTransaction(key: key, accountKey: accountKey, firstSeenAt: now)
                fill(row, with: item, calendar: calendar)
                row.resolution = item.status == .booked ? .needsReview : .pending
                context.insert(row)
                byKey[key] = row
                outcome.newRows += 1
                if item.status == .booked { toResolve.append(row) }
            }
        }
        // Pending entries the bank no longer reports were either booked (under a new id) or
        // dropped. They were never in the ledger, so removing them can't change any total.
        for row in existing where row.status == .pending && !seen.contains(row.key) {
            context.delete(row)
            outcome.pendingRemoved += 1
        }
        try resolve(toResolve, link: link, account: account, now: now, calendar: calendar, in: context, outcome: &outcome)
        return outcome
    }

    private static func fill(_ row: BankTransaction, with item: ParsedBankTransaction, calendar: Calendar) {
        row.identityKind = item.identityKind.rawValue
        row.providerTransactionID = item.providerTransactionID
        row.entryReference = item.entryReference
        row.statusRaw = item.status.rawValue
        row.amount = item.amount
        row.directionKnown = item.directionKnown
        row.currencyCode = item.currency
        row.bookingDate = item.bookingDay.flatMap { BankDay.date($0, calendar: calendar) }
        row.valueDate = item.valueDay.flatMap { BankDay.date($0, calendar: calendar) }
        row.transactionDate = item.transactionDay.flatMap { BankDay.date($0, calendar: calendar) }
        row.counterpartyName = item.counterpartyName
        row.counterpartyAccountHash = item.counterpartyAccountHash
        row.counterpartyAccountMasked = item.counterpartyAccountMasked
        row.remittance = item.remittance
        row.referenceNumber = item.referenceNumber
        row.bankTransactionCode = item.bankCode
        row.merchantCategoryCode = item.merchantCategoryCode
        row.contentHash = item.contentHash
        row.reviewReasonRaw = item.occurrence > 0 ? BankReviewReason.identicalTwin.rawValue : ""
    }

    // MARK: Resolution

    struct Context {
        var records: [TransactionRecord]
        var accountsByID: [UUID: Account]
        /// Ledger record → bank accounts whose transaction already accounts for it.
        var claims: [UUID: Set<String>]
        /// accountKey → linked WealthOS account, for recognising transfers between own accounts.
        var ownAccounts: [String: UUID]
        var rules: [BankCounterpartyRule]
        var categories: [TransactionCategory]
    }

    static func makeContext(in context: ModelContext) throws -> Context {
        let rows = try context.fetch(FetchDescriptor<BankTransaction>())
        var claims: [UUID: Set<String>] = [:]
        for row in rows {
            if let id = row.ledgerRecordID, row.resolution == .imported || row.resolution == .matched {
                claims[id, default: []].insert(row.accountKey)
            }
        }
        var own: [String: UUID] = [:]
        for link in try context.fetch(FetchDescriptor<BankAccountLink>()) {
            if let local = link.localAccountID { own[link.accountKey] = local }
        }
        let accounts = try context.fetch(FetchDescriptor<Account>())
        return Context(records: try context.fetch(FetchDescriptor<TransactionRecord>()),
                       accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                       claims: claims, ownAccounts: own,
                       rules: try context.fetch(FetchDescriptor<BankCounterpartyRule>()),
                       categories: try context.fetch(FetchDescriptor<TransactionCategory>()))
    }

    private static func resolve(_ rows: [BankTransaction], link: BankAccountLink, account: Account, now: Date,
                                calendar: Calendar, in context: ModelContext, outcome: inout Outcome) throws {
        guard !rows.isEmpty else { return }
        var ctx = try makeContext(in: context)
        let sorted = rows.sorted { ($0.day ?? .distantPast, $0.key) < ($1.day ?? .distantPast, $1.key) }
        // Which manual records each row could be, and how many rows want each record.
        var candidates: [String: [TransactionRecord]] = [:]
        var demand: [UUID: Int] = [:]
        for row in sorted {
            let found = manualCandidates(for: row, accountID: account.id, accountKey: link.accountKey, ctx: ctx, calendar: calendar)
            candidates[row.key] = found
            for record in found { demand[record.id, default: 0] += 1 }
        }

        let fingerprinted = Dictionary(ctx.records.compactMap { record in record.importFingerprint.map { ($0, record) } },
                                       uniquingKeysWith: { a, _ in a })
        for row in sorted {
            // Already imported once (e.g. the provenance row was lost but the ledger record wasn't).
            let decision = fingerprinted[ledgerFingerprint(for: row.key)].map { Decision.match($0) }
                ?? classify(row, link: link, account: account, candidates: candidates[row.key] ?? [], demand: demand,
                            ctx: ctx, calendar: calendar)
            switch decision {
            case .review(let reason, let ids):
                row.resolution = .needsReview
                row.reviewReason = reason
                row.candidateRecordIDs = ids.map(\.uuidString).joined(separator: ",")
                outcome.needsReview += 1
            case .match(let record):
                row.resolution = .matched
                row.ledgerRecordID = record.id
                row.reviewReasonRaw = ""
                ctx.claims[record.id, default: []].insert(link.accountKey)
                outcome.matched += 1
            case .create(let kind, let categoryID, let other):
                let record = makeRecord(for: row, kind: kind, accountID: account.id, otherAccountID: other, categoryID: categoryID)
                context.insert(record)
                ctx.records.append(record)
                row.resolution = .imported
                row.ledgerRecordID = record.id
                row.reviewReasonRaw = ""
                ctx.claims[record.id, default: []].insert(link.accountKey)
                outcome.imported += 1
            case .ignore:
                row.resolution = .ignored
                row.reviewReasonRaw = ""
            }
        }
    }

    enum Decision {
        case review(BankReviewReason, [UUID])
        case match(TransactionRecord)
        case create(TransactionKind, categoryID: UUID?, otherAccountID: UUID?)
        case ignore
    }

    static func classify(_ row: BankTransaction, link: BankAccountLink, account: Account, candidates: [TransactionRecord],
                         demand: [UUID: Int], ctx: Context, calendar: Calendar) -> Decision {
        if row.currencyCode != account.currencyCode { return .review(.foreignCurrency, []) }
        if !row.directionKnown || row.amount == 0 { return .review(.missingDirection, []) }
        if row.reviewReason == .identicalTwin { return .review(.identicalTwin, candidates.map(\.id)) }
        let magnitude = row.amount < 0 ? -row.amount : row.amount
        guard let day = row.day else { return .review(.unclassified, []) }

        // 1. Transfer between two linked bank accounts: one shared ledger transfer, whichever side
        //    arrives first creates it, the other side attaches to it.
        if !row.counterpartyAccountHash.isEmpty, row.counterpartyAccountHash != link.accountKey,
           let otherID = ctx.ownAccounts[row.counterpartyAccountHash], let other = ctx.accountsByID[otherID] {
            guard other.currencyCode == account.currencyCode else { return .review(.ownTransferCurrency, []) }
            let (source, destination) = row.amount < 0 ? (account.id, otherID) : (otherID, account.id)
            let existing = ctx.records.filter { record in
                record.kind == .transfer && record.accountID == source && record.destinationAccountID == destination
                    && record.amount == magnitude && (record.destinationAmount ?? record.amount) == magnitude
                    && BankDay.distance(record.date, day, calendar: calendar) <= 3
                    && !(ctx.claims[record.id]?.contains(link.accountKey) ?? false)
            }.min { BankDay.distance($0.date, day, calendar: calendar) < BankDay.distance($1.date, day, calendar: calendar) }
            if let existing { return .match(existing) }
            return .create(.transfer, categoryID: nil, otherAccountID: otherID)
        }

        // 2. Possibly already entered by hand. Auto-match only an unambiguous, same-day, exact
        //    amount pair; anything less certain is the user's call.
        if !candidates.isEmpty {
            let sameDay = candidates.filter { record in
                [row.bookingDate, row.transactionDate].compactMap { $0 }.contains { BankDay.distance(record.date, $0, calendar: calendar) == 0 }
            }
            if candidates.count == 1, let only = sameDay.first, sameDay.count == 1, demand[only.id] == 1 {
                return .match(only)
            }
            return .review(.possibleDuplicate, candidates.map(\.id))
        }

        // 3. The user's standing rule for this counterparty.
        if let rule = rule(for: row, rules: ctx.rules) {
            switch rule.action {
            case .ignore: return .ignore
            case .income where row.amount > 0:
                return .create(.income, categoryID: validCategory(rule.categoryID, kind: .income, ctx: ctx), otherAccountID: nil)
            case .expense where row.amount < 0:
                return .create(.expense, categoryID: validCategory(rule.categoryID, kind: .expense, ctx: ctx), otherAccountID: nil)
            case .refund where row.amount > 0:
                return .create(.adjustment, categoryID: nil, otherAccountID: nil)
            case .transfer:
                if let otherID = rule.otherAccountID, let other = ctx.accountsByID[otherID], otherID != account.id,
                   other.currencyCode == account.currencyCode {
                    return .create(.transfer, categoryID: nil, otherAccountID: otherID)
                }
            default: break
            }
        }

        // 4. Clear-cut card spending, bank fees and payments to a recognised merchant, with a
        //    suggested category. Everything else — incoming money (salary, loan repayments,
        //    transfers from own accounts elsewhere), other outgoing transfers and cash
        //    withdrawals — waits for the user rather than becoming income or expense.
        let code = row.bankTransactionCode.uppercased()
        let isCash = ["6010", "6011"].contains(row.merchantCategoryCode) || code.contains("CWDL")
        let isCard = !row.merchantCategoryCode.isEmpty || code.contains("CCRD") || code.contains("POSD")
            || BankCategorizer.isCardPurchase(row)
        let isFee = code.contains("FEES") || code.contains("CHRG")
        if row.amount < 0, !isCash {
            let suggestion = BankCategorizer.suggest(for: row, kind: .expense, categories: ctx.categories, rules: ctx.rules)
            if isCard || isFee || suggestion != nil {
                return .create(.expense, categoryID: suggestion?.categoryID ?? validCategory(nil, kind: .expense, ctx: ctx),
                               otherAccountID: nil)
            }
        }
        if row.amount > 0, isCard, !isCash { return .review(.refundLike, []) }
        return .review(.unclassified, [])
    }

    /// Unclaimed manual (non-imported) records on the linked account with the same direction and
    /// exact amount, dated within three days.
    static func manualCandidates(for row: BankTransaction, accountID: UUID, accountKey: String, ctx: Context,
                                 calendar: Calendar) -> [TransactionRecord] {
        guard row.directionKnown, row.amount != 0 else { return [] }
        let days = [row.bookingDate, row.transactionDate, row.valueDate].compactMap { $0 }
        guard !days.isEmpty else { return [] }
        let magnitude = row.amount < 0 ? -row.amount : row.amount
        return ctx.records.filter { record in
            guard !isBankImport(record), !(ctx.claims[record.id]?.contains(accountKey) ?? false),
                  days.contains(where: { BankDay.distance(record.date, $0, calendar: calendar) <= 3 }) else { return false }
            switch record.kind {
            case .expense: return row.amount < 0 && record.accountID == accountID && record.amount == magnitude
            case .income: return row.amount > 0 && record.accountID == accountID && record.amount == magnitude
            case .transfer:
                if row.amount < 0 { return record.accountID == accountID && record.amount == magnitude }
                return record.destinationAccountID == accountID && (record.destinationAmount ?? record.amount) == magnitude
            case .adjustment: return false
            }
        }
    }

    static func ruleKeys(for row: BankTransaction) -> [String] {
        var keys: [String] = []
        if !row.counterpartyAccountHash.isEmpty { keys.append("acct:" + row.counterpartyAccountHash) }
        let name = BankHash.normalizedName(row.counterpartyName)
        if !name.isEmpty { keys.append("name:" + name) }
        // Swedbank card purchases name the shop only in the payment details ("PIRKUMS 4*** ****1234
        // 03.11.2026 BOOZIE RIGA"): the words without numbers identify the merchant.
        if BankCategorizer.isCardPurchase(row) {
            let words = BankHash.normalizedName(row.remittance).split(separator: " ").map(String.init)
                .filter { word in !word.contains(where: \.isNumber) && !BankCategorizer.cardPurchaseWords.contains(word)
                    && !BankCategorizer.merchantNoiseWords.contains(word) }
            if !words.isEmpty { keys.append("merchant:" + words.prefix(4).joined(separator: " ")) }
        }
        return keys
    }

    static func rule(for row: BankTransaction, rules: [BankCounterpartyRule]) -> BankCounterpartyRule? {
        let direction = row.amount < 0 ? "out" : "in"
        for key in ruleKeys(for: row) {
            if let rule = rules.first(where: { $0.matchKey == key && $0.direction == direction }) { return rule }
        }
        return nil
    }

    private static func validCategory(_ id: UUID?, kind: CategoryKind, ctx: Context) -> UUID? {
        if let id, ctx.categories.contains(where: { $0.id == id && $0.kind == kind }) { return id }
        return ctx.categories.first { $0.kind == kind && $0.isSystem }?.id
    }

    static func makeRecord(for row: BankTransaction, kind: TransactionKind, accountID: UUID, otherAccountID: UUID?,
                           categoryID: UUID?) -> TransactionRecord {
        let magnitude = row.amount < 0 ? -row.amount : row.amount
        var source = accountID
        var destination: UUID?
        if kind == .transfer, let otherAccountID {
            (source, destination) = row.amount < 0 ? (accountID, otherAccountID) : (otherAccountID, accountID)
        }
        return TransactionRecord(kind: kind, amount: kind == .adjustment ? row.amount : magnitude, date: row.day ?? .now,
                                 note: String(row.title.prefix(80)), accountID: source, destinationAccountID: destination,
                                 categoryID: kind.categoryKind == nil ? nil : categoryID,
                                 importFingerprint: ledgerFingerprint(for: row.key))
    }
}

// MARK: - Review decisions

enum BankReviewDecision: Equatable {
    /// The bank transaction is the same money as this existing record.
    case sameAs(UUID)
    case income(categoryID: UUID?)
    case expense(categoryID: UUID?)
    /// Transfer with another own account (source for money in, destination for money out).
    case transfer(otherAccountID: UUID)
    /// Money back for an earlier purchase: changes the balance, but isn't income.
    case refund
    case ignore
}

enum BankReview {
    /// Applies the user's decision to one booked transaction waiting for review.
    static func resolve(_ row: BankTransaction, decision: BankReviewDecision, remember: Bool, now: Date = .now,
                        in context: ModelContext) throws {
        guard row.status == .booked, row.resolution == .needsReview else { throw BankingError.invalidResponse }
        let accountKey = row.accountKey
        guard let link = try context.fetch(FetchDescriptor<BankAccountLink>(predicate: #Predicate { $0.accountKey == accountKey })).first,
              let localID = link.localAccountID else { throw BankingError.notFound }
        let ctx = try BankReconciler.makeContext(in: context)
        guard let account = ctx.accountsByID[localID] else { throw BankingError.notFound }
        let money = row.amount
        switch decision {
        case .sameAs(let id):
            guard let record = ctx.records.first(where: { $0.id == id }),
                  !(ctx.claims[id]?.contains(row.accountKey) ?? false) else { throw BankingError.notFound }
            row.resolution = .matched
            row.ledgerRecordID = record.id
        case .income(let category), .expense(let category):
            let isIncome = { if case .income = decision { return true } else { return false } }()
            guard (money > 0) == isIncome, row.currencyCode == account.currencyCode else { throw BankingError.currencyMismatch }
            // "Default" means the system category of that kind, as automatic imports use.
            let kind: CategoryKind = isIncome ? .income : .expense
            let chosen = category.flatMap { id in ctx.categories.first { $0.id == id && $0.kind == kind }?.id }
                ?? ctx.categories.first { $0.kind == kind && $0.isSystem }?.id
            try create(row, kind: isIncome ? .income : .expense, account: account, other: nil, category: chosen, in: context)
        case .transfer(let otherID):
            guard otherID != account.id, let other = ctx.accountsByID[otherID], other.currencyCode == account.currencyCode,
                  row.currencyCode == account.currencyCode else { throw BankingError.currencyMismatch }
            try create(row, kind: .transfer, account: account, other: otherID, category: nil, in: context)
        case .refund:
            guard money > 0, row.currencyCode == account.currencyCode else { throw BankingError.currencyMismatch }
            try create(row, kind: .adjustment, account: account, other: nil, category: nil, in: context)
        case .ignore:
            row.resolution = .ignored
        }
        row.reviewReasonRaw = ""
        row.candidateRecordIDs = ""
        if remember, let key = BankReconciler.ruleKeys(for: row).first, let action = ruleAction(decision) {
            let direction = money < 0 ? "out" : "in"
            for old in try context.fetch(FetchDescriptor<BankCounterpartyRule>()) where old.matchKey == key && old.direction == direction {
                context.delete(old)
            }
            let (category, other): (UUID?, UUID?) = switch decision {
            case .income(let c), .expense(let c): (c, nil)
            case .transfer(let o): (nil, o)
            default: (nil, nil)
            }
            context.insert(BankCounterpartyRule(matchKey: key, direction: direction, action: action, categoryID: category,
                                                otherAccountID: other, label: row.title, createdAt: now))
        }
    }

    /// Rows the bulk action may record: only "couldn't classify" ones. Possible duplicates,
    /// identical twins, refund-like card credits, foreign currency and unknown direction keep
    /// waiting for an individual decision.
    static func isBulkRecordable(_ row: BankTransaction) -> Bool {
        row.status == .booked && row.resolution == .needsReview && row.reviewReason == .unclassified
            && row.directionKnown && row.amount != 0 && row.candidates.isEmpty
    }

    /// The user's explicit "record all as income/expense": money in → income, money out → expense,
    /// default categories. Returns how many rows were recorded. Callers wrap it in `Persistence.commit`.
    @discardableResult
    static func recordAllAsIncomeOrExpense(_ rows: [BankTransaction], now: Date = .now, in context: ModelContext) throws -> Int {
        var count = 0
        let categories = try context.fetch(FetchDescriptor<TransactionCategory>())
        let rules = try context.fetch(FetchDescriptor<BankCounterpartyRule>())
        for row in rows where isBulkRecordable(row) {
            let kind: CategoryKind = row.amount > 0 ? .income : .expense
            let category = BankCategorizer.suggest(for: row, kind: kind, categories: categories, rules: rules)?.categoryID
            do {
                try resolve(row, decision: row.amount > 0 ? .income(categoryID: category) : .expense(categoryID: category),
                            remember: false, now: now, in: context)
                count += 1
            } catch BankingError.currencyMismatch {
                continue // account currency differs: stays in review
            }
        }
        return count
    }

    /// Sends a matched transaction back to review (the user says it isn't the same money).
    /// The manual record itself is never changed.
    static func unmatch(_ row: BankTransaction) {
        guard row.resolution == .matched else { return }
        row.resolution = .needsReview
        row.reviewReason = .unclassified
        row.ledgerRecordID = nil
    }

    private static func ruleAction(_ decision: BankReviewDecision) -> BankRuleAction? {
        switch decision {
        case .sameAs: nil
        case .income: .income
        case .expense: .expense
        case .transfer: .transfer
        case .refund: .refund
        case .ignore: .ignore
        }
    }

    private static func create(_ row: BankTransaction, kind: TransactionKind, account: Account, other: UUID?, category: UUID?,
                               in context: ModelContext) throws {
        let record = BankReconciler.makeRecord(for: row, kind: kind, accountID: account.id, otherAccountID: other, categoryID: category)
        context.insert(record)
        row.resolution = .imported
        row.ledgerRecordID = record.id
    }
}
