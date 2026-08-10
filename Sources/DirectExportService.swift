import Foundation

/// Best-effort delivery of completed workout JSON to a private receiver.
///
/// The file/iCloud export remains authoritative. This transport only copies the
/// already-serialized payload into a local queue and must never make workout
/// completion depend on network availability.
enum DirectExportService {
    static let endpointInfoKey = "OpenLiftDirectExportEndpoint"
    static let tokenInfoKey = "OpenLiftDirectExportBearerToken"
    static let backfillCompletionKey = "openlift.directExport.localWorkoutBackfill.v1"
    static let maxBackfillFiles = 250
    static let maxBackfillFileBytes = 5 * 1_024 * 1_024

    private struct SessionIdentityEnvelope: Decodable {
        let session_id: String
    }

    struct Configuration: Equatable {
        let endpoint: URL
        let bearerToken: String?

        static func resolve(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Configuration? {
            guard let rawEndpoint = normalizedSetting(infoDictionary[endpointInfoKey]),
                  let endpoint = URL(string: rawEndpoint),
                  endpoint.scheme?.lowercased() == "https",
                  endpoint.host != nil,
                  endpoint.user == nil,
                  endpoint.password == nil,
                  endpoint.fragment == nil else {
                return nil
            }
            return Configuration(
                endpoint: endpoint,
                bearerToken: normalizedSetting(infoDictionary[tokenInfoKey])
            )
        }

        private static func normalizedSetting(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
            return trimmed
        }
    }

    struct QueueEntry: Codable, Equatable {
        let sessionId: String
        var payload: Data
        let createdAt: Date
        var attemptCount: Int
        var lastAttemptAt: Date?
        var nextAttemptAt: Date
        var lastResult: String?
    }

    struct RetrySummary: Equatable {
        let deliveredCount: Int
        let pendingCount: Int
        let nextAttemptAt: Date?
    }

    struct Environment {
        let queueDirectory: URL
        let now: () -> Date
        let send: (URLRequest) async throws -> Int

        static func live() -> Environment? {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            return Environment(
                queueDirectory: applicationSupport
                    .appendingPathComponent("OpenLift", isDirectory: true)
                    .appendingPathComponent("DirectExportQueue", isDirectory: true),
                now: Date.init,
                send: { request in
                    let (_, response) = try await URLSession.shared.data(for: request)
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            )
        }
    }

    private static let queueLock = NSLock()

    static func makeRequest(payload: Data, sessionId: UUID, configuration: Configuration) -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionId.uuidString, forHTTPHeaderField: "Idempotency-Key")
        if let bearerToken = configuration.bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Adds or refreshes one stable session entry. Re-enqueuing byte-identical
    /// JSON leaves retry metadata intact; a corrected payload retries promptly.
    static func enqueue(
        payload: Data,
        sessionId: UUID,
        configuration: Configuration?,
        queueDirectory: URL,
        now: Date = .now
    ) throws {
        guard configuration != nil else { return }
        queueLock.lock()
        defer { queueLock.unlock() }

        try prepareQueueDirectory(queueDirectory)
        let destination = entryURL(sessionId: sessionId, queueDirectory: queueDirectory)
        let decoder = JSONDecoder()
        if let existingData = try? Data(contentsOf: destination),
           var existing = try? decoder.decode(QueueEntry.self, from: existingData) {
            guard existing.payload != payload else { return }
            existing.payload = payload
            existing.attemptCount = 0
            existing.lastAttemptAt = nil
            existing.nextAttemptAt = now
            existing.lastResult = nil
            try write(existing, to: destination)
            return
        }

        try write(
            QueueEntry(
                sessionId: sessionId.uuidString,
                payload: payload,
                createdAt: now,
                attemptCount: 0,
                lastAttemptAt: nil,
                nextAttemptAt: now,
                lastResult: nil
            ),
            to: destination
        )
    }

    /// Enqueues without surfacing any failure into workout completion, then
    /// opportunistically starts delivery and reserves a background retry slot.
    static func enqueueAndSchedule(payload: Data, sessionId: UUID) {
        guard let configuration = Configuration.resolve(),
              let environment = Environment.live() else { return }
        do {
            try enqueue(
                payload: payload,
                sessionId: sessionId,
                configuration: configuration,
                queueDirectory: environment.queueDirectory,
                now: environment.now()
            )
        } catch {
            return
        }
        SessionExportService.scheduleBackgroundExportRetry(after: 60)
        Task {
            let summary = await retryPending(configuration: configuration, environment: environment)
            scheduleNextRetryIfNeeded(summary)
        }
    }

    /// Used at app launch/foreground alongside the existing iCloud retry path.
    static func retryPendingInBackground() {
        guard let configuration = Configuration.resolve(),
              let environment = Environment.live(),
              let localDocumentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first else { return }
        Task.detached(priority: .utility) {
            _ = try? backfillLocalWorkoutExports(
                configuration: configuration,
                localDocumentsURL: localDocumentsURL,
                queueDirectory: environment.queueDirectory,
                defaults: .standard,
                now: environment.now()
            )
            let summary = await retryPending(configuration: configuration, environment: environment)
            scheduleNextRetryIfNeeded(summary)
        }
    }

