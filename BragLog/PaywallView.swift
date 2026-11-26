import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: StoreAccess

    var body: some View {
        Page {
            SheetHeader(key: "common.back") { dismiss() }
            Label(L.t("app.name"), systemImage: "bookmark.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(D.accent)
            PageTitle(key: "store.paywallTitle").accessibilityIdentifier("paywall.title")
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "book.pages").font(.system(size: 33)).foregroundStyle(D.accent)
                    .accessibilityHidden(true)
                Text(L.t("store.proIncludes")).font(.subheadline)
                if store.entitlement.purchasedPro {
                    Label(L.t("store.owned"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(D.accent).font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("paywall.owned")
                } else if store.pro {
                    Text(L.f("store.until", store.entitlement.trialEnd.formatted(date: .long, time: .omitted)))
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(L.t("store.expired")).font(.subheadline.weight(.semibold))
                }
                Text(L.t("store.trialRules")).font(.footnote).foregroundStyle(D.muted)
                Text(L.t("store.freeBrief")).font(.footnote).foregroundStyle(D.muted)
            }.journalCard()
            buttons
            if let message = store.message {
                Text(L.t(message)).font(.footnote).foregroundStyle(D.muted).accessibilityIdentifier("paywall.message")
            }
        }
        .task { if store.items.isEmpty { await store.loadProducts() } }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let price = store.price, !store.entitlement.purchasedPro {
                ActionButton(key: "store.upgrade", id: "paywall.buy", primary: true, wide: true,
                             display: L.f("store.oneTime", price)) {
                    Task { await store.purchase(StoreAccess.proID) }
                }.disabled(store.busy)
            } else if !store.entitlement.purchasedPro {
                Text(L.t("store.priceMissing")).font(.footnote).foregroundStyle(D.muted)
                TextButton(key: "common.retry", id: "paywall.reload") {
                    Task { await store.foreground() }
                }
            }
            if store.pro && store.entitlement.trialClaimedAt == nil && !store.entitlement.purchasedPro {
                ActionButton(key: "store.claim", id: "paywall.trial", wide: true) {
                    Task { await store.purchase(StoreAccess.trialID) }
                }
                .disabled(store.busy || store.price == nil ||
                          !(Launch.testing || store.items.contains { $0.id == StoreAccess.trialID }))
            }
            TextButton(key: "store.restore", id: "paywall.restore", symbol: "arrow.clockwise") {
                Task { await store.restore() }
            }.disabled(store.busy || !store.ready)
            Text(L.t("store.noRenewal")).font(.caption).foregroundStyle(D.muted)
        }
    }
}
