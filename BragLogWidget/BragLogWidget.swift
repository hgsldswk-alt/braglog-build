import SwiftUI
import WidgetKit

struct CaptureEntry: TimelineEntry {
    let date: Date
    let open: Bool
}

struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry { CaptureEntry(date: Date(), open: true) }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: Date(), open: context.isPreview || access()?.isOpen(at: Date()) == true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        let now = Date()
        let value = access()
        var entries = [CaptureEntry(date: now, open: value?.isOpen(at: now) == true)]
        if let end = value?.expires, end > now, entries[0].open {
            entries.append(CaptureEntry(date: end, open: false))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func access() -> WidgetAccess? {
        guard let data = UserDefaults(suiteName: WidgetAccess.group)?.data(forKey: WidgetAccess.key) else { return nil }
        return try? JSONDecoder().decode(WidgetAccess.self, from: data)
    }
}

struct CaptureWidgetView: View {
    let entry: CaptureEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                Label(L.t(entry.open ? "widget.new" : "widget.open"),
                      systemImage: entry.open ? "square.and.pencil" : "book.closed")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.21, green: 0.24, blue: 0.55))
                    Text(L.t("app.name")).font(.system(.headline, design: .serif))
                    Label(L.t(entry.open ? "widget.new" : "widget.open"),
                          systemImage: entry.open ? "plus" : "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.97, green: 0.96, blue: 0.94) }
        .widgetURL(entry.open ? WidgetAccess.captureURL : WidgetAccess.homeURL)
    }
}

@main
struct BragLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BragLog.Capture", provider: CaptureProvider()) { CaptureWidgetView(entry: $0) }
            .configurationDisplayName(L.t("widget.new"))
            .description(L.t("widget.description"))
            .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