    /// One-time, capped migration of existing completed workout exports into
    /// the direct-delivery queue. Only the app's local Documents mirror is read;
    /// nested draft/readiness directories and iCloud are deliberately outside
    /// this backfill path.
    @discardableResult
    static func backfillLocalWorkoutExports(
        configuration: Configuration?,
        localDocumentsURL: URL,
        queueDirectory: URL,
        defaults: UserDefaults,
        completionKey: String = backfillCompletionKey,
        limit: Int = maxBackfillFiles,
        maxFileBytes: Int = maxBackfillFileBytes,
        now: Date = .now
    ) throws -> Int {
        guard let configuration, !defaults.bool(forKey: completionKey) else { return 0 }
        let exportDirectory = localDocumentsURL
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: exportDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            defaults.set(true, forKey: completionKey)
            return 0
        }
        let boundedCandidates = candidates
            .filter {
                $0.pathExtension.lowercased() == "json"
                    && $0.lastPathComponent.hasPrefix("workout-")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(max(0, limit))

        var enqueuedCount = 0
        for file in boundedCandidates {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize,
                  fileSize <= max(0, maxFileBytes) else {
                continue
            }
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard let sessionId = completedWorkoutSessionId(data: data) else {
                continue
            }
            try enqueue(
                payload: data,
                sessionId: sessionId,
                configuration: configuration,
                queueDirectory: queueDirectory,
                now: now
            )
            enqueuedCount += 1
        }
        defaults.set(true, forKey: completionKey)
        return enqueuedCount
    }

    @discardableResult
    static func retryPending(
        configuration: Configuration,
        environment: Environment
    ) async -> RetrySummary {
        let now = environment.now()
        let entries = loadEntries(queueDirectory: environment.queueDirectory)
            .sorted { $0.createdAt < $1.createdAt }
        var deliveredCount = 0

        for entry in entries where entry.nextAttemptAt <= now {
            guard let sessionId = UUID(uuidString: entry.sessionId) else {
                recordFailure(
                    entry,
                    result: "invalid_session_id",
                    at: now,
                    queueDirectory: environment.queueDirectory
                )
                continue
            }
            do {
                let statusCode = try await environment.send(
                    makeRequest(payload: entry.payload, sessionId: sessionId, configuration: configuration)
                )
                if (200...299).contains(statusCode) {
                    remove(entry, queueDirectory: environment.queueDirectory)
                    deliveredCount += 1
                } else {
                    recordFailure(
                        entry,
                        result: "http_\(statusCode)",
                        at: now,
                        queueDirectory: environment.queueDirectory
                    )
                }
            } catch {
                recordFailure(
                    entry,
                    result: "transport_error",
                    at: now,
                    queueDirectory: environment.queueDirectory
                )
            }
        }

        let remaining = loadEntries(queueDirectory: environment.queueDirectory)
        return RetrySummary(
            deliveredCount: deliveredCount,
            pendingCount: remaining.count,
            nextAttemptAt: remaining.map(\.nextAttemptAt).min()
        )
    }

    static func loadEntries(queueDirectory: URL) -> [QueueEntry] {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: queueDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { file in
            guard file.pathExtension == "queue",
                  let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(QueueEntry.self, from: data)
        }
    }

    static func retryDelay(afterAttempt attemptCount: Int) -> TimeInterval {
        let exponent = min(max(attemptCount - 1, 0), 9)
        return min(60 * pow(2, Double(exponent)), 6 * 60 * 60)
    }

    private static func completedWorkoutSessionId(data: Data) -> UUID? {
        guard let identity = try? JSONDecoder().decode(SessionIdentityEnvelope.self, from: data) else {
            return nil
        }
        return UUID(uuidString: identity.session_id)
    }

    private static func recordFailure(
        _ original: QueueEntry,
        result: String,
        at date: Date,
        queueDirectory: URL
    ) {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let sessionId = UUID(uuidString: original.sessionId) else { return }
        let destination = entryURL(sessionId: sessionId, queueDirectory: queueDirectory)
        guard let currentData = try? Data(contentsOf: destination),
              var entry = try? JSONDecoder().decode(QueueEntry.self, from: currentData),
              entry.payload == original.payload else { return }
        entry.attemptCount += 1
        entry.lastAttemptAt = date
        entry.nextAttemptAt = date.addingTimeInterval(retryDelay(afterAttempt: entry.attemptCount))
        entry.lastResult = result
        try? write(entry, to: destination)
    }

    private static func remove(_ entry: QueueEntry, queueDirectory: URL) {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let sessionId = UUID(uuidString: entry.sessionId) else { return }
        let destination = entryURL(sessionId: sessionId, queueDirectory: queueDirectory)
        guard let currentData = try? Data(contentsOf: destination),
              let current = try? JSONDecoder().decode(QueueEntry.self, from: currentData),
              current.payload == entry.payload else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    private static func entryURL(sessionId: UUID, queueDirectory: URL) -> URL {
        queueDirectory
            .appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("queue")
    }

    private static func prepareQueueDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private static func write(_ entry: QueueEntry, to destination: URL) throws {
        let data = try JSONEncoder().encode(entry)
        try data.write(to: destination, options: [.atomic])
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
#endif
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path)
    }

    private static func scheduleNextRetryIfNeeded(_ summary: RetrySummary) {
        guard summary.pendingCount > 0 else { return }
        let delay = max(60, summary.nextAttemptAt?.timeIntervalSinceNow ?? 60)
        SessionExportService.scheduleBackgroundExportRetry(after: delay)
    }
}
