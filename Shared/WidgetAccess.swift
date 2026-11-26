import Foundation

struct WidgetAccess: Codable, Sendable {
    static let group = "group.com.hgsldswk.braglog"
    static let key = "capture-access"
    static let captureURL = URL(string: "braglog://capture")!
    static let homeURL = URL(string: "braglog://home")!

    var unlocked: Bool
    var expires: Date?

    func isOpen(at date: Date) -> Bool {
        unlocked && (expires.map { date < $0 } ?? true)
    }
}
