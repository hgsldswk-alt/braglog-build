import Combine
import Foundation
import Security
import StoreKit
import WidgetKit

private actor AccessKeychain {
    private let identity: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.braglog.entitlement",
        kSecAttrAccount as String: "owner"
    ]

    func load(now: Date, free: Bool) throws -> Entitlement {
        var query: [String: Any] = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var entitlement: Entitlement
        if status == errSecItemNotFound {
            entitlement = Entitlement(firstOpen: now, proStartedAt: free ? nil : now)
            try write(entitlement)
        } else {
            guard status == errSecSuccess, let data = result as? Data else { throw JournalFailure.unavailable }
            entitlement = try JSONDecoder().decode(Entitlement.self, from: data)
            if !free && entitlement.proStartedAt == nil {
                entitlement.proStartedAt = now
                try write(entitlement)
            }
        }
        return entitlement
    }

    func write(_ entitlement: Entitlement) throws {
        let value: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(entitlement)]
        let status = SecItemUpdate(identity as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw JournalFailure.unavailable }
        var item: [String: Any] = identity
        item.merge(value) { _, new in new }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw JournalFailure.unavailable }
    }
}

@MainActor
final class StoreAccess: ObservableObject {
    static let proID = "com.hgsldswk.braglog.pro"
    static let trialID = "com.hgsldswk.braglog.trial"
    @Published private(set) var entitlement = Entitlement(firstOpen: .distantPast)
    @Published private(set) var ready = false
    @Published private(set) var pro = false
    @Published private(set) var items: [Product] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private let keychain = AccessKeychain()
    private var listener: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var starting = false
    private var refreshInProgress = false
    private var refreshRequested = false
    private var restoreRequested = false
    private var verifiedUpdates: [StoreKit.Transaction] = []

    var price: String? { Launch.testing ? "$3.99" : items.first(where: { $0.id == Self.proID })?.displayPrice }
    var hasPro: Bool { Launch.isFree || (ready && entitlement.hasPro(at: Date())) }

    func start() async {
        guard !ready, !starting else { return }
        starting = true
        defer { starting = false }
        if Launch.testing {
            let now = Date()
            let days: TimeInterval = Launch.testFlag("-expired") ? 31 : 0
            entitlement = Entitlement(firstOpen: now.addingTimeInterval(-days * 86_400),
                                      purchasedPro: Launch.testFlag("-owned"))
            ready = true
            publish()
            return
        }
        do {
            entitlement = try await keychain.load(now: Date(), free: Launch.isFree)
            ready = true
            publish()
        } catch {
            message = "store.accessFailed"
            return
        }
        guard !Launch.isFree else { return }
        listener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                if case .verified(let transaction) = update,
                   [Self.proID, Self.trialID].contains(transaction.productID) {
                    await self.reconcile(verified: transaction)
                    await transaction.finish()
                }
            }
        }
        Task { await reconcile() }
        Task { await loadProducts() }
    }

    func foreground() async {
        if !ready { await start() }
        guard ready else { return }
        publish()
        if !Launch.testing && !Launch.isFree {
            await reconcile()
            if items.count < 2 { await loadProducts() }
        }
    }

    func loadProducts() async {
        guard !Launch.isFree, !Launch.testing else { return }
        do { items = try await Product.products(for: [Self.proID, Self.trialID]) }
        catch { return }
    }

    func purchase(_ id: String) async {
        guard !busy, ready, !Launch.isFree else { return }
        busy = true
        defer { busy = false }
        if Launch.testing {
            if id == Self.proID { entitlement.purchasedPro = true }
            else if hasPro {
                entitlement.reconcile(pro: entitlement.purchasedPro, trialReceipt: Date())
            }
            publish()
            return
        }
        if id == Self.trialID && (!hasPro || entitlement.trialClaimedAt != nil || price == nil) { return }
        guard let product = items.first(where: { $0.id == id }) else {
            await loadProducts()
            message = "store.unavailable"
            return
        }
        do {
            var options: Set<Product.PurchaseOption> = []
            if id == Self.trialID, let token = TrialReceipt.token(start: entitlement.trialStart) {
                options.insert(.appAccountToken(token))
            }
            switch try await product.purchase(options: options) {
            case .success(.verified(let transaction)):
                await reconcile(verified: transaction)
                await transaction.finish()
            case .success(.unverified): message = "store.unverified"
            case .pending: message = "store.pending"
            case .userCancelled: break
            @unknown default: message = "store.unavailable"
            }
        } catch { message = "store.unavailable" }
    }

    func restore() async {
        guard !busy, ready, !Launch.isFree else { return }
        busy = true
        defer { busy = false }
        if Launch.testing {
            if Launch.testFlag("-restore-owned") { entitlement.purchasedPro = true }
            publish()
            message = entitlement.purchasedPro ? "store.restored" : "store.noPurchase"
            return
        }
        do {
            try await AppStore.sync()
            await reconcile(confirmedRestore: true)
            message = entitlement.purchasedPro || entitlement.trialClaimedAt != nil
                ? "store.restored" : "store.noPurchase"
        } catch { message = "store.unavailable" }
    }

    private func reconcile(verified: StoreKit.Transaction? = nil, confirmedRestore: Bool = false) async {
        if let verified { verifiedUpdates.append(verified) }
        restoreRequested = restoreRequested || confirmedRestore
        if refreshInProgress {
            refreshRequested = true
            while refreshInProgress && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        refreshInProgress = true
        defer { refreshInProgress = false }
        repeat {
            refreshRequested = false
            let updates = verifiedUpdates
            verifiedUpdates.removeAll()
            let confirmOwnership = restoreRequested
            restoreRequested = false
            var owned = false
            var receipt: Date?
            for await result in StoreKit.Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    guard transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
                    if transaction.productID == Self.proID { owned = true }
                    if transaction.productID == Self.trialID {
                        let start = Self.trialBeginning(transaction)
                        receipt = min(receipt ?? start, start)
                    }
                case .unverified: break
                }
            }
            for transaction in updates where transaction.revocationDate == nil && !transaction.isUpgraded {
                if transaction.productID == Self.proID { owned = true }
                if transaction.productID == Self.trialID {
                    let start = Self.trialBeginning(transaction)
                    receipt = min(receipt ?? start, start)
                }
            }
            var revoked = updates.contains { $0.productID == Self.proID && $0.revocationDate != nil }
            if !owned, case .verified(let latest)? = await StoreKit.Transaction.latest(for: Self.proID) {
                revoked = revoked || latest.revocationDate != nil
            }
            var next = entitlement
            next.reconcile(pro: owned || (next.purchasedPro && !revoked && !confirmOwnership), trialReceipt: receipt)
            if next != entitlement {
                do {
                    try await keychain.write(next)
                    entitlement = next
                } catch { message = "store.accessFailed" }
            }
            publish()
        } while refreshRequested
    }

    private static func trialBeginning(_ transaction: StoreKit.Transaction) -> Date {
        TrialReceipt.start(token: transaction.appAccountToken, purchaseDate: transaction.originalPurchaseDate)
    }

    private func publish() {
        pro = hasPro
        expiry?.cancel()
        let end = (Launch.isFree || entitlement.purchasedPro || !ready) ? nil : entitlement.trialEnd
        if !Launch.testing {
            let access = WidgetAccess(unlocked: pro, expires: end)
            if let data = try? JSONEncoder().encode(access) {
                UserDefaults(suiteName: WidgetAccess.group)?.set(data, forKey: WidgetAccess.key)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        if let end, end > Date() {
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
                catch { return }
                self?.publish()
            }
        }
    }
}
