import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    @State private var filePicker = false
    @State private var roles = false
    @State private var preview: BackupPreview?
    @State private var template: ExportTemplate?
    @State private var working = false
    @State private var templateStatus: String?
    let share: (ShareRequest) -> Void
    let upgrade: () -> Void

    var body: some View {
        Page {
            Wordmark()
            PageTitle(key: "tab.settings")
            reminderCard
            dataCard
            if !Launch.isFree { premiumCard }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): Task { await previewCSV { try TransferFiles.read(url) } }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.storageError = "error.csv" }
            }
        }
        .sheet(isPresented: $roles) { RolesView() }
        .sheet(item: $preview) { item in
            BackupImportView(preview: item.preview)
        }
    }

    private var settings: Reminder { model.reminderSetting }

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { value in
                var next = settings
                next.enabled = value
                model.setReminder(next)
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionName(key: "reminder.title")
                    Text(L.t("reminder.body")).font(.footnote).foregroundStyle(D.muted)
                }
            }
            .accessibilityIdentifier("reminder.toggle")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(weekdays, id: \.self) { day in
                        Chip(title: Calendar.journal.shortWeekdaySymbols[day - 1],
                             id: "reminder.day." + String(day), selected: settings.weekday == day) {
                            var next = settings
                            next.weekday = day
                            model.setReminder(next)
                        }
                        .accessibilityLabel(Calendar.journal.weekdaySymbols[day - 1])
                    }
                }
            }
            DatePicker(L.t("reminder.time"), selection: Binding(get: { time }, set: { date in
                let parts = Calendar.journal.dateComponents([.hour, .minute], from: date)
                var next = settings
                next.hour = parts.hour ?? 17
                next.minute = parts.minute ?? 0
                model.setReminder(next)
            }), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("reminder.time")
            if model.reminderDenied {
                Text(L.t("reminder.denied")).font(.footnote).foregroundStyle(D.muted)
                    .accessibilityIdentifier("reminder.denied")
                TextButton(key: "reminder.system", id: "reminder.system") {
                    if let url = URL(string: UIApplication.openSettingsURLString), !Launch.testing {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }.journalCard()
    }

    private var weekdays: [Int] {
        let first = Calendar.journal.firstWeekday
        return (0...6).map { (first - 1 + $0) % 7 + 1 }
    }

    private var time: Date {
        Calendar.journal.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date()
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionName(key: "settings.data")
            TextButton(key: "role.manage", id: "settings.roles", symbol: "person.crop.rectangle") { roles = true }
            Divider()
            TextButton(key: "settings.csvOut", id: "settings.csvOut", symbol: store.pro ? "square.and.arrow.up" : "lock") {
                if store.hasPro { Task { await shareCSV() } }
                else { upgrade() }
            }.disabled(working)
            Text(L.t("csv.textOnly")).font(.caption).foregroundStyle(D.muted)
            TextButton(key: "settings.csvIn", id: "settings.csvIn", symbol: store.pro ? "square.and.arrow.down" : "lock") {
                if !store.hasPro { upgrade() }
                else if Launch.testing, let fixture = ProcessInfo.processInfo.environment["BRAG_CSV"] {
                    Task { await previewCSV { fixture } }
                } else { filePicker = true }
            }.disabled(working)
            Divider()
            templateSection
        }.journalCard()
    }

    @ViewBuilder private var templateSection: some View {
        if Launch.testing, let code = ProcessInfo.processInfo.environment["BRAG_TEMPLATE"] {
            TextButton(key: "settings.paste", id: "settings.paste.test") { decode(code) }
        } else {
            PasteButton(payloadType: String.self) { items in
                if let code = items.first { decode(code) }
            }
            .labelStyle(.titleAndIcon)
            .tint(D.accent)
            .frame(minHeight: 44)
            .accessibilityLabel(L.t("settings.paste"))
            .accessibilityIdentifier("settings.paste")
        }
        if let template {
            VStack(alignment: .leading, spacing: 5) {
                Text(template.format.title).font(.subheadline.weight(.semibold))
                if template.includeProject || template.includeDate {
                    Text(template.fields.filter { $0 == .project ? template.includeProject : template.includeDate }
                        .map(\.title).joined(separator: " · "))
                        .font(.caption).foregroundStyle(D.muted)
                }
                if !store.pro && template.format != .list {
                    Text(L.t("template.savedForPro")).font(.caption).foregroundStyle(D.muted)
                }
                ActionButton(key: "template.import", id: "settings.templateImport", primary: true) {
                    Task { await saveTemplate(template) }
                }.disabled(model.busy)
            }.padding(.vertical, 6)
        }
        if let templateStatus {
            Text(L.t(templateStatus)).font(.footnote).foregroundStyle(D.muted)
                .accessibilityIdentifier("settings.templateStatus")
        }
        if !model.journal.templates.isEmpty {
            SectionName(key: "template.saved")
            ForEach(Array(model.journal.templates.enumerated()), id: \.element) { index, item in
                TextButton(key: "template.use", id: "settings.templateUse." + String(index), symbol: "text.document") {
                    model.exportTemplate = item
                    model.show("template.applied")
                }
                .accessibilityLabel(item.format.title)
                Text(item.format.title).font(.caption).foregroundStyle(D.muted)
            }
        }
    }

    private var premiumCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionName(key: "store.title")
            TextButton(key: "store.upgrade", id: "settings.upgrade", symbol: "sparkles", action: upgrade)
            TextButton(key: "store.restore", id: "settings.restore", symbol: "arrow.clockwise") {
                Task { await store.restore() }
            }.disabled(store.busy)
            if let message = store.message {
                Text(L.t(message)).font(.footnote).foregroundStyle(D.muted)
            }
        }.journalCard()
    }

    private func decode(_ code: String) {
        do {
            template = try TemplateCode.decode(code)
            templateStatus = nil
        } catch {
            template = nil
            templateStatus = "error.template"
        }
    }

    private func saveTemplate(_ value: ExportTemplate) async {
        if model.journal.templates.contains(value) {
            templateStatus = "template.duplicate"
            template = nil
            return
        }
        let saved = await model.change {
            if !$0.templates.contains(value) { $0.templates.append(value) }
            $0.template = value
        }
        if saved {
            model.exportTemplate = value
            template = nil
            templateStatus = "template.imported"
        }
    }

    private func shareCSV() async {
        guard !working, store.hasPro else { return }
        working = true
        defer { working = false }
        let snapshot = model.journal
        do {
            let url = try await Task.detached {
                let text = try JournalCSV.encode(snapshot)
                return try TransferFiles.temporary(Data(text.utf8), name: "BragLog.csv")
            }.value
            guard store.hasPro else {
                Task.detached { TransferFiles.remove(url) }
                return
            }
            share(ShareRequest(items: [url], file: url))
        } catch { model.storageError = "error.csv" }
    }

    private func previewCSV(_ read: @escaping @Sendable () throws -> String) async {
        guard !working, store.hasPro else { return }
        working = true
        defer { working = false }
        let snapshot = model.journal
        do {
            let value = try await Task.detached {
                try JournalCSV.preview(read(), existing: snapshot)
            }.value
            preview = BackupPreview(preview: value)
        } catch { model.storageError = "error.csv" }
    }
}

