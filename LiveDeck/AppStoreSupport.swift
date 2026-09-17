import SwiftUI
import AppKit
import StoreKit

// MARK: - Mac App Store edition
//
// Built with the APPSTORE compilation condition (set in the Xcode project in AppStore/project.yml):
//   • 14-day free trial, then a one-time purchase (StoreKit 2, two non-consumable in-app purchases):
//       <bundle id>.trial14  — "14-Day Free Trial", price Free (Apple's required pattern for time-based trials)
//       <bundle id>.full     — "LiveDeck Studio Full Version", your price
//     The trial starts when the free trial item is "bought"; its date comes from Apple and syncs across the
//     user's Macs, so reinstalling does not restart the trial.
//   • App Sandbox: files the user opens are remembered with security-scoped bookmarks.
// Builds without APPSTORE (GitHub / direct download) are fully unlocked and unchanged.

enum AppEdition {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}

// MARK: - Licence (trial + purchase)

@MainActor
final class LicenseManager: ObservableObject {
    enum State: Equatable {
        case checking
        case needsTrial
        case trial(daysLeft: Int, endsOn: Date)
        case expired
        case purchased
        case unlocked            // non-App Store builds
    }

    static let trialDays = 14

    @Published private(set) var state: State = .checking
    @Published private(set) var trialProduct: Product?
    @Published private(set) var fullProduct: Product?
    @Published var busy = false
    @Published var message = ""
    @Published var showPaywall = false

    let trialID: String
    let fullID: String
    private var updatesTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = Bundle.main.bundleIdentifier ?? "com.shamaapps.livedeck"
        trialID = (info["LDTrialProductID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundle + ".trial14"
        fullID = (info["LDFullProductID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundle + ".full"
        if !AppEdition.isAppStore { state = .unlocked }
    }

    /// True when the app must show the purchase screen before it can be used.
    var isLocked: Bool { state == .needsTrial || state == .expired }

    var isTrial: Bool { if case .trial = state { return true }; return false }

    func start() async {
        guard AppEdition.isAppStore else { return }
        updatesTask?.cancel()
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        await loadProducts()
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [trialID, fullID])
            trialProduct = products.first { $0.id == trialID }
            fullProduct = products.first { $0.id == fullID }
            if products.isEmpty { message = "The App Store products could not be loaded. Check your internet connection." }
        } catch {
            message = "Could not reach the App Store: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard AppEdition.isAppStore else { state = .unlocked; return }
        var purchased = false
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == fullID { purchased = true }
            if t.productID == trialID { trialStart = t.originalPurchaseDate }
        }
        if purchased { state = .purchased; showPaywall = false; return }
        guard let start = trialStart else { state = .needsTrial; return }
        var trialLength = Double(Self.trialDays) * 86_400
        #if DEBUG
        // Testing only: LIVEDECK_TRIAL_SECONDS=120 in the Xcode scheme makes the trial end after 2 minutes.
        if let s = ProcessInfo.processInfo.environment["LIVEDECK_TRIAL_SECONDS"], let v = Double(s) { trialLength = v }
        #endif
        let ends = start.addingTimeInterval(trialLength)
        let left = ends.timeIntervalSinceNow
        state = left > 0 ? .trial(daysLeft: max(1, Int((left / 86_400).rounded(.up))), endsOn: ends) : .expired
    }

    func buy(_ product: Product) async {
        busy = true
        defer { busy = false }
        message = ""
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification { await t.finish() } else { message = "The purchase could not be verified." }
                await refresh()
            case .pending:
                message = "The purchase is waiting for approval (Ask to Buy)."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func startTrial() async {
        if trialProduct == nil { await loadProducts() }
        guard let p = trialProduct else { message = "The free trial is not available right now. Please try again."; return }
        await buy(p)
    }

    func buyFull() async {
        if fullProduct == nil { await loadProducts() }
        guard let p = fullProduct else { message = "The purchase is not available right now. Please try again."; return }
        await buy(p)
    }

    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = state == .purchased ? "Your purchase has been restored." :
                (isTrial ? "Your free trial has been restored." : "No purchase was found for this Apple ID.")
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Purchase screen

struct PaywallView: View {
    @EnvironmentObject var license: LicenseManager
    var dismissible = false
    @Environment(\.dismiss) private var dismiss

    private let features = [
        ("rectangle.split.3x1", "Live switcher with transitions, keys, multiview and Program Out"),
        ("music.note.list", "Songs, Bible, dictionary and AI-assisted slides"),
        ("dot.radiowaves.left.and.right", "Stream, record, NDI® in and out, Zoom and network inputs"),
        ("slider.horizontal.3", "Audio mixer with effects, overlays, countdowns and automation"),
        ("display.2", "External displays, LED walls, stage display and LAN collaboration")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LiveDeck Studio").font(.system(size: 22, weight: .bold)).foregroundColor(CP.text)
                    Text(headline).font(.system(size: 13)).foregroundColor(CP.text2)
                }
                Spacer()
                if dismissible {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(CP.text2)
                }
            }
            .padding(22)

            Rectangle().fill(CP.divider).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.1) { f in
                    HStack(spacing: 10) {
                        Image(systemName: f.0).font(.system(size: 13)).foregroundColor(CP.icon).frame(width: 20)
                        Text(f.1).font(CPFont.body).foregroundColor(CP.text)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(CP.divider).frame(height: 1)

            VStack(spacing: 10) {
                switch license.state {
                case .needsTrial, .checking:
                    primaryButton("Start 14-day free trial", subtitle: "Every feature. No charge.") { Task { await license.startTrial() } }
                    secondaryButton(buyTitle) { Task { await license.buyFull() } }
                case .trial(let days, let ends):
                    Text("\(days) day\(days == 1 ? "" : "s") left in your free trial (ends \(ends.formatted(date: .abbreviated, time: .shortened)))")
                        .font(CPFont.emphasis).foregroundColor(CP.text)
                    primaryButton(buyTitle, subtitle: "One-time purchase — keep LiveDeck Studio forever") { Task { await license.buyFull() } }
                case .expired:
                    Text("Your 14-day free trial has ended.").font(CPFont.emphasis).foregroundColor(CP.text)
                    primaryButton(buyTitle, subtitle: "One-time purchase — your shows, songs and settings are kept") { Task { await license.buyFull() } }
                case .purchased, .unlocked:
                    Label("LiveDeck Studio is unlocked. Thank you!", systemImage: "checkmark.seal.fill").font(CPFont.emphasis).foregroundColor(DS.ok)
                }
                HStack(spacing: 14) {
                    Button("Restore purchases") { Task { await license.restore() } }.buttonStyle(.plain).foregroundColor(CP.text2)
                    Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        .foregroundColor(CP.text2)
                    if let privacy = privacyURL { Link("Privacy Policy", destination: privacy).foregroundColor(CP.text2) }
                }
                .font(CPFont.caption)
                if license.busy { ProgressView().controlSize(.small) }
                if !license.message.isEmpty {
                    Text(license.message).font(CPFont.caption).foregroundColor(DS.amber).multilineTextAlignment(.center)
                }
                Text("The free trial is a free in-app purchase that starts your 14 days. After the trial, LiveDeck Studio needs the one-time purchase to keep working. Payment is charged to your Apple ID.")
                    .font(.system(size: 10)).foregroundColor(CP.text2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .frame(width: 520)
        .background(CP.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CP.border, lineWidth: 1))
        .disabled(license.busy)
    }

    private var headline: String {
        switch license.state {
        case .trial(let d, _): return "Free trial · \(d) day\(d == 1 ? "" : "s") left"
        case .expired: return "Trial ended"
        case .purchased, .unlocked: return "Full version"
        default: return "Create · Switch · Stream"
        }
    }

    private var buyTitle: String {
        if let p = license.fullProduct { return "Buy LiveDeck Studio — \(p.displayPrice)" }
        return "Buy LiveDeck Studio"
    }

    private var privacyURL: URL? {
        (Bundle.main.infoDictionary?["LDPrivacyPolicyURL"] as? String).flatMap { URL(string: $0) }
    }

    private func primaryButton(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).opacity(0.75)
            }
            .foregroundColor(CP.primaryText)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 8).fill(CP.primaryFill))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundColor(CP.text)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(rgb: 0x26262A)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CP.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Covers the window until the trial is started or the app is bought (App Store edition only).
struct LicenseGateOverlay: View {
    @EnvironmentObject var license: LicenseManager
    var body: some View {
        if license.isLocked {
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()
                PaywallView()
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            }
            .transition(.opacity)
        }
    }
}

