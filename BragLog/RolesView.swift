import SwiftUI

struct RolesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var form: Role?
    @State private var creating = false

    private var active: [Role] { model.journal.roles.filter { !$0.archived } }
    private var archived: [Role] { model.journal.roles.filter(\.archived) }

    var body: some View {
        Page {
            SheetHeader(key: "common.back") { dismiss() }
            PageTitle(key: "role.manage")
            ActionButton(key: "role.add", id: "role.add", symbol: "plus", primary: true, wide: true) {
                creating = true
                form = Role()
            }
            if active.isEmpty {
                EmptyJournal(title: "role.empty", hint: "role.emptyHint", icon: "person.crop.rectangle")
            }
            ForEach(active) { role in row(role) }
            if !archived.isEmpty {
                SectionName(key: "role.archived")
                ForEach(archived) { role in row(role) }
            }
        }
        .sheet(item: $form) { item in
            RoleEditor(role: item, creating: creating)
        }
    }

    private func row(_ role: Role) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                creating = false
                form = role
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.label).font(.headline)
                        if let start = role.start {
                            Text(start.display + (role.end.map { " – " + $0.display } ?? ""))
                                .font(.caption).foregroundStyle(D.muted)
                        } else if let end = role.end {
                            Text(L.f("role.ended", end.display)).font(.caption).foregroundStyle(D.muted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(D.accent)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("role.row." + role.id.uuidString)
            if model.journal.currentRole == role.id {
                Label(L.t("role.current"), systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(D.accent)
            } else {
                TextButton(key: "role.makeCurrent", id: "role.current." + role.id.uuidString) {
                    Task {
                        if await model.change({ $0.makeCurrent(role.id) }),
                           model.capture.action.trimmed.isEmpty {
                            model.capture.roleID = role.id
                        }
                    }
                }.disabled(model.busy)
            }
        }.journalCard()
    }
}

private struct RoleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var role: Role
    let creating: Bool
    @State private var makeCurrent = true
    @State private var endPrevious = true

    var body: some View {
        Page {
            SheetHeader(key: "common.back") { dismiss() }
            PageTitle(key: creating ? "role.add" : "role.edit")
            form
            ActionButton(key: "common.save", id: "role.save", primary: true, wide: true) {
                Task { await save() }
            }.disabled(!role.valid || model.busy)
            if !creating {
                TextButton(key: role.archived ? "role.unarchive" : "role.archive", id: "role.archive",
                           symbol: "archivebox") {
                    Task { await archive() }
                }.disabled(model.busy)
            }
            if let error = model.storageError { Text(L.t(error)).font(.footnote) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionName(key: "role.name")
            TextField(L.t("role.name"), text: $role.title).journalField().accessibilityIdentifier("role.name")
            SectionName(key: "role.org")
            TextField(L.t("role.org"), text: $role.organization).journalField().accessibilityIdentifier("role.org")
            optionalDate("field.start", id: "role.start", day: $role.start)
            optionalDate("field.end", id: "role.end", day: $role.end)
            if creating {
                Toggle(L.t("role.makeCurrent"), isOn: $makeCurrent).accessibilityIdentifier("role.makeCurrent")
                if makeCurrent && model.journal.currentRole != nil {
                    Toggle(L.t("role.endPrevious"), isOn: $endPrevious).accessibilityIdentifier("role.endPrevious")
                }
            }
            if let start = role.start, let end = role.end, end < start {
                Text(L.t("role.invalidRange")).font(.footnote).foregroundStyle(D.muted)
            }
        }.journalCard()
    }

    private func optionalDate(_ label: String, id: String, day: Binding<LocalDay?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L.t(label), isOn: Binding(get: { day.wrappedValue != nil }, set: { value in
                day.wrappedValue = value ? LocalDay() : nil
            })).accessibilityIdentifier(id + ".enabled")
            if day.wrappedValue != nil {
                DatePicker(L.t(label), selection: Binding(get: { day.wrappedValue?.date() ?? Date() },
                    set: { day.wrappedValue = LocalDay($0) }), displayedComponents: .date)
                    .labelsHidden().accessibilityLabel(L.t(label)).accessibilityIdentifier(id)
            }
        }
    }

    private func save() async {
        var value = role
        value.title = value.title.trimmed
        value.organization = value.organization.trimmed
        let updated = value
        let choose = creating && makeCurrent
        let end = endPrevious
        let today = LocalDay()
        if await model.change({ journal in
            if let index = journal.roles.firstIndex(where: { $0.id == updated.id }) {
                journal.roles[index] = updated
            } else {
                journal.roles.append(updated)
            }
            if choose {
                if end, let previous = journal.roles.firstIndex(where: { $0.id == journal.currentRole }),
                   journal.roles[previous].end == nil {
                    let date = updated.start ?? today
                    journal.roles[previous].end = max(journal.roles[previous].start ?? date, date)
                }
                journal.makeCurrent(updated.id)
            }
        }) {
            if choose && model.capture.action.trimmed.isEmpty { model.capture.roleID = updated.id }
            dismiss()
        }
    }

    private func archive() async {
        let value = role
        if await model.change({ journal in
            if value.archived {
                if let index = journal.roles.firstIndex(where: { $0.id == value.id }) {
                    journal.roles[index].archived = false
                }
            } else {
                journal.archive(value.id)
            }
        }) {
            if model.capture.action.trimmed.isEmpty { model.capture.roleID = model.journal.currentRole }
            dismiss()
        }
    }
}
