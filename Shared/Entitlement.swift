import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    static let trialLength: TimeInterval = 30 * 86_400
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(Self.trialLength) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (trialStart <= now && now < trialEnd)
    }

    mutating func reconcile(pro: Bool, trialReceipt: Date?) {
        purchasedPro = pro
        if let trialReceipt {
            trialClaimedAt = min(trialReceipt, trialClaimedAt ?? trialReceipt)
        }
    }
}

enum TrialReceipt {
    private static let marker = "424C5431"

    static func token(start: Date) -> UUID? {
        let millis = (start.timeIntervalSince1970 * 1000).rounded(.up)
        guard millis.isFinite, millis >= 0, millis < 281_474_976_710_656 else { return nil }
        let stamp = String(format: "%012llX", UInt64(millis))
        let parts = UUID().uuidString.split(separator: "-")
        let token = "\(stamp.prefix(8))-\(stamp.suffix(4))-\(parts[2])-\(parts[3])-"
            + marker + String(parts[4].suffix(4))
        return UUID(uuidString: token)
    }

    static func start(token: UUID?, purchaseDate: Date) -> Date {
        guard let token else { return purchaseDate }
        let parts = token.uuidString.split(separator: "-")
        guard parts[4].hasPrefix(marker), let millis = UInt64(String(parts[0]) + String(parts[1]), radix: 16)
        else { return purchaseDate }
        let decoded = Date(timeIntervalSince1970: Double(millis) / 1000)
        let age = purchaseDate.timeIntervalSince(decoded)
        guard age >= -60, age <= Entitlement.trialLength + 60 else { return purchaseDate }
        return min(purchaseDate, decoded)
    }
}
