import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    static var isFree: Bool {
        freePeriod && !(testing && ["-paid-mode", "-paywall", "-expired"].contains(where: arguments.contains))
    }
    static func testFlag(_ name: String) -> Bool { testing && arguments.contains(name) }
}
