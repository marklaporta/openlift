import Foundation
import XCTest
@testable import OpenLift

final class DirectExportServiceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private let endpoint = URL(string: "https://openlift.test/openlift-export")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsSuiteName = "DirectExportServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func testConfigurationIsDisabledWithoutValidHTTPSEndpoint() {
        XCTAssertNil(DirectExportService.Configuration.resolve(infoDictionary: [:]))
        XCTAssertNil(DirectExportService.Configuration.resolve(infoDictionary: [
            DirectExportService.endpointInfoKey: "",
            DirectExportService.tokenInfoKey: "secret"
        ]))
        XCTAssertNil(DirectExportService.Configuration.resolve(infoDictionary: [
            DirectExportService.endpointInfoKey: "http://openlift.test/openlift-export"
        ]))
        XCTAssertNil(DirectExportService.Configuration.resolve(infoDictionary: [
            DirectExportService.endpointInfoKey: "$(OPENLIFT_DIRECT_EXPORT_ENDPOINT)"
        ]))
    }

    func testEndpointOnlyRequestHasNoAuthorizationHeader() throws {
        let configuration = try XCTUnwrap(DirectExportService.Configuration.resolve(infoDictionary: [
            DirectExportService.endpointInfoKey: endpoint.absoluteString
        ]))
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"test"}"#.utf8)

        let request = DirectExportService.makeRequest(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, payload)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), sessionId.uuidString)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTransportErrorRetainsPayloadForRetry() async throws {
        struct Offline: Error {}

        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"offline"}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root,
            now: now
        )
        let environment = DirectExportService.Environment(
            queueDirectory: root,
            now: { now },
            send: { _ in throw Offline() }
        )

        let summary = await DirectExportService.retryPending(
            configuration: configuration,
            environment: environment
        )

        XCTAssertEqual(summary.deliveredCount, 0)
        XCTAssertEqual(summary.pendingCount, 1)
        let retained = try XCTUnwrap(DirectExportService.loadEntries(queueDirectory: root).first)
        XCTAssertEqual(retained.payload, payload)
        XCTAssertEqual(retained.attemptCount, 1)
        XCTAssertEqual(retained.lastResult, "transport_error")
        XCTAssertEqual(retained.nextAttemptAt, now.addingTimeInterval(60))
    }

    func testScopedTokenAppearsOnlyInRequestAndNotQueue() throws {
        let token = "scoped-private-token"
        let configuration = DirectExportService.Configuration(
            endpoint: endpoint,
            bearerToken: token
        )
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"token-test"}"#.utf8)

        let request = DirectExportService.makeRequest(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)"
        )

        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root
        )
        let queueFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let persisted = try String(contentsOf: queueFile, encoding: .utf8)
        XCTAssertFalse(persisted.contains(token))
        XCTAssertFalse(persisted.contains("Authorization"))
    }

    func testDisabledConfigurationDoesNotCreateQueue() throws {
        try DirectExportService.enqueue(
            payload: Data("payload".utf8),
            sessionId: UUID(),
            configuration: nil,
            queueDirectory: root
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty
        )
    }

    func testEnqueueIsIdempotentBySessionAndPreservesBackoffForSamePayload() async throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"same"}"#.utf8)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root,
            now: start
        )
        let failedEnvironment = DirectExportService.Environment(
            queueDirectory: root,
            now: { start },
            send: { _ in 503 }
        )
        _ = await DirectExportService.retryPending(
            configuration: configuration,
            environment: failedEnvironment
        )

        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root,
            now: start.addingTimeInterval(30)
        )
        let entries = DirectExportService.loadEntries(queueDirectory: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].attemptCount, 1)
        XCTAssertEqual(entries[0].nextAttemptAt, start.addingTimeInterval(60))
    }

    func testTwoHundredResponseRemovesQueuedPayload() async throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"success"}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root,
            now: now
        )
        let recorder = RequestRecorder(statusCodes: [204])
        let environment = DirectExportService.Environment(
            queueDirectory: root,
            now: { now },
            send: { request in await recorder.send(request) }
        )

        let summary = await DirectExportService.retryPending(
            configuration: configuration,
            environment: environment
        )

        XCTAssertEqual(summary.deliveredCount, 1)
        XCTAssertEqual(summary.pendingCount, 0)
        XCTAssertTrue(DirectExportService.loadEntries(queueDirectory: root).isEmpty)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpBody, payload)
    }

    func testFailureRetainsPayloadWithBoundedBackoffAndSkipsEarlyRetry() async throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let sessionId = UUID()
        let payload = Data(#"{"session_id":"retry"}"#.utf8)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try DirectExportService.enqueue(
            payload: payload,
            sessionId: sessionId,
            configuration: configuration,
            queueDirectory: root,
            now: start
        )
        let recorder = RequestRecorder(statusCodes: [500, 200])
        let firstEnvironment = DirectExportService.Environment(
            queueDirectory: root,
            now: { start },
            send: { request in await recorder.send(request) }
        )

        let failed = await DirectExportService.retryPending(
            configuration: configuration,
            environment: firstEnvironment
        )
        XCTAssertEqual(failed.deliveredCount, 0)
        XCTAssertEqual(failed.pendingCount, 1)
        let retained = try XCTUnwrap(DirectExportService.loadEntries(queueDirectory: root).first)
        XCTAssertEqual(retained.payload, payload)
        XCTAssertEqual(retained.attemptCount, 1)
        XCTAssertEqual(retained.lastResult, "http_500")
        XCTAssertEqual(retained.nextAttemptAt, start.addingTimeInterval(60))

        let earlyEnvironment = DirectExportService.Environment(
            queueDirectory: root,
            now: { start.addingTimeInterval(59) },
            send: { request in await recorder.send(request) }
        )
        _ = await DirectExportService.retryPending(
            configuration: configuration,
            environment: earlyEnvironment
        )
        let earlyRequestCount = await recorder.count
        XCTAssertEqual(earlyRequestCount, 1)

        let dueEnvironment = DirectExportService.Environment(
            queueDirectory: root,
            now: { start.addingTimeInterval(60) },
            send: { request in await recorder.send(request) }
        )
        let recovered = await DirectExportService.retryPending(
            configuration: configuration,
            environment: dueEnvironment
        )
        XCTAssertEqual(recovered.deliveredCount, 1)
        XCTAssertEqual(recovered.pendingCount, 0)

        XCTAssertEqual(DirectExportService.retryDelay(afterAttempt: 100), 6 * 60 * 60)
    }

    func testBackfillScansOnlyImmediateLocalCompletedWorkoutFilesAndRunsOnce() async throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let localDocuments = root.appendingPathComponent("Documents", isDirectory: true)
        let exports = localDocuments.appendingPathComponent("OpenLift/exports", isDirectory: true)
        let drafts = exports.appendingPathComponent("drafts", isDirectory: true)
        let readiness = exports.appendingPathComponent("readiness", isDirectory: true)
        let queue = root.appendingPathComponent("Queue", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readiness, withIntermediateDirectories: true)

        let fixedId = UUID()
        let adaptiveId = UUID()
        let fixedPayload = workoutPayload(sessionId: fixedId, kind: "rotation")
        let adaptivePayload = workoutPayload(sessionId: adaptiveId, kind: "adaptive")
        try fixedPayload.write(to: exports.appendingPathComponent("workout-fixed.json"))
        try adaptivePayload.write(to: exports.appendingPathComponent("workout-adaptive.json"))
        try workoutPayload(sessionId: UUID(), kind: "readiness")
            .write(to: exports.appendingPathComponent("readiness-root.json"))
        try workoutPayload(sessionId: UUID(), kind: "draft")
            .write(to: drafts.appendingPathComponent("workout-draft.json"))
        try workoutPayload(sessionId: UUID(), kind: "readiness")
            .write(to: readiness.appendingPathComponent("workout-readiness.json"))
        try Data(#"{"session_id":"not-a-uuid"}"#.utf8)
            .write(to: exports.appendingPathComponent("workout-invalid.json"))

        let count = try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queue,
            defaults: defaults
        )

        XCTAssertEqual(count, 2)
        XCTAssertTrue(defaults.bool(forKey: DirectExportService.backfillCompletionKey))
        let entries = DirectExportService.loadEntries(queueDirectory: queue)
        XCTAssertEqual(Set(entries.map(\.sessionId)), Set([fixedId.uuidString, adaptiveId.uuidString]))
        XCTAssertEqual(Set(entries.map(\.payload)), Set([fixedPayload, adaptivePayload]))

        let environment = DirectExportService.Environment(
            queueDirectory: queue,
            now: Date.init,
            send: { _ in 204 }
        )
        _ = await DirectExportService.retryPending(
            configuration: configuration,
            environment: environment
        )
        XCTAssertTrue(DirectExportService.loadEntries(queueDirectory: queue).isEmpty)

        let repeatedCount = try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queue,
            defaults: defaults
        )
        XCTAssertEqual(repeatedCount, 0)
        XCTAssertTrue(DirectExportService.loadEntries(queueDirectory: queue).isEmpty)
    }

    func testBackfillBoundsCandidateCountAndFileSize() throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let localDocuments = root.appendingPathComponent("Documents", isDirectory: true)
        let exports = localDocuments.appendingPathComponent("OpenLift/exports", isDirectory: true)
        let queue = root.appendingPathComponent("Queue", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let firstPayload = workoutPayload(sessionId: UUID(), kind: "rotation")
        let oversizedPayload = workoutPayload(
            sessionId: UUID(),
            kind: String(repeating: "x", count: firstPayload.count + 1)
        )
        try firstPayload.write(to: exports.appendingPathComponent("workout-1.json"))
        try oversizedPayload.write(to: exports.appendingPathComponent("workout-2.json"))
        try workoutPayload(sessionId: UUID(), kind: "adaptive")
            .write(to: exports.appendingPathComponent("workout-3.json"))

        let count = try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queue,
            defaults: defaults,
            completionKey: "bounded-backfill",
            limit: 2,
            maxFileBytes: firstPayload.count
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(DirectExportService.loadEntries(queueDirectory: queue).count, 1)
        XCTAssertTrue(defaults.bool(forKey: "bounded-backfill"))
    }

    func testBackfillReenqueuePreservesExistingFailureBackoff() async throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let localDocuments = root.appendingPathComponent("Documents", isDirectory: true)
        let exports = localDocuments.appendingPathComponent("OpenLift/exports", isDirectory: true)
        let queue = root.appendingPathComponent("Queue", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let sessionId = UUID()
        let payload = workoutPayload(sessionId: sessionId, kind: "adaptive")
        try payload.write(to: exports.appendingPathComponent("workout-existing.json"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queue,
            defaults: defaults,
            completionKey: "retry-backfill",
            now: start
        )
        _ = await DirectExportService.retryPending(
            configuration: configuration,
            environment: DirectExportService.Environment(
                queueDirectory: queue,
                now: { start },
                send: { _ in 503 }
            )
        )
        defaults.removeObject(forKey: "retry-backfill")

        _ = try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queue,
            defaults: defaults,
            completionKey: "retry-backfill",
            now: start.addingTimeInterval(30)
        )

        let retained = try XCTUnwrap(DirectExportService.loadEntries(queueDirectory: queue).first)
        XCTAssertEqual(retained.sessionId, sessionId.uuidString)
        XCTAssertEqual(retained.attemptCount, 1)
        XCTAssertEqual(retained.nextAttemptAt, start.addingTimeInterval(60))
    }

    func testDisabledBackfillDoesNotMarkCompletion() throws {
        let count = try DirectExportService.backfillLocalWorkoutExports(
            configuration: nil,
            localDocumentsURL: root,
            queueDirectory: root.appendingPathComponent("Queue"),
            defaults: defaults
        )
        XCTAssertEqual(count, 0)
        XCTAssertFalse(defaults.bool(forKey: DirectExportService.backfillCompletionKey))
    }

    func testBackfillQueueWriteFailureDoesNotMarkCompletion() throws {
        let configuration = DirectExportService.Configuration(endpoint: endpoint, bearerToken: nil)
        let localDocuments = root.appendingPathComponent("Documents", isDirectory: true)
        let exports = localDocuments.appendingPathComponent("OpenLift/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try workoutPayload(sessionId: UUID(), kind: "rotation")
            .write(to: exports.appendingPathComponent("workout-existing.json"))
        let queueBlocker = root.appendingPathComponent("Queue")
        try Data("not a directory".utf8).write(to: queueBlocker)

        XCTAssertThrowsError(try DirectExportService.backfillLocalWorkoutExports(
            configuration: configuration,
            localDocumentsURL: localDocuments,
            queueDirectory: queueBlocker,
            defaults: defaults
        ))
        XCTAssertFalse(defaults.bool(forKey: DirectExportService.backfillCompletionKey))
    }

    private func workoutPayload(sessionId: UUID, kind: String) -> Data {
        Data(#"{"session_id":"\#(sessionId.uuidString)","workout_kind":"\#(kind)"}"#.utf8)
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    private var statusCodes: [Int]

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    var count: Int { requests.count }

    func send(_ request: URLRequest) -> Int {
        requests.append(request)
        return statusCodes.isEmpty ? 500 : statusCodes.removeFirst()
    }
}