private struct BackupPreview: Identifiable {
    let id = UUID()
    let preview: CSVPreview
}

private struct BackupImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    @State private var keep = false
    let preview: CSVPreview

    var body: some View {
        Page {
            SheetHeader(key: "common.back") { dismiss() }
            PageTitle(key: "csv.preview")
            VStack(alignment: .leading, spacing: 9) {
                Text(L.f("csv.summary", preview.validCount, preview.duplicates, preview.badLines.count))
                    .font(.subheadline.weight(.semibold))
                if !preview.backupRoles.isEmpty {
                    Text(L.f("csv.roles", preview.backupRoles.count)).font(.caption).foregroundStyle(D.muted)
                }
                if !preview.badLines.isEmpty {
                    Text(L.f("csv.badLines", preview.badLines.map(String.init).joined(separator: ", ")))
                        .font(.caption).foregroundStyle(D.muted)
                }
                Toggle(L.t("csv.keep"), isOn: $keep)
                    .accessibilityIdentifier("csv.keep")
            }.journalCard()
            VStack(alignment: .leading, spacing: 6) {
                SectionName(key: "csv.mapping")
                ForEach(preview.mapping) { item in
                    Text(item.header + " → " + item.column.title).font(.footnote)
                }
            }.journalCard()
            ActionButton(key: "common.import", id: "csv.apply", primary: true, wide: true) {
                let value = keep
                Task {
                    guard store.hasPro else { return }
                    if await model.change({ journal in
                        _ = preview.apply(to: &journal, keepDuplicates: value)
                    }) {
                        if !model.capture.valid { model.capture.roleID = model.journal.currentRole }
                        model.show("csv.imported")
                        dismiss()
                    }
                }
            }
            .disabled(!store.pro || model.busy ||
                      (preview.validCount == 0 && preview.backupRoles.isEmpty
                         && (!keep || !preview.items.contains { $0.duplicate && !$0.explicitID })))
            if let error = model.storageError {
                Text(L.t(error)).font(.footnote)
            }
        }
    }
}
