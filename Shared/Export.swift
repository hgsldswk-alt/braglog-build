import Foundation

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case review, star, resume, list
    var id: Self { self }
    var title: String { L.t("format." + rawValue) }
}

enum ExtraField: String, Codable, CaseIterable, Identifiable, Sendable {
    case project, date
    var id: Self { self }
    var title: String { L.t("field." + rawValue) }
}

struct ExportTemplate: Codable, Hashable, Sendable {
    var format: ExportFormat = .review
    var fields: [ExtraField] = [.project, .date]
    var includeProject = false
    var includeDate = false

    var effective: Self {
        guard format == .review else { return Self(format: format) }
        var value = self
        if !includeProject || !includeDate { value.fields = [.project, .date] }
        return value
    }

    func text(_ wins: [Win]) -> String {
        wins.sorted(by: Win.recent).map(render).joined(separator: "\n\n")
    }

    func missingSTAR(_ wins: [Win]) -> Int {
        guard format == .star else { return 0 }
        return wins.filter { $0.situation.trimmed.isEmpty || $0.task.trimmed.isEmpty }.count
    }

    private func render(_ win: Win) -> String {
        func labeled(_ key: String, _ value: String, prefix: String = "") -> String? {
            value.trimmed.isEmpty ? nil : prefix + L.f(key, value)
        }

        switch format {
        case .review:
            let extras = fields.compactMap { field -> String? in
                switch field {
                case .project:
                    return includeProject ? labeled("line.project", win.project, prefix: "  ") : nil
                case .date:
                    return includeDate ? labeled("line.date", win.day.raw, prefix: "  ") : nil
                }
            }
            return (["• " + win.action] + [
                labeled("line.result", win.result, prefix: "  "),
                labeled("line.metric", win.metric, prefix: "  ")
            ].compactMap { $0 } + extras).joined(separator: "\n")
        case .star:
            let outcome = [win.result, win.metric].filter { !$0.trimmed.isEmpty }.joined(separator: " · ")
            return [labeled("line.situation", win.situation), labeled("line.task", win.task),
                    labeled("line.action", win.action), labeled("line.starResult", outcome)]
                .compactMap { $0 }.joined(separator: "\n")
        case .resume:
            let result = win.result.trimmed.isEmpty ? "" : " — " + win.result
            let metric = win.metric.trimmed.isEmpty ? "" : " (" + win.metric + ")"
            return "• " + win.action + result + metric
        case .list:
            return ([win.day.raw + " ｜ " + win.action] + [
                labeled("line.result", win.result, prefix: "  "),
                labeled("line.metric", win.metric, prefix: "  ")
            ].compactMap { $0 }).joined(separator: "\n")
        }
    }
}

enum TemplateCode {
    static let prefix = "BLT1:"
    private static let keys: Set<String> = ["version", "format", "fields", "includeProject", "includeDate"]

    private struct Payload: Codable {
        let version: Int
        let format: ExportFormat
        let fields: [ExtraField]
        let includeProject: Bool
        let includeDate: Bool
    }

    static func encode(_ template: ExportTemplate) throws -> String {
        let clean = template.effective
        let payload = Payload(version: 1, format: clean.format, fields: clean.fields,
                              includeProject: clean.includeProject, includeDate: clean.includeDate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(payload)
        let code = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return prefix + code
    }

    static func decode(_ text: String) throws -> ExportTemplate {
        let code = text.trimmed
        guard code.hasPrefix(prefix), code.utf8.count <= 512 else { throw JournalFailure.invalid }
        let body = code.dropFirst(prefix.count)
        guard !body.isEmpty, body.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw JournalFailure.invalid }
        let padded = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= 256,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else { throw JournalFailure.invalid }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1, payload.fields.count == ExtraField.allCases.count,
              Set(payload.fields) == Set(ExtraField.allCases) else { throw JournalFailure.invalid }
        return ExportTemplate(format: payload.format, fields: payload.fields,
                              includeProject: payload.includeProject, includeDate: payload.includeDate).effective
    }
}

enum PublicCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case recognition, feedback, problem, other
    var id: Self { self }
    var title: String { L.t("category." + rawValue) }

    init(win: Win) {
        for category in Self.allCases where category != .other {
            if win.tags.contains(where: {
                $0 == category.rawValue || $0.localizedCaseInsensitiveCompare(category.title) == .orderedSame
                    || Self.aliases[category, default: []].contains($0.lowercased())
            }) {
                self = category
                return
            }
        }
        self = .other
    }

    private static let aliases: [Self: Set<String>] = [
        .recognition: ["recognition", "manager praise", "领导表扬", "主管肯定"],
        .feedback: ["client feedback", "customer feedback", "客户反馈", "客戶回饋"],
        .problem: ["problem solved", "problem solving", "解决问题", "解決問題"]
    ]
}

struct Counts: Codable, Equatable, Sendable {
    var buckets: [PublicCategory: Int] = [:]
    var total: Int { buckets.values.reduce(0, +) }

    init(_ wins: [Win] = []) {
        for win in wins { add(win) }
    }

    mutating func add(_ win: Win) {
        buckets[PublicCategory(win: win), default: 0] += 1
    }
}
