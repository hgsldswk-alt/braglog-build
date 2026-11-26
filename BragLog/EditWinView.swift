import PhotosUI
import SwiftUI
import UIKit

struct EditWinView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: StoreAccess
    @FocusState private var focus: Field?
    @State private var win: Win
    @State private var tags: String
    @State private var dateAndRole = false
    @State private var star = false
    @State private var photoOptions = false
    @State private var photosPicker = false
    @State private var camera = false
    @State private var imageSelection: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var mediaBusy = false
    @State private var warning: String?

    private enum Field { case action, result, metric, project, tags, situation, task }
    private let editing: Bool
    private let upgrade: () -> Void
    private var key: String { editing ? win.id.uuidString : "capture" }

    init(initial: Win, editing: Bool, upgrade: @escaping () -> Void) {
        _win = State(initialValue: initial)
        _tags = State(initialValue: initial.tags.joined(separator: ", "))
        self.editing = editing
        self.upgrade = upgrade
    }

    var body: some View {
        Page {
            HStack {
                SheetHeader(key: "common.back") { dismiss() }
                Spacer()
                if focus != nil {
                    TextButton(key: "common.done", id: "edit.keyboard") { focus = nil }
                }
                Text(win.day.display).font(.caption).foregroundStyle(D.muted)
            }
            PageTitle(key: editing ? "edit.title" : "capture.details")
            descriptionFields
            tagging
            scheduling
            evidence
            starFields
            if editing {
                TextButton(key: "common.delete", id: "edit.delete", symbol: "trash") {
                    focus = nil
                    Task { if await model.delete(win.id, pro: store.hasPro) { dismiss() } }
                }
                .disabled(model.busy || mediaBusy || !accessible)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .interactiveDismissDisabled(model.busy || mediaBusy)
        .photosPicker(isPresented: $photosPicker, selection: $imageSelection, matching: .images)
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { photo in
                camera = false
                guard let photo else { return }
                Task { await attachCamera(photo) }
            }.ignoresSafeArea()
        }
        .onChange(of: win) { _, value in
            if editing { model.queueDraft(value, key: key) }
            else { model.capture = value }
        }
        .onChange(of: tags) { _, value in
            win.tags = value.components(separatedBy: CharacterSet(charactersIn: ",，;；、"))
                .map(\.trimmed).filter { !$0.isEmpty }
        }
        .onChange(of: imageSelection) { _, value in
            guard let value else { return }
            Task { await attachSelection(value) }
        }
        .task(id: win.photoID) {
            image = nil
            guard let id = win.photoID, let data = await model.photo(id), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
        .task {
            if !editing && !Launch.testFlag("-no-focus") { focus = .result }
        }
        .onChange(of: store.pro) { _, open in
            if !open && !accessible { dismiss() }
        }
    }

    private var accessible: Bool {
        !editing || model.journal.visible(pro: store.pro).contains { $0.id == win.id }
    }

    private var descriptionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("field.action", id: "edit.action", text: $win.action, target: .action, multiline: true)
            field("field.result", id: "edit.result", text: $win.result, target: .result, multiline: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { metric; project }
                VStack(spacing: 10) { metric; project }
            }
        }
        .journalCard()
    }

    private var metric: some View { field("field.metric", id: "edit.metric", text: $win.metric, target: .metric) }
    private var project: some View { field("field.project", id: "edit.project", text: $win.project, target: .project) }

    private func field(_ label: String, id: String, text: Binding<String>, target: Field,
                       multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionName(key: label)
            TextField(L.t(label), text: text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...6 : 1...1)
                .font(.subheadline)
                .journalField()
                .focused($focus, equals: target)
                .submitLabel(target == .metric ? .next : .done)
                .onSubmit { focus = target == .metric ? .project : nil }
                .accessibilityIdentifier(id)
                .disabled(model.busy || mediaBusy)
        }
    }

    private var tagging: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionName(key: "field.tags")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PublicCategory.allCases.filter { $0 != .other }) { tag in
                        Chip(title: tag.title, id: "edit.tag." + tag.rawValue, selected: win.tags.contains(tag.title)) {
                            var items = win.tags
                            if items.contains(tag.title) { items.removeAll { $0 == tag.title } }
                            else { items.append(tag.title) }
                            tags = items.joined(separator: ", ")
                        }
                    }
                }
            }
            TextField(L.t("edit.customTags"), text: $tags)
                .font(.subheadline)
                .journalField()
                .focused($focus, equals: .tags)
                .accessibilityIdentifier("edit.tags")
                .disabled(model.busy || mediaBusy)
        }
        .journalCard()
    }

    private var scheduling: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextButton(key: "edit.dateRole", id: "edit.dateRole",
                       symbol: dateAndRole ? "chevron.up" : "calendar") {
                focus = nil
                dateAndRole.toggle()
            }
            if dateAndRole {
                DatePicker(L.t("field.date"), selection: Binding(get: { win.day.date() },
                    set: { win.day = LocalDay($0) }), displayedComponents: .date)
                    .accessibilityIdentifier("edit.date")
                HStack {
                    Text(L.t("field.role")).font(.subheadline)
                    Spacer()
                    Menu {
                        Button(L.t("role.none")) { win.roleID = nil }
                        ForEach(model.journal.roles.filter { !$0.archived || $0.id == win.roleID }) { role in
                            Button(role.label) { win.roleID = role.id }
                        }
                    } label: {
                        MenuLabel(title: model.journal.roles.first { $0.id == win.roleID }?.label ?? L.t("role.none"))
                    }
                    .accessibilityIdentifier("edit.role")
                }
            } else {
                Text(model.journal.roles.first { $0.id == win.roleID }?.label ?? L.t("role.none"))
                    .font(.caption).foregroundStyle(D.muted)
            }
        }.journalCard(padding: 11)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 265)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(L.t("photo.evidence"))
                    .accessibilityIdentifier("edit.evidence")
            }
            if win.photoID != nil {
                TextButton(key: "photo.remove", id: "edit.removePhoto", symbol: "minus.circle") {
                    win.photoID = nil
                    warning = nil
                }
                .disabled(mediaBusy || model.busy)
            }
            TextButton(key: win.photoID == nil ? "photo.add" : "photo.replace",
                       id: "edit.photo", symbol: store.pro ? "paperclip" : "lock") {
                focus = nil
                if store.hasPro { photoOptions.toggle() }
                else { upgrade() }
            }
            .disabled(mediaBusy || model.busy)
            .confirmationDialog(L.t("photo.add"), isPresented: $photoOptions, titleVisibility: .visible) {
                Button(L.t("photo.library")) { photosPicker = true }
                Button(L.t("photo.camera")) {
                    Task {
                        if await Evidence.cameraAllowed(), !Launch.testing { camera = true }
                        else { warning = "photo.cameraUnavailable" }
                    }
                }
            }
            if mediaBusy { ProgressView().accessibilityLabel(L.t("common.loading")) }
            if let warning {
                Text(L.t(warning)).font(.footnote).foregroundStyle(D.muted)
                    .accessibilityIdentifier("edit.photoMessage")
            }
        }.journalCard(padding: 11)
    }

    private var starFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextButton(key: "edit.star", id: "edit.star", symbol: star ? "chevron.up" : "text.alignleft") {
                star.toggle()
            }
            if star {
                field("field.situation", id: "edit.situation", text: $win.situation, target: .situation, multiline: true)
                field("field.task", id: "edit.task", text: $win.task, target: .task, multiline: true)
            }
        }.journalCard(padding: 11)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.storageError {
                Text(L.t(error)).font(.footnote).accessibilityIdentifier("edit.error")
            }
            ActionButton(key: editing ? "edit.save" : "capture.save", id: "edit.save", primary: true, wide: true) {
                let value = win
                Task {
                    if await model.save(value, editing: editing, pro: store.hasPro) {
                        focus = nil
                        dismiss()
                    }
                }
            }
            .disabled(!win.valid || !accessible || model.busy || mediaBusy)
        }
        .padding(.horizontal, D.inset)
        .padding(.vertical, 8)
        .background(D.paper)
    }

    private func attachSelection(_ selection: PhotosPickerItem) async {
        guard !mediaBusy, store.hasPro else { return }
        mediaBusy = true
        defer { mediaBusy = false; imageSelection = nil }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else { throw JournalFailure.attachment }
            let jpeg = try await Task.detached { try Evidence.jpeg(from: data) }.value
            await attach(jpeg)
        } catch { warning = "error.photo" }
    }

    private func attachCamera(_ photo: UIImage) async {
        guard !mediaBusy, store.hasPro else { return }
        mediaBusy = true
        defer { mediaBusy = false }
        do {
            let jpeg = try await Task.detached {
                guard let data = photo.jpegData(compressionQuality: 0.93) else { throw JournalFailure.attachment }
                return try Evidence.jpeg(from: data)
            }.value
            await attach(jpeg)
        } catch { warning = "error.photo" }
    }

    private func attach(_ jpeg: Data) async {
        guard store.hasPro else { warning = "photo.expired"; return }
        if let next = await model.attach(jpeg, to: win, key: key) {
            win = next
            warning = nil
        } else {
            warning = "error.photo"
        }
    }
}
