import SwiftUI
import UIKit

/// Company logos from Trading 212's public image server, keyed by Trading 212 ticker
/// (e.g. "AAPL_US_EQ"). Each logo is downloaded once and cached in Caches; a missing logo is
/// remembered for a week. Only the ticker is sent — no account data, no credentials.
/// Off when the user turns off Settings → Investment Integrations → Company Logos.
actor LogoCache {
    static let shared = LogoCache()
    static let host = "trading212equities.s3.eu-central-1.amazonaws.com"
    static let maximumBytes = 400_000
    static let missingRetry: TimeInterval = 7 * 86_400

    private var memory: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession
    private let directory: URL

    init(directory: URL = URL.cachesDirectory.appending(path: "Logos", directoryHint: .isDirectory)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": "WealthOS"]
        session = URLSession(configuration: configuration)
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Plain Trading 212 ticker characters only, so nothing else can be put into the URL.
    static func isValidTicker(_ ticker: String) -> Bool {
        !ticker.isEmpty && ticker.count <= 32 && ticker.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
    }

    static func url(for ticker: String) -> URL? {
        guard isValidTicker(ticker) else { return nil }
        return URL(string: "https://\(host)/\(ticker).png")
    }

    func cachedImage(_ ticker: String) -> UIImage? {
        if let image = memory[ticker] { return image }
        guard let data = try? Data(contentsOf: file(ticker)), let image = UIImage(data: data) else { return nil }
        memory[ticker] = image
        return image
    }

    func image(_ ticker: String) async -> UIImage? {
        if let image = cachedImage(ticker) { return image }
        if let marked = try? FileManager.default.attributesOfItem(atPath: missingFile(ticker).path)[.modificationDate] as? Date,
           Date.now.timeIntervalSince(marked) < Self.missingRetry { return nil }
        if let task = inFlight[ticker] {
            // An empty image is the "not on the server" marker, never a logo.
            let shared = await task.value
            return shared?.size == .zero ? nil : shared
        }
        guard let url = Self.url(for: ticker) else { return nil }
        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200, http.url?.host == Self.host, data.count <= Self.maximumBytes,
                  http.mimeType?.hasPrefix("image/") == true, let image = UIImage(data: data) else {
                return http.statusCode == 403 || http.statusCode == 404 ? UIImage() : nil
            }
            return image
        }
        inFlight[ticker] = task
        let result = await task.value
        inFlight[ticker] = nil
        guard let result else { return nil }
        if result.size == .zero {
            // Not on the server: don't ask again for a week.
            FileManager.default.createFile(atPath: missingFile(ticker).path, contents: Data())
            return nil
        }
        if let png = result.pngData() { try? png.write(to: file(ticker), options: .atomic) }
        memory[ticker] = result
        return result
    }

    private func file(_ ticker: String) -> URL { directory.appending(path: "\(ticker).png") }
    private func missingFile(_ ticker: String) -> URL { directory.appending(path: "\(ticker).missing") }
}

/// Logo tile: the company logo on a white rounded square, or a colored monogram.
struct TickerLogo: View {
    /// Trading 212 ticker to load a logo for; nil = monogram only.
    let ticker: String?
    /// Short symbol for the monogram (e.g. "AAPL").
    let symbol: String
    var size: CGFloat = 40
    @AppStorage(SettingsKey.companyLogos) private var logosEnabled = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(.white)
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.1)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Self.color(for: symbol).gradient)
                Text(Self.monogram(symbol))
                    .font(.system(size: size * (Self.monogram(symbol).count > 2 ? 0.28 : 0.38), weight: .bold, design: .rounded))
                    .foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(ticker ?? "")|\(logosEnabled)") {
            guard logosEnabled, let ticker, !Persistence.isHostingTests() else { image = nil; return }
            if let cached = await LogoCache.shared.cachedImage(ticker) { image = cached; return }
            let loaded = await LogoCache.shared.image(ticker)
            image = loaded?.size == .zero ? nil : loaded
        }
    }

    static func monogram(_ symbol: String) -> String {
        let letters = symbol.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(4)).isEmpty ? "?" : String(letters.prefix(4))
    }

    /// Stable color per symbol.
    static func color(for symbol: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .mint, .red]
        let hash = symbol.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}
