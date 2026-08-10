import Foundation
import XCTest
@testable import OpenLift

final class DirectExportServiceTests: XCTestCase {
    private var root: URL!
    private let endpoint = URL(string: "https://openlift.test/openlift-export")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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
