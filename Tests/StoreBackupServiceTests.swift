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

    func testPendingCloudRetryReusesSnapshotAndDoesNotRewriteOrResnapshotLiveStore() throws {
        let store = root.appendingPathComponent("live.store")
        try makeStore(at: store, exerciseCount: 1)
        let baseline = makeEnvironment()
        var writes = 0
        var uploaded = false
        let environment = SessionExportService.ExportEnvironment(
            containerIdentifier: baseline.containerIdentifier, iCloudContainerURL: baseline.iCloudContainerURL,
            localDocumentsURL: baseline.localDocumentsURL,
            coordinatedWrite: { data, url in writes += 1; try data.write(to: url, options: .atomic) },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: true, isUploaded: uploaded,
                                         isUploading: !uploaded, uploadingErrorDescription: nil) }
        )
        let first = try StoreBackupService.mirrorStore(storeURL: store, dateKey: "2026-09-04", environment: environment)
        XCTAssertEqual(first.status, .pending)
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: environment))
        let evidence = StoreBackupService.evidence(dateKey: "2026-09-04", environment: environment)
        XCTAssertTrue(evidence.localSnapshotVerified)
        XCTAssertTrue(evidence.cloudMirrorVerified)
        XCTAssertFalse(evidence.cloudUploadVerified)
        let bytes = try Data(contentsOf: XCTUnwrap(first.localMirrorURL))
        // An absent source makes a needless re-VACUUM fail. Retry must reuse the checked daily snapshot.
        let absentStore = root.appendingPathComponent("absent.store")
        _ = try StoreBackupService.mirrorStore(storeURL: absentStore, dateKey: "2026-09-04", environment: environment)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(first.localMirrorURL)), bytes)
        uploaded = true
        XCTAssertFalse(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: environment))
    }

    func testExistingCloudFileIsNotVerifiedBackupWithoutIntegrityAndUploadEvidence() throws {
        let base = makeEnvironment()
        let cloud = StoreBackupService.destinations(dateKey: "2026-09-04", environment: base).cloud!
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("placeholder or corruption".utf8).write(to: cloud)
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: base))
        XCTAssertFalse(StoreBackupService.evidence(dateKey: "2026-09-04", environment: base).cloudUploadVerified)
        let source = root.appendingPathComponent("source.store")
        try makeStore(at: source, exerciseCount: 1)
        _ = try StoreBackupService.mirrorStore(storeURL: source, dateKey: "2026-09-04", environment: base)
        let metadataCases: [SessionExportService.UbiquityMetadata] = [
            .init(isUbiquitousItem: nil, isUploaded: false, isUploading: false, uploadingErrorDescription: nil),
            .init(isUbiquitousItem: false, isUploaded: true, isUploading: false, uploadingErrorDescription: nil),
            .init(isUbiquitousItem: true, isUploaded: false, isUploading: false, uploadingErrorDescription: "Offline"),
            .init(isUbiquitousItem: true, isUploaded: true, isUploading: false, uploadingErrorDescription: "Upload failed"),
            .init(isUbiquitousItem: true, isUploaded: true, isUploading: false, uploadingErrorDescription: nil, isDownloaded: false)
        ]
        for metadata in metadataCases {
            let environment = SessionExportService.ExportEnvironment(
                containerIdentifier: base.containerIdentifier, iCloudContainerURL: base.iCloudContainerURL,
                localDocumentsURL: base.localDocumentsURL, coordinatedWrite: base.coordinatedWrite,
                ubiquityMetadata: { _ in metadata }
            )
            XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: environment))
            XCTAssertFalse(StoreBackupService.evidence(dateKey: "2026-09-04", environment: environment).cloudUploadVerified)
        }
    }

    func testLocalOnlySnapshotUploadsWhenContainerReturnsAndMetadataFailureStaysPending() throws {
        let base = makeEnvironment()
        let source = root.appendingPathComponent("source.store")
        try makeStore(at: source, exerciseCount: 1)
        let localOnly = SessionExportService.ExportEnvironment(
            containerIdentifier: base.containerIdentifier, iCloudContainerURL: nil,
            localDocumentsURL: base.localDocumentsURL, coordinatedWrite: base.coordinatedWrite,
            ubiquityMetadata: base.ubiquityMetadata
        )
        _ = try StoreBackupService.mirrorStore(storeURL: source, dateKey: "2026-09-04", environment: localOnly)
        XCTAssertFalse(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: localOnly))
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: base))
        let result = try StoreBackupService.mirrorStore(storeURL: root.appendingPathComponent("absent"), dateKey: "2026-09-04", environment: base)
        XCTAssertEqual(result.status, .success)
        let throwingMetadata = SessionExportService.ExportEnvironment(
            containerIdentifier: base.containerIdentifier, iCloudContainerURL: base.iCloudContainerURL,
            localDocumentsURL: base.localDocumentsURL, coordinatedWrite: base.coordinatedWrite,
            ubiquityMetadata: { _ in throw CocoaError(.fileReadUnknown) }
        )
        XCTAssertTrue(StoreBackupService.needsSnapshot(dateKey: "2026-09-04", environment: throwingMetadata))
    }

    func testEvictedCloudSnapshotIsNotOverwrittenWhileDownloadIsPending() throws {
        let base = makeEnvironment()
        let source = root.appendingPathComponent("source.store")
        try makeStore(at: source, exerciseCount: 1)
        let cloud = StoreBackupService.destinations(dateKey: "2026-09-04", environment: base).cloud!
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        let placeholder = Data("evicted snapshot".utf8)
        try placeholder.write(to: cloud)
        let environment = SessionExportService.ExportEnvironment(
            containerIdentifier: base.containerIdentifier, iCloudContainerURL: base.iCloudContainerURL,
            localDocumentsURL: base.localDocumentsURL,
            coordinatedWrite: { _, _ in XCTFail("Must not replace an unreadable ubiquitous snapshot") },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: true, isUploaded: true, isUploading: false,
                                         uploadingErrorDescription: nil, isDownloaded: false) }
        )
        let result = try StoreBackupService.mirrorStore(storeURL: source, dateKey: "2026-09-04", environment: environment)
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(try Data(contentsOf: cloud), placeholder)
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: result.localMirrorURL))
    }

    func testPendingAndCorruptCloudFilesCannotDisplaceUploadedRecoveryPoints() throws {
        let base = makeEnvironment()
        let source = root.appendingPathComponent("retention-source.store")
        try makeStore(at: source, exerciseCount: 1)
        let snapshot = root.appendingPathComponent("retention-source.sqlite")
        try StoreBackupService.snapshot(storeAt: source, into: snapshot)
        let bytes = try Data(contentsOf: snapshot)
        let directory = iCloudBackupsDirectory(base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func destination(_ day: Int) -> URL {
            directory.appendingPathComponent(StoreBackupService.filename(dateKey: String(format: "2026-07-%02d", day)))
        }
        // Eight uploaded recovery points, followed by a newer pending upload
        // and a corrupt file whose metadata incorrectly looks successful.
        for day in 1...9 { try bytes.write(to: destination(day)) }
        try Data("corrupt snapshot".utf8).write(to: destination(10))
        let environment = SessionExportService.ExportEnvironment(
            containerIdentifier: base.containerIdentifier, iCloudContainerURL: base.iCloudContainerURL,
            localDocumentsURL: base.localDocumentsURL, coordinatedWrite: base.coordinatedWrite,
            ubiquityMetadata: { url in
                let pending = url.lastPathComponent == "store-2026-07-09.sqlite"
                return .init(isUbiquitousItem: true, isUploaded: !pending,
                             isUploading: pending, uploadingErrorDescription: nil)
            }
        )

        StoreBackupService.pruneSnapshots(environment: environment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination(1).path))
        for day in 2...8 {
            XCTAssertTrue(StoreBackupService.isValidSnapshot(at: destination(day)),
                          "Uploaded recovery point \(day) must survive pending/corrupt newer files")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination(9).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination(10).path))
    }

    func testPruneKeepsNewestSnapshotsInBothDestinations() throws {
        let environment = makeEnvironment()
        let source = root.appendingPathComponent("prune-source.store")
        try makeStore(at: source, exerciseCount: 1)
        let verified = root.appendingPathComponent("prune-source.sqlite")
        try StoreBackupService.snapshot(storeAt: source, into: verified)
        let bytes = try Data(contentsOf: verified)
        let directories = [iCloudBackupsDirectory(environment), localBackupsDirectory(environment)]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for day in 1...9 {
                let name = StoreBackupService.filename(dateKey: String(format: "2026-07-%02d", day))
                try bytes.write(to: directory.appendingPathComponent(name))
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
