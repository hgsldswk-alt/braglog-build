import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    @State private var custom = false
    @FocusState private var searching: Bool
    let edit: (Win) -> Void
    let export: () -> Void
    let upgrade: () -> Void

    private var available: [Win] { model.journal.visible(pro: store.pro) }
    private var results: [Win] { model.filter.apply(available) }

    var body: some View {
        Page {
            HStack {
                Wordmark()
                Spacer()
                TextButton(key: "tab.export", id: "history.export", action: export)
            }
            PageTitle(key: "tab.history")
            search
            periods
            filters
            resultList
            if !store.pro, model.journal.wins.count > available.count {
                TextButton(key: "history.unlock", id: "history.upgrade", symbol: "lock", action: upgrade)
            }
        }
        .sheet(isPresented: $custom) {
            DateRangeSheet(start: model.filter.start, end: model.filter.end) { start, end in
                model.filter.start = start
                model.filter.end = end
                model.filter.period = .custom
                model.filter.unrestricted = false
            }.presentationDetents([.medium, .large])
        }
    }

    private var search: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(D.muted)
            TextField(L.t("history.search"), text: $model.filter.query)
                .focused($searching)
                .submitLabel(.search)
                .onSubmit { searching = false }
                .accessibilityIdentifier("history.search")
            if !model.filter.query.isEmpty {
                Button { model.filter.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(D.muted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("history.clearSearch"))
                .accessibilityIdentifier("history.clearSearch")
            }
        }.journalField()
    }

    private var periods: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Period.allCases) { period in
                    Chip(title: period.title, id: "history.period." + period.rawValue,
                         selected: !model.filter.unrestricted && model.filter.period == period) {
                        searching = false
                        if period == .custom { custom = true }
                        else {
                            model.filter.unrestricted = false
                            model.filter.period = period
                        }
                    }
                }
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Menu {
                    Button(L.t("history.allRoles")) { model.filter.roleID = nil }
                    ForEach(model.journal.roles) { role in
                        Button(role.label) { model.filter.roleID = role.id }
                    }
                } label: {
                    MenuLabel(title: model.journal.roles.first { $0.id == model.filter.roleID }?.label
                              ?? L.t("history.allRoles"))
                }
                .accessibilityIdentifier("history.role")
                Menu {
                    Button(L.t("history.allProjects")) { model.filter.project = nil }
                    ForEach(Set(available.map(\.project)).filter { !$0.isEmpty }.sorted(), id: \.self) { project in
                        Button(project) { model.filter.project = project }
                    }
                } label: {
                    MenuLabel(title: model.filter.project ?? L.t("history.allProjects"))
                }
                .accessibilityIdentifier("history.project")
                Menu {
                    Button(L.t("history.allTags")) { model.filter.tag = nil }
                    ForEach(Set(available.flatMap(\.tags)).sorted(), id: \.self) { tag in
                        Button(tag) { model.filter.tag = tag }
                    }
                } label: {
                    MenuLabel(title: model.filter.tag ?? L.t("field.tags"))
                }
                .accessibilityIdentifier("history.tags")
            }
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(RangeLabel.title(model.filter)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(L.f("history.count", results.count)).font(.caption).foregroundStyle(D.muted)
                    .accessibilityIdentifier("history.count")
            }
            if results.isEmpty {
                EmptyJournal(title: "history.empty", hint: "history.emptyHint", icon: "magnifyingglass")
                TextButton(key: "history.clear", id: "history.clear") {
                    searching = false
                    model.filter = WinFilter(unrestricted: true)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(results) { win in
                        WinRow(win: win) { edit(win) }
                        if win.id != results.last?.id { Divider() }
                    }
                }.journalCard(padding: 10)
            }
        }
    }
}

enum RangeLabel {
    static func title(_ filter: WinFilter) -> String {
        guard let range = filter.span() else { return L.t("history.allDates") }
        let format = DateIntervalFormatter()
        format.dateStyle = filter.period == .custom ? .medium : .short
        format.timeStyle = .none
        return format.string(from: range.lowerBound.date(), to: range.upperBound.date())
    }
}

private struct DateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var start: LocalDay
    @State var end: LocalDay
    let apply: (LocalDay, LocalDay) -> Void

    var body: some View {
        Page {
            SheetHeader(key: "common.back") { dismiss() }
            PageTitle(key: "period.custom")
            VStack(alignment: .leading, spacing: 12) {
                DatePicker(L.t("field.start"), selection: day($start), displayedComponents: .date)
                    .accessibilityIdentifier("range.start")
                DatePicker(L.t("field.end"), selection: day($end), displayedComponents: .date)
                    .accessibilityIdentifier("range.end")
            }.journalCard()
            ActionButton(key: "common.apply", id: "range.apply", primary: true, wide: true) {
                apply(min(start, end), max(start, end))
                dismiss()
            }
        }
    }

    private func day(_ value: Binding<LocalDay>) -> Binding<Date> {
        Binding(get: { value.wrappedValue.date() }, set: { value.wrappedValue = LocalDay($0) })
    }
}
