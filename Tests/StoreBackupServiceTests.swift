import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import OpenLift

final class StoreBackupServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(at url: URL, exerciseCount: Int) throws {
        let schema = Schema(OpenLiftSchemaV11.models)
        let configuration = ModelConfiguration(
            "StoreBackupFixture",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for index in 0..<exerciseCount {
            context.insert(Exercise(
                name: "Backup Fixture \(index)",
                primaryMuscle: .chest,
                type: .compound,
                equipment: .dumbbell
            ))
        }
        try context.save()
    }

    private func makeEnvironment() -> SessionExportService.ExportEnvironment {
        SessionExportService.ExportEnvironment(
            containerIdentifier: "iCloud.test.openlift",
            iCloudContainerURL: root.appendingPathComponent("iCloud", isDirectory: true),
            localDocumentsURL: root.appendingPathComponent("Documents", isDirectory: true),
            coordinatedWrite: { data, url in
                try data.write(to: url, options: [.atomic])
            },
            ubiquityMetadata: { _ in
                SessionExportService.UbiquityMetadata(
                    isUbiquitousItem: true,
                    isUploaded: true,
                    isUploading: false,
                    uploadingErrorDescription: nil
                )
            }
        )
    }

    private func iCloudBackupsDirectory(_ environment: SessionExportService.ExportEnvironment) -> URL {
        SessionExportService.exportDirectory(
            containerURL: environment.iCloudContainerURL!,
            relativeSubdirectory: StoreBackupService.relativeSubdirectory
        )
    }

    private func localBackupsDirectory(_ environment: SessionExportService.ExportEnvironment) -> URL {
        environment.localDocumentsURL!
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent(StoreBackupService.relativeSubdirectory, isDirectory: true)
    }

    func testSnapshotProducesOpenableConsistentCopy() throws {
        let storeURL = root.appendingPathComponent("live.store")
        try makeStore(at: storeURL, exerciseCount: 5)

        let snapshotURL = root.appendingPathComponent("snapshot.sqlite")
        try StoreBackupService.snapshot(storeAt: storeURL, into: snapshotURL)

        // VACUUM INTO emits one consolidated file; sidecars would mean the
        // snapshot still depends on WAL state that never reaches iCloud.
        // Checked before the verification container below opens the file,
        // which creates fresh sidecars of its own.
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))

        let schema = Schema(OpenLiftSchemaV11.models)
        let configuration = ModelConfiguration(
            "StoreBackupSnapshot",
            schema: schema,
            url: snapshotURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(exercises.count, 5)
        XCTAssertTrue(exercises.allSatisfy { $0.name.hasPrefix("Backup Fixture") })
    }

    func testSnapshotOverwritesStaleStagingFile() throws {
        let storeURL = root.appendingPathComponent("live.store")
        try makeStore(at: storeURL, exerciseCount: 1)

        let snapshotURL = root.appendingPathComponent("snapshot.sqlite")
        try Data("stale partial write".utf8).write(to: snapshotURL)
        try StoreBackupService.snapshot(storeAt: storeURL, into: snapshotURL)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(snapshotURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA integrity_check;", nil, nil, nil), SQLITE_OK)
    }

    func testMirrorStoreWritesBothDestinationsAndSkipsSameDay() throws {
        let storeURL = root.appendingPathComponent("live.store")
        try makeStore(at: storeURL, exerciseCount: 3)
        let environment = makeEnvironment()

        let outcome = try StoreBackupService.mirrorStore(
            storeURL: storeURL,
            dateKey: "2026-07-29",
            environment: environment
        )
        XCTAssertEqual(outcome.status, .success)

        let filename = StoreBackupService.filename(dateKey: "2026-07-29")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: iCloudBackupsDirectory(environment).appendingPathComponent(filename).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: localBackupsDirectory(environment).appendingPathComponent(filename).path
        ))

        XCTAssertFalse(StoreBackupService.needsSnapshot(dateKey: "2026-07-29", environment: environment))
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-07-30", environment: environment))
    }

    func testNeedsSnapshotIgnoresLocalCopyWhileICloudLacksToday() throws {
        let environment = makeEnvironment()
        let filename = StoreBackupService.filename(dateKey: "2026-07-29")
        let localDir = localBackupsDirectory(environment)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try Data("local only".utf8).write(to: localDir.appendingPathComponent(filename))

        // The iCloud container is reachable but has no snapshot for today:
        // the local-only copy must not satisfy the day, or a container that
        // was down at first snapshot would never receive one.
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-07-29", environment: environment))
    }

    func testPruneKeepsNewestSnapshotsInBothDestinations() throws {
        let environment = makeEnvironment()
        let directories = [iCloudBackupsDirectory(environment), localBackupsDirectory(environment)]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for day in 1...9 {
                let name = StoreBackupService.filename(dateKey: String(format: "2026-07-%02d", day))
                try Data("snapshot \(day)".utf8).write(to: directory.appendingPathComponent(name))
            }
            try Data("not a snapshot".utf8).write(to: directory.appendingPathComponent("workout-keep.json"))
        }

        StoreBackupService.pruneSnapshots(environment: environment)

        for directory in directories {
            let remaining = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            let snapshots = remaining
                .filter { $0.pathExtension == "sqlite" }
                .map(\.lastPathComponent)
                .sorted()
            XCTAssertEqual(snapshots.count, StoreBackupService.retainedSnapshotCount)
            XCTAssertEqual(snapshots.first, StoreBackupService.filename(dateKey: "2026-07-03"))
            XCTAssertEqual(snapshots.last, StoreBackupService.filename(dateKey: "2026-07-09"))
            XCTAssertTrue(remaining.contains { $0.lastPathComponent == "workout-keep.json" })
        }
    }
}
