import SwiftUI
import UIKit

struct CountCardView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var year = Calendar.journal.component(.year, from: Date())
    @State private var quarter = (Calendar.journal.component(.month, from: Date()) - 1) / 3 + 1
    @State private var quarterly = false
    @State private var level: Int?
    @State private var art: UIImage?
    @State private var renderedJob: CardJob?
    @State private var request: ShareRequest?
    @State private var file: URL?
    @State private var sharing = false
    @State private var warning: String?

    init(initialLevel: Int?) { _level = State(initialValue: initialLevel) }

    private var period: SharePeriod {
        if let level { return .milestone(level) }
        return quarterly ? .quarter(year, quarter) : .year(year)
    }
    private var counts: Counts { period.counts(in: model.journal) }
    private var job: CardJob { CardJob(period: period, counts: counts) }

    private var years: [Int] {
        let current = Calendar.journal.component(.year, from: Date())
        return Set(model.journal.wins.compactMap { Int($0.day.raw.prefix(4)) } + [current]).sorted(by: >)
    }

    var body: some View {
        Page {
            SheetHeader(key: "tab.capture") { dismiss() }
            PageTitle(key: "card.title")
            selectors
            preview
            Text(L.t("card.privacy")).font(.footnote).foregroundStyle(D.muted)
            milestones
            if let warning {
                Text(L.t(warning)).font(.footnote)
                    .accessibilityIdentifier(warning == "share.requested" ? "share.requested" : "card.message")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task(id: job) {
            let item = job
            let storeID = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
            let image = await Task.detached(priority: .userInitiated) {
                ShareArt.render(counts: item.counts, period: item.period, storeID: storeID)
            }.value
            guard !Task.isCancelled, job == item else { return }
            art = image
            renderedJob = item
        }
        .sheet(item: $request, onDismiss: clean) { ActivitySheet(request: $0) }
        .interactiveDismissDisabled(sharing)
    }

    private var selectors: some View {
        HStack(spacing: 7) {
            Chip(title: L.t("card.yearShort"), id: "card.year", selected: level == nil && !quarterly) {
                quarterly = false
                level = nil
            }
            Chip(title: L.t("period.quarter"), id: "card.quarter", selected: level == nil && quarterly) {
                quarterly = true
                level = nil
            }
            Menu {
                ForEach(years, id: \.self) { value in
                    Button(String(value)) {
                        year = value
                        level = nil
                    }
                }
            } label: {
                MenuLabel(title: String(year))
            }.accessibilityIdentifier("card.yearMenu")
            if quarterly && level == nil {
                Menu {
                    ForEach(1...4, id: \.self) { value in
                        Button(L.f("card.shortQuarter", value)) { quarter = value }
                    }
                } label: {
                    MenuLabel(title: L.f("card.shortQuarter", quarter))
                }.accessibilityIdentifier("card.quarterMenu")
            }
        }
    }

    private var artLabel: String {
        var parts: [String] = []
        for category in PublicCategory.allCases {
            let n: Int = counts.buckets[category, default: 0]
            if n > 0 { parts.append(category.title + " " + n.formatted()) }
        }
        let head: String = period.caption + " · " + L.f("history.count", counts.total)
        return head + " · " + parts.joined(separator: ", ")
    }

    @ViewBuilder private var preview: some View {
        if let art, renderedJob == job {
            Image(uiImage: art).resizable().scaledToFit()
                .frame(maxHeight: 445)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .shadow(color: D.ink.opacity(0.12), radius: 10, y: 5)
                .accessibilityLabel(artLabel)
                .accessibilityIdentifier("card.art")
            if counts.total == 0 {
                Text(L.t("card.empty")).font(.footnote).foregroundStyle(D.muted)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityLabel(L.t("common.loading"))
        }
    }

    private var milestones: some View {
        HStack {
            SectionName(key: "card.milestones")
            Spacer()
            ForEach(Progress.levels, id: \.self) { value in
                Chip(title: value.formatted(), id: "card.milestone." + String(value), selected: level == value) {
                    level = value
                }
                .disabled(!model.journal.progress.milestones.contains(value))
                .opacity(model.journal.progress.milestones.contains(value) ? 1 : 0.43)
            }
        }.journalCard(padding: 9)
    }

    private var footer: some View {
        ActionButton(key: "card.share", id: "card.share", symbol: "square.and.arrow.up", primary: true, wide: true) {
            Task { await share() }
        }
        .disabled(counts.total == 0 || renderedJob != job || sharing)
        .padding(.horizontal, D.inset)
        .padding(.vertical, 8)
        .background(D.paper)
    }

    private func share() async {
        guard let art, renderedJob == job, !sharing, counts.total > 0 else { return }
        sharing = true
        defer { sharing = false }
        do {
            let url = try await Task.detached {
                guard let data = art.pngData() else { throw JournalFailure.file }
                return try TransferFiles.temporary(data, name: "BragLog.png")
            }.value
            if Launch.testing {
                warning = "share.requested"
                Task.detached { TransferFiles.remove(url) }
            } else {
                file = url
                request = ShareRequest(items: [url, ShareArt.hashtags], file: url)
            }
        } catch { warning = "error.share" }
    }

    private func clean() {
        let value = file
        file = nil
        Task.detached { TransferFiles.remove(value) }
    }

    private struct CardJob: Equatable {
        let period: SharePeriod
        let counts: Counts
    }
}
