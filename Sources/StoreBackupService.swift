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
    private static let snapshotLock = NSLock()
    @MainActor private static var isMirroring = false

    struct Evidence: Equatable {
        let localSnapshotVerified: Bool
        let cloudMirrorVerified: Bool
        let cloudUploadVerified: Bool
        let detail: String
    }

    static func destinations(
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) -> (local: URL?, cloud: URL?) {
        let name = filename(dateKey: dateKey)
        return (
            environment.localDocumentsURL?
                .appendingPathComponent("OpenLift/\(relativeSubdirectory)", isDirectory: true)
                .appendingPathComponent(name),
            environment.iCloudContainerURL.map {
                SessionExportService.exportDirectory(containerURL: $0, relativeSubdirectory: relativeSubdirectory)
                    .appendingPathComponent(name)
            }
        )
    }

    /// A filename or an evicted iCloud placeholder is not a checked snapshot.
    /// Validate SQLite's actual result row (executing PRAGMA alone is insufficient).
    static func isValidSnapshot(at url: URL?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    static func evidence(
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) -> Evidence {
        let urls = destinations(dateKey: dateKey, environment: environment)
        let local = isValidSnapshot(at: urls.local)
        let metadata = urls.cloud.flatMap { try? environment.ubiquityMetadata($0) }
        let cloud = metadata?.isDownloaded != false && isValidSnapshot(at: urls.cloud)
        let mirrored = cloud && metadata?.isUbiquitousItem == true
        let uploaded = mirrored && metadata?.isUploaded == true && metadata?.uploadingErrorDescription == nil
        let detail: String
        if uploaded { detail = "Today's full-store snapshot: iCloud upload confirmed." }
        else if let error = metadata?.uploadingErrorDescription { detail = "Full-store iCloud upload failed: \(error)" }
        else if metadata?.isUbiquitousItem == false { detail = "Full-store iCloud backup is not verified: the destination is not an iCloud item." }
        else if mirrored { detail = "Today's full-store snapshot is mirrored; iCloud upload is not confirmed." }
        else if local { detail = "Today's full-store snapshot is local only; iCloud backup is not confirmed." }
        else { detail = "No verified full-store snapshot for today." }
        return Evidence(localSnapshotVerified: local, cloudMirrorVerified: mirrored,
                        cloudUploadVerified: uploaded, detail: detail)
    }

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
        guard !AppRuntime.isUITesting, !isMirroring else { return }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let dateKey = AdaptiveWorkoutService.localDateKey(for: now)
        isMirroring = true
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in isMirroring = false } }
            guard needsSnapshot(dateKey: dateKey, environment: environment) else { return }
            do {
                _ = try mirrorStore(storeURL: storeURL, dateKey: dateKey, environment: environment)
            } catch {
                logger.error("Store backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// This gates both first snapshot creation and later upload verification.
    /// A pending mirror is retried with identical snapshot bytes, not a new VACUUM.
    static func needsSnapshot(
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) -> Bool {
        let state = evidence(dateKey: dateKey, environment: environment)
        return environment.iCloudContainerURL != nil
            ? !state.cloudUploadVerified
            : environment.localDocumentsURL != nil && !state.localSnapshotVerified
    }

    @discardableResult
    static func mirrorStore(
        storeURL: URL,
        dateKey: String,
        environment: SessionExportService.ExportEnvironment
    ) throws -> SessionExportService.ExportWriteOutcome {
        // Foreground and retry paths must never race to replace a daily snapshot.
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let urls = destinations(dateKey: dateKey, environment: environment)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        let metadata = urls.cloud.flatMap { try? environment.ubiquityMetadata($0) }
        let source: URL
        if metadata?.isDownloaded != false, isValidSnapshot(at: urls.cloud), let cloud = urls.cloud {
            source = cloud
        } else if isValidSnapshot(at: urls.local), let local = urls.local {
            source = local
        } else {
            try snapshot(storeAt: storeURL, into: staging)
            guard isValidSnapshot(at: staging) else { throw BackupError.sqlite("snapshot integrity check failed") }
            source = staging
        }
        let data = try Data(contentsOf: source)
        // Do not overwrite an evicted, potentially good cloud snapshot. Request
        // its download and keep a local snapshot while waiting for readable bytes.
        let awaitingDownload = metadata?.isUbiquitousItem == true && metadata?.isDownloaded == false
        if awaitingDownload, let cloud = urls.cloud {
            try? FileManager.default.startDownloadingUbiquitousItem(at: cloud)
        }
        let writeEnvironment = awaitingDownload
            ? SessionExportService.ExportEnvironment(
                containerIdentifier: environment.containerIdentifier,
                iCloudContainerURL: nil,
                localDocumentsURL: environment.localDocumentsURL,
                coordinatedWrite: environment.coordinatedWrite,
                ubiquityMetadata: environment.ubiquityMetadata
            ) : environment
        let outcome = try SessionExportService.writeExportData(
            data: data,
            relativeSubdirectory: relativeSubdirectory,
            filename: filename(dateKey: dateKey),
            requireICloudMirror: false,
            environment: writeEnvironment
        )
        // Only verified snapshots count toward retention; pending/corrupt cloud
        // files cannot displace the last seven uploaded recovery points.
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
        var directories: [(url: URL, isCloud: Bool)] = []
        if let iCloudURL = environment.iCloudContainerURL {
            directories.append((SessionExportService.exportDirectory(
                containerURL: iCloudURL,
                relativeSubdirectory: relativeSubdirectory
            ), true))
        }
        if let docs = environment.localDocumentsURL {
            directories.append((docs
                .appendingPathComponent("OpenLift", isDirectory: true)
                .appendingPathComponent(relativeSubdirectory, isDirectory: true), false))
        }
        for (directory, isCloud) in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            let snapshots = files
                .filter { $0.lastPathComponent.hasPrefix("store-") && $0.pathExtension == "sqlite" }
                .filter { url in
                    // Corrupt/pending files must not displace good recovery points.
                    if isCloud {
                        guard let metadata = try? environment.ubiquityMetadata(url),
                              metadata.isUbiquitousItem == true, metadata.isUploaded,
                              metadata.isDownloaded != false, metadata.uploadingErrorDescription == nil else { return false }
                    }
                    return isValidSnapshot(at: url)
                }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in snapshots.dropFirst(keeping) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }
}
