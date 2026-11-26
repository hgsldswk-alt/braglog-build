import StoreKit
import SwiftUI
import UIKit

@main
struct BragLogApp: App {
    var body: some Scene {
        WindowGroup {
            JournalRoot()
                .preferredColorScheme(.light)
                .tint(D.accent)
        }
    }
}

enum JournalTab: String, CaseIterable, Identifiable {
    case capture, history, export, settings
    var id: Self { self }
    var icon: String {
        switch self {
        case .capture: return "square.and.pencil"
        case .history: return "clock"
        case .export: return "text.document"
        case .settings: return "gearshape"
        }
    }
}

private enum JournalRoute: Identifiable {
    case details, edit(Win), count(Int?), paywall

    var id: String {
        switch self {
        case .details: return "details"
        case .edit(let win): return win.id.uuidString
        case .count(let level): return "count-" + String(level ?? 0)
        case .paywall: return "paywall"
        }
    }
}

struct JournalRoot: View {
    @StateObject private var model = AppModel()
    @StateObject private var store = StoreAccess()
    @Environment(\.scenePhase) private var scene
    @Environment(\.requestReview) private var requestReview
    @FocusState private var composing: Bool
    @State private var tab = JournalTab.capture
    @State private var route: JournalRoute?
    @State private var firstFocus = true
    @State private var pendingCapture = false
    @State private var keyboard = false
    @State private var shareRequest: ShareRequest?
    @State private var sharedFile: URL?
    @State private var reviewChecked = false
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            if model.loaded {
                content
                feedback
                tabBar
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "bookmark.fill").font(.largeTitle).foregroundStyle(D.accent)
                    Text(L.t("app.name")).font(.system(.largeTitle, design: .serif))
                    if let error = model.storageError {
                        Text(L.t(error)).multilineTextAlignment(.center)
                        ActionButton(key: "common.retry", id: "load.retry", primary: true) {
                            Task { await model.start() }
                        }
                    } else {
                        ProgressView().accessibilityLabel(L.t("common.loading"))
                    }
                }
                .padding(D.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(D.paper.ignoresSafeArea())
        .foregroundStyle(D.ink)
        .environmentObject(model)
        .environmentObject(store)
        .sheet(item: $route) { value in
            routeView(value)
                .environmentObject(model)
                .environmentObject(store)
        }
        .sheet(item: $shareRequest, onDismiss: cleanShare) { ActivitySheet(request: $0) }
        .onOpenURL { url in
            guard url == WidgetAccess.captureURL || url == WidgetAccess.homeURL else { return }
            switchTab(.capture)
            if url == WidgetAccess.captureURL {
                pendingCapture = true
                maybeFocus()
            } else {
                pendingCapture = false
                firstFocus = false
            }
        }
        .task { await model.start() }
        .task {
            await store.start()
            if Launch.testFlag("-paywall") { present(.paywall) }
            maybeFocus()
        }
        .onChange(of: model.loaded) { _, _ in maybeFocus() }
        .onChange(of: store.ready) { _, _ in maybeFocus() }
        .onChange(of: model.capture) { _, value in model.queueDraft(value, key: "capture") }
        .onChange(of: model.filter) { _, _ in
            model.exportSelection = nil
            model.rememberPreferences()
        }
        .onChange(of: model.exportTemplate) { _, _ in model.rememberPreferences() }
        .onChange(of: scene) { _, value in
            if value == .active {
                updateToday()
                Task { await store.foreground() }
                model.reconcileReminder()
            } else if value == .background {
                model.reviewCandidate = false
                Task { await model.flushDrafts() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            updateToday()
            model.reconcileReminder()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        .task(id: canRequestReview) { await evaluateReview() }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .capture:
            CaptureView(focus: $composing, now: now, details: { present(.details) },
                        edit: { present(.edit($0)) }, history: { switchTab(.history) },
                        counts: { present(.count(nil)) }, upgrade: { present(.paywall) })
        case .history:
            HistoryView(edit: { present(.edit($0)) }, export: { openExport(reset: true) },
                        upgrade: { present(.paywall) })
        case .export:
            ExportView(share: share, upgrade: { present(.paywall) })
        case .settings:
            SettingsView(share: share, upgrade: { present(.paywall) })
        }
    }

    @ViewBuilder private func routeView(_ value: JournalRoute) -> some View {
        switch value {
        case .details:
            EditWinView(initial: model.capture, editing: false, upgrade: { presentUpgradeAfterSheet() })
        case .edit(let win):
            EditWinView(initial: model.editing(win), editing: true, upgrade: { presentUpgradeAfterSheet() })
        case .count(let level):
            CountCardView(initialLevel: level)
        case .paywall:
            PaywallView()
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(D.line)
            HStack(spacing: 2) {
                ForEach(JournalTab.allCases) { item in
                    Button {
                        if item == .export { openExport(reset: false) }
                        else { switchTab(item) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.body.weight(tab == item ? .semibold : .regular))
                            Text(L.t("tab." + item.rawValue))
                                .font(.caption2.weight(tab == item ? .bold : .medium))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(tab == item ? D.accent : D.muted)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("tab." + item.rawValue)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 3)
        }
        .background(D.paper.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder private var feedback: some View {
        if let error = model.storageError, route == nil {
            HStack {
                Text(L.t(error)).font(.footnote)
                Spacer()
                TextButton(key: "common.dismiss", id: "status.dismiss") { model.storageError = nil }
            }
            .padding(.horizontal, D.inset)
            .foregroundStyle(D.ink)
            .background(D.lilac)
        } else if let notice = model.notice, route == nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L.t(notice.key)).font(.footnote.weight(.semibold))
                        .accessibilityIdentifier(notice.key == "share.requested" ? "share.requested" : "status.message")
                    Spacer()
                    if let id = notice.undo {
                        TextButton(key: "common.undo", id: "status.undo") {
                            Task { await model.undo(id, pro: store.hasPro) }
                        }
                    }
                }
                if let level = notice.milestone {
                    TextButton(key: "card.viewMilestone", id: "status.milestone") { present(.count(level)) }
                }
            }
            .padding(.horizontal, D.inset)
            .padding(.vertical, notice.undo == nil ? 9 : 0)
            .background(D.lilac)
        }
        if reviewChecked && Launch.testing {
            Text(L.t("status.review")).font(.caption2).accessibilityIdentifier("review.requested")
        }
    }

    private func present(_ value: JournalRoute) {
        composing = false
        model.reviewCandidate = false
        route = value
    }

    private func presentUpgradeAfterSheet() {
        guard !Launch.isFree else { return }
        route = nil
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if route == nil { present(.paywall) }
        }
    }

    private func switchTab(_ value: JournalTab) {
        composing = false
        if tab != value { model.reviewCandidate = false }
        tab = value
    }

    private func openExport(reset: Bool) {
        if reset { model.exportSelection = nil }
        switchTab(.export)
    }

    private func maybeFocus() {
        guard model.loaded, route == nil, tab == .capture else { return }
        if pendingCapture {
            guard store.ready else { return }
            pendingCapture = false
            firstFocus = false
            composing = store.hasPro
        } else if firstFocus {
            firstFocus = false
            composing = !Launch.testFlag("-no-focus")
        }
    }

    private func updateToday() {
        let previous = LocalDay(now)
        now = Date()
        let today = LocalDay(now)
        if model.capture.day == previous && model.capture.action.trimmed.isEmpty {
            model.capture.day = today
        }
    }

    private func share(_ request: ShareRequest) {
        if Launch.testing {
            model.show("share.requested")
            let file = request.file
            Task.detached { TransferFiles.remove(file) }
        } else {
            model.reviewCandidate = false
            sharedFile = request.file
            shareRequest = request
        }
    }

    private func cleanShare() {
        let file = sharedFile
        sharedFile = nil
        Task.detached { TransferFiles.remove(file) }
    }

    private var canRequestReview: Bool {
        model.reviewCandidate && tab == .capture && scene == .active && route == nil
            && !composing && !keyboard && model.storageError == nil && model.notice?.milestone == nil
            && shareRequest == nil && !store.busy && !model.busy
    }

    private func evaluateReview() async {
        guard canRequestReview else { return }
        do { try await Task.sleep(for: .seconds(2)) }
        catch { return }
        guard canRequestReview, !Task.isCancelled else { return }
        model.recordReviewRequest()
        if Launch.testing { reviewChecked = true }
        else { requestReview() }
    }
}
