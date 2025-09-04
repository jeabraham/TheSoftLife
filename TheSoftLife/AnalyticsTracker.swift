import Foundation

struct ListeningRecord: Codable {
    let folderName: String
    let start: Date
    var end: Date?
    var secondsListened: TimeInterval { max(0, (end ?? Date()).timeIntervalSince(start)) }
}

final class AnalyticsTracker {
    func sessionStarted(folderName: String, mode: PlaybackMode, at: Date = Date()) {
        // TODO: store record; keep simple JSON in Documents for now
    }
    func sessionEnded(at: Date = Date()) {
        // TODO: finalize record & persist
    }
    func addListeningChunk(seconds: TimeInterval) {
        // TODO: accumulate by day/folder
    }
}
