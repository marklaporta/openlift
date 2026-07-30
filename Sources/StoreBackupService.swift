import Foundation
import OSLog
import SQLite3
import SwiftData

/// Mirrors a full snapshot of the SwiftData store into the same iCloud
/// container the workout exports ride. The JSON exports carry workouts;
/// they do not carry planner state, cycle position, or readiness history.
/// A store snapshot makes a lost phone recoverable to full fidelity from
/// the iCloud mirror alone, with no dependency on development tooling.
///
/// Snapshots are taken with SQLite's `VACUUM INTO` on a separate read-only
/// connection: it runs inside a read transaction, so it is consistent even
/// while SwiftData is writing, and it emits one consolidated file with no
/// -wal/-shm sidecars to keep in sync.
enum StoreBackupService {
    private static let logger = Logger(subsystem: "com.mark.openlift", category: "StoreBackup")

    static let relativeSubdirectory = "backups"
    static let retainedSnapshotCount = 7

    enum BackupError: LocalizedError {
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message):
                return "Store snapshot failed: \(message)"
            }
        }
    }

    static func filename(dateKey: String) -> String {
        "store-\(dateKey).sqlite"
    }

    /// Takes at most one snapshot per local day, keyed by the destination's
    /// contents rather than in-memory state so it survives relaunches. Called
    /// from the same launch/foreground path as export retries.
    @MainActor
    static func mirrorStoreIfNeeded(
        modelContext: ModelContext,
        environment: SessionExportService.ExportEnvironment = .live(),
        now: Date = .now
    ) {
        guard !AppRuntime.isUITesting else { return }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let dateKey = AdaptiveWorkoutService.localDateKey(for: now)
        guard needsSnapshot(dateKey: dateKey, environment: environment) else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try mirrorStore(storeURL: storeURL, dateKey: dateKey, environment: environment)
            } catch {
                logger.error("Store backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The iCloud copy is the one that matters; the local mirror only decides
    /// skipping when the container is unavailable, so a day whose snapshot
    /// landed local-only still reaches iCloud once the container comes up.
    static func needsSnapshot(
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) -> Bool {
        let name = filename(dateKey: dateKey)
        if let iCloudURL = environment.iCloudContainerURL {
            let destination = SessionExportService.exportDirectory(
                containerURL: iCloudURL,
                relativeSubdirectory: relativeSubdirectory
            ).appendingPathComponent(name)
            return !FileManager.default.fileExists(atPath: destination.path)
        }
        if let docs = environment.localDocumentsURL {
            let destination = docs
                .appendingPathComponent("OpenLift", isDirectory: true)
                .appendingPathComponent(relativeSubdirectory, isDirectory: true)
                .appendingPathComponent(name)
            return !FileManager.default.fileExists(atPath: destination.path)
        }
        return false
    }

    @discardableResult
    static func mirrorStore(
        storeURL: URL,
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) throws -> SessionExportService.ExportWriteOutcome {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try snapshot(storeAt: storeURL, into: staging)
        let data = try Data(contentsOf: staging)
        let outcome = try SessionExportService.writeExportData(
            data: data,
            relativeSubdirectory: relativeSubdirectory,
            filename: filename(dateKey: dateKey),
            requireICloudMirror: false,
            environment: environment
        )
        pruneSnapshots(environment: environment)
        return outcome
    }

    static func snapshot(storeAt storeURL: URL, into destination: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open store"
            sqlite3_close(handle)
            throw BackupError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        // VACUUM INTO refuses to overwrite; a stale partial file would wedge
        // every later snapshot, so clear the staging path first.
        try? FileManager.default.removeItem(at: destination)
        let escapedPath = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "VACUUM INTO '\(escapedPath)'", nil, nil, nil) == SQLITE_OK else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Filenames embed the local date key, so lexical order is chronological.
    static func pruneSnapshots(
        environment: SessionExportService.ExportEnvironment,
        keeping: Int = retainedSnapshotCount
    ) {
        var directories: [URL] = []
        if let iCloudURL = environment.iCloudContainerURL {
            directories.append(SessionExportService.exportDirectory(
                containerURL: iCloudURL,
                relativeSubdirectory: relativeSubdirectory
            ))
        }
        if let docs = environment.localDocumentsURL {
            directories.append(docs
                .appendingPathComponent("OpenLift", isDirectory: true)
                .appendingPathComponent(relativeSubdirectory, isDirectory: true))
        }
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            let snapshots = files
                .filter { $0.lastPathComponent.hasPrefix("store-") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in snapshots.dropFirst(keeping) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }
}