/// Top-bar reminder during the trial.
struct TrialBadge: View {
    @EnvironmentObject var license: LicenseManager
    var body: some View {
        if case .trial(let days, _) = license.state {
            Button { license.showPaywall = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                    Text("TRIAL · \(days) DAY\(days == 1 ? "" : "S") LEFT").font(.system(size: 10.5, weight: .semibold))
                    Text("BUY").font(.system(size: 10.5, weight: .bold)).foregroundColor(CP.primaryText)
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(CP.primaryFill))
                }
                .foregroundColor(days <= 3 ? DS.amber : DS.text2)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.bg0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(days <= 3 ? DS.amber.opacity(0.6) : DS.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Your free trial ends in \(days) day\(days == 1 ? "" : "s"). Click to buy LiveDeck Studio.")
            .sheet(isPresented: $license.showPaywall) { PaywallView(dismissible: true).environmentObject(license) }
        }
    }
}

// MARK: - Sandbox file access (security-scoped bookmarks)

/// In the App Store edition the app is sandboxed: a file the user opened can only be reopened after a restart
/// through a security-scoped bookmark. Everything the user picks or drops is remembered here, and all
/// bookmarks are reopened at launch so shows, presets and playlists keep working.
enum FileAccess {
    private static let key = "fileAccess.bookmarks"
    private static var active: [URL] = []

    static func remember(_ url: URL) { remember([url]) }

    static func remember(_ urls: [URL]) {
        guard AppEdition.isAppStore, !urls.isEmpty else { return }
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for u in urls {
            if let d = try? u.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                store[u.path] = d
            }
        }
        if store.count > 1000 {
            for k in store.keys.sorted().prefix(store.count - 1000) { store[k] = nil }
        }
        UserDefaults.standard.set(store, forKey: key)
    }

    static func restoreAll() {
        guard AppEdition.isAppStore else { return }
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        var changed = false
        for (path, data) in store {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                store[path] = nil; changed = true; continue
            }
            if url.startAccessingSecurityScopedResource() { active.append(url) }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                store[path] = nil; store[url.path] = fresh; changed = true
            }
        }
        if changed { UserDefaults.standard.set(store, forKey: key) }
    }
}
