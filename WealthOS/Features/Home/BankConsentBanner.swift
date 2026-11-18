import SwiftUI
import SwiftData

/// Home banner when bank access ends within a week or has ended: without a reconnect,
/// syncing stops silently. Opens Bank Connections to reconnect.
struct BankConsentBanner: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \BankConnection.createdAt) private var connections: [BankConnection]

    struct Notice: Equatable {
        let bankName: String
        /// Negative = already expired.
        let daysLeft: Int

        var title: String {
            switch daysLeft {
            case ..<0: "\(bankName) access has expired"
            case 0: "\(bankName) access ends today"
            case 1: "\(bankName) access ends tomorrow"
            default: "\(bankName) access ends in \(daysLeft) days"
            }
        }
    }

    /// The most urgent connection within `window` days of its end, or already expired.
    static func notice(for connections: [BankConnection], now: Date = .now, window: Int = 7,
                       calendar: Calendar = .current) -> Notice? {
        connections.compactMap { connection -> Notice? in
            switch connection.status {
            case .expired:
                return Notice(bankName: connection.title, daysLeft: -1)
            case .active:
                guard let until = connection.validUntil else { return nil }
                if until <= now { return Notice(bankName: connection.title, daysLeft: -1) }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                   to: calendar.startOfDay(for: until)).day ?? 0
                return days <= window ? Notice(bankName: connection.title, daysLeft: days) : nil
            default:
                return nil
            }
        }
        .min { $0.daysLeft < $1.daysLeft }
    }

    var body: some View {
        if !app.isDemoMode, let notice = Self.notice(for: connections) {
            NavigationLink { BankConnectionsSettingsView() } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "building.columns.fill", color: Theme.warning, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title).font(.subheadline.weight(.semibold))
                        Text("Reconnect to keep syncing. Your data is kept.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .card(padding: 14)
        }
    }
}
