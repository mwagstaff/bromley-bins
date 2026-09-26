import BackgroundTasks
import Foundation

/// Asks iOS for roughly twice-daily background refreshes so reminders and
/// widgets pick up council schedule changes (bank holidays and the like) even
/// when the app is not opened. iOS decides when, or whether, these run.
enum BackgroundRefresh {
    static let identifier = "dev.skynolimit.bromleybins.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
