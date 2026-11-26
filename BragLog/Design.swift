import SwiftUI

enum D {
    static let paper = Color(red: 247/255, green: 245/255, blue: 240/255)
    static let card = Color(red: 1, green: 254/255, blue: 252/255)
    static let ink = Color(red: 31/255, green: 42/255, blue: 51/255)
    static let accent = Color(red: 53/255, green: 61/255, blue: 139/255)
    static let muted = Color(red: 91/255, green: 93/255, blue: 105/255)
    static let line = Color(red: 227/255, green: 222/255, blue: 215/255)
    static let lilac = Color(red: 236/255, green: 236/255, blue: 248/255)
    static let amber = Color(red: 175/255, green: 107/255, blue: 28/255)
    static let inset: CGFloat = 21
}

extension View {
    func journalCard(padding: CGFloat = 15) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(D.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(D.line, lineWidth: 1) }
            .shadow(color: D.ink.opacity(0.05), radius: 8, y: 4)
    }

    func journalField() -> some View {
        self.padding(11)
            .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
            .background(D.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(D.line, lineWidth: 1) }
    }
}

struct ActionButton: View {
    let key: String
    let id: String
    var symbol: String? = nil
    var primary = false
    var wide = false
    var display: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(display ?? L.t(key)).lineLimit(2)
            }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .frame(minHeight: 46)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(primary ? Color.white : D.accent)
            .background(primary ? D.accent : D.lilac, in: RoundedRectangle(cornerRadius: 11))
            .opacity(enabled ? 1 : 0.48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct TextButton: View {
    let key: String
    let id: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(L.t(key))
            }
            .foregroundStyle(D.accent)
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct Chip: View {
    let title: String
    let id: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .bold : .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? D.accent : D.muted)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    Capsule().fill(selected ? D.lilac : D.card).padding(.vertical, 5)
                }
                .overlay {
                    Capsule().strokeBorder(selected ? D.accent.opacity(0.32) : D.line, lineWidth: 1)
                        .padding(.vertical, 5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

struct SectionName: View {
    let key: String
    var body: some View {
        Text(L.t(key)).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}

struct PageTitle: View {
    let key: String
    var body: some View {
        Text(L.t(key))
            .font(.system(.largeTitle, design: .serif).weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Wordmark: View {
    var body: some View {
        Label(L.t("app.name"), systemImage: "bookmark.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(D.accent)
            .frame(minHeight: 25, alignment: .leading)
    }
}

struct Page<Contents: View>: View {
    @ViewBuilder let contents: Contents

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) { contents }
                .padding(.horizontal, D.inset)
                .padding(.top, 7)
                .padding(.bottom, 20)
                .frame(maxWidth: 690)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(D.paper)
        .foregroundStyle(D.ink)
    }
}

struct SheetHeader: View {
    let key: String
    let dismiss: () -> Void

    var body: some View {
        TextButton(key: key, id: "sheet.back", symbol: "chevron.left", action: dismiss)
    }
}

struct EmptyJournal: View {
    let title: String
    let hint: String
    var icon = "book.closed"
    var small = false

    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 13).fill(D.lilac)
                    .frame(width: small ? 49 : 63, height: small ? 49 : 63)
                    .rotationEffect(.degrees(-10))
                Image(systemName: icon).font(.system(size: small ? 22 : 29, weight: .regular))
                    .foregroundStyle(D.accent).frame(width: small ? 49 : 63, height: small ? 49 : 63)
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(D.amber)
                    .offset(x: 4, y: -3)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t(title)).font(.system(.headline, design: .serif))
                Text(L.t(hint)).font(.footnote).foregroundStyle(D.muted)
            }
        }
        .journalCard()
    }
}

struct WinRow: View {
    let win: Win
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(win.day.date().formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(D.accent)
                    .frame(minWidth: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(win.action).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let summary = [win.metric, win.project, win.result].first(where: { !$0.trimmed.isEmpty }) {
                        Text(summary).font(.caption).foregroundStyle(D.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                if win.photoID != nil { Image(systemName: "paperclip").foregroundStyle(D.muted) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(D.muted)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("win.row." + win.id.uuidString)
    }
}

struct MenuLabel: View {
    let title: String
    var icon = "chevron.down"
    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: icon).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(D.accent)
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 11)
        .frame(minWidth: 44, minHeight: 44)
        .background(D.lilac, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }
}
