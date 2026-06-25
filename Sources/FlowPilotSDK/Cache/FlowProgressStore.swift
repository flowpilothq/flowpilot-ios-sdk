import Foundation

// MARK: - Flow Progress Snapshot

/// A persisted snapshot of a user's in-progress run of a flow.
///
/// Written when a flow has `settings.saveProgress == true` so that, if the user
/// leaves mid-flow and reopens the app, the SDK can resume them on the screen
/// they last reached with their previous answers intact. Tied to a specific
/// `flowVersionId` — a snapshot is discarded if the resolved flow has since been
/// republished, since the navigation graph may have changed.
struct FlowProgressSnapshot: Codable, Sendable {
    let flowId: String
    let flowVersionId: String
    let userId: String
    let navigation: NavigationProgressSnapshot
    let variables: [String: VariableValue]
    let savedAt: Date
}

// MARK: - Flow Progress Store

/// On-device persistence for flow progress snapshots.
///
/// Stores one JSON file per (flow, user) under Application Support so progress
/// survives across launches and is not purged under cache pressure the way the
/// `DiskCache` (`.cachesDirectory`) can be. Writes are async on a utility queue;
/// reads are synchronous (a single small file).
final class FlowProgressStore: @unchecked Sendable {
    static let shared = FlowProgressStore()

    private let directory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "io.flowpilot.progress", qos: .utility)

    init(directory: URL? = nil) {
        if let dir = directory {
            self.directory = dir
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("FlowPilot/Progress", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Load a saved snapshot for a flow/user, or `nil` if none exists or it's unreadable.
    func load(flowId: String, userId: String) -> FlowProgressSnapshot? {
        let url = fileURL(flowId: flowId, userId: userId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(FlowProgressSnapshot.self, from: data)
        } catch {
            Logger.shared.warn("Failed to read flow progress for \(flowId): \(error)")
            // Corrupt file — drop it so it can't keep failing.
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    /// Persist a snapshot (async, atomic write).
    func save(_ snapshot: FlowProgressSnapshot) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try self.encoder.encode(snapshot)
                let url = self.fileURL(flowId: snapshot.flowId, userId: snapshot.userId)
                try data.write(to: url, options: .atomic)
            } catch {
                Logger.shared.warn("Failed to write flow progress for \(snapshot.flowId): \(error)")
            }
        }
    }

    /// Remove any saved snapshot for a flow/user (e.g. after completion).
    func clear(flowId: String, userId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? self.fileManager.removeItem(at: self.fileURL(flowId: flowId, userId: userId))
        }
    }

    // MARK: - Helpers

    private func fileURL(flowId: String, userId: String) -> URL {
        let key = "progress_\(flowId)_\(userId)"
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return directory.appendingPathComponent(safeKey + ".json")
    }
}
