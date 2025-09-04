import Foundation

enum PlaybackMode: Equatable {
    /// MVP: play files in filename order, once
    case sequential

    /// Future: uniform delay between files, optional notification instead of silence
    case randomLoop(minDelay: TimeInterval, maxDelay: TimeInterval, useNotification: Bool)
}
