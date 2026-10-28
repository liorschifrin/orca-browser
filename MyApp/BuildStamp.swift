import Foundation

/// When this build was made (the app binary's modification time), so a new
/// build is easy to tell apart from an old one.
enum BuildStamp {
    static let text: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "build ?" }
        return "build " + date.formatted(.dateTime.month().day().hour().minute().second())
    }()
}
