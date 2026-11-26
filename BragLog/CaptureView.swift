import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    let focus: FocusState<Bool>.Binding
    let now: Date
    let details: () -> Void
    let edit: (Win) -> Void
    let history: () -> Void
    let counts: () -> Void
    let upgrade: () -> Void

    private var recent: [Win] { Array(model.journal.visible(pro: store.pro).prefix(3)) }

    private var thisYear: Int {
        let year = LocalDay(now).raw.prefix(4)
        return model.journal.wins.filter { $0.day.raw.hasPrefix(year) }.count
    }

    var body: some View {
        Page {
            HStack {
                Wordmark()
                Spacer()
                Text(LocalDay(now).display).font(.caption).foregroundStyle(D.muted)
                if focus.wrappedValue {
                    TextButton(key: "common.done", id: "capture.keyboard") { focus.wrappedValue = false }
                }
            }
            PageTitle(key: "capture.title")
            compose
            if !Launch.isFree, store.ready, !store.entitlement.purchasedPro { trialDisclosure }
            tally
            HStack {
                SectionName(key: "capture.recent")
                Spacer()
                if !recent.isEmpty { TextButton(key: "capture.seeAll", id: "capture.history", action: history) }
            }
            if recent.isEmpty {
                EmptyJournal(title: "capture.empty", hint: "capture.emptyHint", small: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { win in
                        WinRow(win: win) { edit(win) }
                        if win.id != recent.last?.id { Divider() }
                    }
                }
                .journalCard(padding: 11)
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionName(key: "field.action")
            TextField(L.t("field.action"), text: $model.capture.action,
                      prompt: Text(L.t("capture.placeholder")), axis: .vertical)
                .lineLimit(3...7)
                .textInputAutocapitalization(.sentences)
                .font(.body)
                .journalField()
                .focused(focus)
                .accessibilityIdentifier("capture.action")
                .disabled(model.busy)
            ViewThatFits(in: .horizontal) {
                HStack {
                    TextButton(key: "capture.details", id: "capture.details", symbol: "plus", action: details)
                    Spacer()
                    saveButton
                }
                VStack(alignment: .leading) {
                    TextButton(key: "capture.details", id: "capture.details", symbol: "plus", action: details)
                    saveButton
                }
            }
        }.journalCard()
    }

    private var saveButton: some View {
        ActionButton(key: "capture.save", id: "capture.save", primary: true) {
            let win = model.capture
            Task {
                if await model.save(win, editing: false, pro: store.hasPro) { focus.wrappedValue = false }
            }
        }
        .disabled(!model.capture.valid || model.busy)
    }

    private var trialDisclosure: some View {
        Button(action: upgrade) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(D.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.pro ? L.f("store.until", store.entitlement.trialEnd.formatted(date: .abbreviated, time: .omitted))
                         : L.t("store.expired"))
                        .font(.caption.weight(.bold))
                    Text(L.t("store.freeBrief")).font(.caption).foregroundStyle(D.muted)
                    if let price = store.price {
                        Text(L.f("store.oneTime", price)).font(.caption.weight(.semibold)).foregroundStyle(D.accent)
                    } else {
                        Text(L.t("store.priceMissing")).font(.caption).foregroundStyle(D.muted)
                    }
                }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(D.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .journalCard(padding: 10)
        .accessibilityIdentifier("capture.trial")
    }

    private var tally: some View {
        Button(action: counts) {
            HStack(spacing: 13) {
                Text(thisYear.formatted()).font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .foregroundStyle(D.amber).monospacedDigit()
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("card.year")).font(.subheadline.weight(.semibold))
                    Text(L.t("card.view")).font(.caption).foregroundStyle(D.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(D.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .journalCard(padding: 11)
        .accessibilityIdentifier("capture.count")
    }
}
