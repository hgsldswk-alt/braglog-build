import SwiftUI
import UIKit

struct ExportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    @State private var full = false
    @State private var options = false
    let share: (ShareRequest) -> Void
    let upgrade: () -> Void

    private var candidates: [Win] { model.filter.apply(model.journal.visible(pro: store.pro)) }
    private var selected: [Win] {
        guard let ids = model.exportSelection else { return candidates }
        return candidates.filter { ids.contains($0.id) }
    }
    private var template: ExportTemplate { store.pro ? model.exportTemplate : ExportTemplate(format: .list) }
    private var text: String { template.text(selected) }
    private var canExport: Bool { !selected.isEmpty }

    var body: some View {
        if full { fullPreview }
        else { workspace }
    }

    private var workspace: some View {
        Page {
            Wordmark()
            PageTitle(key: "tab.export")
            selection
            formats
            preview
            TextButton(key: "export.copyCode", id: "export.code", symbol: "link") { copyCode() }
            if !store.pro {
                TextButton(key: "export.upgrade", id: "export.upgrade", symbol: "lock", action: upgrade)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RangeLabel.title(model.filter)).font(.subheadline.weight(.semibold))
                    if let id = model.filter.roleID, let role = model.journal.roles.first(where: { $0.id == id }) {
                        Text(role.label).font(.caption).foregroundStyle(D.muted)
                    }
                }
                Spacer(minLength: 5)
                if !candidates.isEmpty {
                    TextButton(key: selected.count == candidates.count ? "export.clearAll" : "export.selectAll",
                               id: "export.selectAll") {
                        model.exportSelection = selected.count == candidates.count ? [] : nil
                    }
                }
            }
            if candidates.isEmpty {
                EmptyJournal(title: "export.empty", hint: "export.emptyHint", icon: "text.document", small: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates) { win in
                            selectRow(win)
                            if win.id != candidates.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(166, CGFloat(candidates.count) * 50))
                .accessibilityLabel(L.t("export.choose"))
            }
        }.journalCard(padding: 11)
    }

    private func selectRow(_ win: Win) -> some View {
        let on = model.exportSelection?.contains(win.id) ?? true
        return Button {
            var ids = model.exportSelection ?? Set(candidates.map(\.id))
            if on { ids.remove(win.id) } else { ids.insert(win.id) }
            model.exportSelection = ids
        } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(D.accent)
                Text(win.action).font(.subheadline).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export.win." + win.id.uuidString)
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionName(key: "export.format")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.pro ? ExportFormat.allCases : [.list]) { format in
                        Chip(title: format.title, id: "export.format." + format.rawValue,
                             selected: format == template.format) {
                            model.exportTemplate.format = format
                        }
                    }
                }
            }
            if store.pro, template.format == .review {
                TextButton(key: "export.fields", id: "export.fields", symbol: options ? "chevron.up" : "slider.horizontal.3") {
                    options.toggle()
                }
                if options {
                    Toggle(L.t("export.includeProject"), isOn: $model.exportTemplate.includeProject)
                        .accessibilityIdentifier("export.includeProject")
                    Toggle(L.t("export.includeDate"), isOn: $model.exportTemplate.includeDate)
                        .accessibilityIdentifier("export.includeDate")
                    if template.includeProject && template.includeDate {
                        TextButton(key: "export.swap", id: "export.swap", symbol: "arrow.up.arrow.down") {
                            model.exportTemplate.fields.reverse()
                        }
                        Text(template.fields.map(\.title).joined(separator: " · "))
                            .font(.caption).foregroundStyle(D.muted)
                    }
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L.f("export.selected", selected.count)).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("export.selected")
                Spacer()
                TextButton(key: "export.full", id: "export.preview") { full = true }.disabled(!canExport)
            }
            Text(canExport ? text : L.t("export.emptyPreview"))
                .font(.footnote)
                .lineLimit(4)
                .foregroundStyle(D.muted)
                .accessibilityIdentifier("export.previewText")
            starNote
        }.journalCard(padding: 11)
    }

    private var fullPreview: some View {
        Page {
            SheetHeader(key: "tab.export") { full = false }
            PageTitle(key: "export.fullTitle")
            Text(L.f("export.selected", selected.count) + " · " + template.format.title)
                .font(.subheadline).foregroundStyle(D.muted)
            Text(text).font(.body).textSelection(.enabled)
                .journalCard()
                .accessibilityIdentifier("export.fullText")
            starNote
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
    }

    @ViewBuilder private var starNote: some View {
        let count = template.missingSTAR(selected)
        if count > 0 {
            Text(L.f("export.starMissing", count)).font(.caption).foregroundStyle(D.muted)
        }
    }

    private var actions: some View {
        HStack {
            ActionButton(key: "export.copy", id: "export.copy", symbol: "doc.on.doc", primary: true, wide: true) {
                UIPasteboard.general.string = text
                model.show("status.copied")
            }
            ActionButton(key: "export.share", id: "export.share", symbol: "square.and.arrow.up", wide: true) {
                share(ShareRequest(items: [text]))
            }
        }
        .disabled(!canExport)
        .padding(.horizontal, D.inset)
        .padding(.vertical, 7)
        .background(D.paper)
    }

    private func copyCode() {
        do {
            UIPasteboard.general.string = try TemplateCode.encode(template)
            model.show("status.codeCopied")
        } catch { model.storageError = "error.template" }
    }
}
