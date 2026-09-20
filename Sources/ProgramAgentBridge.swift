import Foundation
import CryptoKit
import SwiftData

/// The URL is only a wakeup. Authority comes from an exact request staged inside
/// the private app container by a paired development host, never from URL data.
@MainActor
enum ProgramAgentBridge {
    struct Request: Codable {
        var protocolVersion = 1
        let id: UUID
        let action: String
        let expiresAt: Double
        var revision: Data? = nil
        var previewID: UUID? = nil
        var approvalToken: String? = nil
        var revisionSHA256: String? = nil
    }
    struct ExerciseReference: Codable { let id: UUID; let name: String; let setup: String }
    struct Receipt: Codable {
        let requestID: UUID
        let requestSHA256: String
        var status: String
        var message: String
        var starter: ProgramRevisionPackage? = nil
        var proposedRevision: ProgramRevisionPackage? = nil
        var exerciseReferences: [ExerciseReference]? = nil
        var changes: [String]? = nil
        var upcoming: [String]? = nil
        var blockedByDraft: Bool? = nil
        var previewID: UUID? = nil
        var approvalToken: String? = nil
        var revisionSHA256: String? = nil
        var sourceSHA256: String? = nil
        var expiresAt: Double? = nil
        var backupPath: String? = nil
        var appliedVersion: String? = nil
        var appliedTemplateID: UUID? = nil
    }
    struct PreviewRecord: Codable {
        let revision: Data
        let fingerprint: String
        let receipt: Receipt
    }
    static let maxRequestSize = 400_000
    static let lifetime: Double = 900
    static let markerPrefix = "openlift.agent-program-receipt."
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftAgentBridge", isDirectory: true)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func requestID(from url: URL) -> UUID? {
        guard url.scheme == "openlift-agent", url.host == "request", url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent), url.path == "/" + id.uuidString.lowercased()
        else { return nil }
        return id
    }
    /// Selection defaults are a cache, not commit evidence. Repair only the
    /// already-active exact template proven by an atomic bridge receipt, before
    /// legacy workout bootstrap can use an old cache after a process death.
    static func restoreCommittedSelectionCache(context: ModelContext) throws {
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>())
        guard cycles.count == 1, let cycle = cycles.first,
              let template = try context.fetch(FetchDescriptor<CycleTemplate>()).first(where: { $0.id == cycle.templateId }),
              let definition = ClusterProgramDefinition.embedded(in: template) else { return }
        let receipts = try context.fetch(FetchDescriptor<TrainingPreference>()).filter { $0.key.hasPrefix(markerPrefix) }
        guard receipts.contains(where: { marker in
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(marker.modeRawValue.utf8)) else { return false }
            return receipt.status == "applied" && receipt.appliedTemplateID == template.id && receipt.appliedVersion == definition.programVersionID
        }) else { return }
        UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
        UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
    }
    static func prepareDirectories() {
        // Creates transport destinations only; never scans or consumes requests.
        for group in ["inbox", "receipts", "previews"] {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(group), withIntermediateDirectories: true)
        }
    }
    static func handle(_ url: URL, context: ModelContext) {
        guard let id = requestID(from: url) else { return }
        do { _ = try process(id: id, context: context) }
        catch { print("OPENLIFT_AGENT_BRIDGE_RECEIPT_UNAVAILABLE") }
    }
    static func path(_ group: String, _ id: UUID, root: URL) -> URL {
        root.appendingPathComponent(group, isDirectory: true).appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    static func read(_ url: URL, limit: Int = maxRequestSize) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= limit else { throw ProgramImportService.Failure.invalid("Invalid or oversized bridge file.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ProgramImportService.Failure.invalid("Oversized bridge file.") }
        return data
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Called only for an explicit URL, never as startup/inbox scanning. Failures
    /// are terminal for this UUID. A later draft completion cannot retry an apply.
    @discardableResult
    static func process(id: UUID, context: ModelContext, root: URL = directory, now: Double = Date().timeIntervalSince1970,
                        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot,
                        save: (ModelContext) throws -> Void = { try $0.save() },
                        afterCommit: () throws -> Void = {}) throws -> Receipt? {
        let requestURL = path("inbox", id, root: root)
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return nil }
        // Never follow directory symlinks out of the app-owned bridge directory.
        for directory in [root] + ["inbox", "receipts", "previews"].map({ root.appendingPathComponent($0) }) {
            if FileManager.default.fileExists(atPath: directory.path),
               try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ProgramImportService.Failure.invalid("Bridge directory must not be a symbolic link.")
            }
        }
        let bytes = try read(requestURL)
        let digest = hash(bytes)
        let receiptURL = path("receipts", id, root: root)
        let key = markerPrefix + id.uuidString.lowercased()
        // Store marker is committed with the program, so it wins over an intent
        // receipt left by a process death between commit and response-file write.
        if let marker = try context.fetch(FetchDescriptor<TrainingPreference>()).first(where: { $0.key == key }) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(marker.modeRawValue.utf8))
            guard receipt.requestSHA256 == digest else { throw ProgramImportService.Failure.invalid("Request UUID collision; original receipt retained.") }
            try write(receipt, to: receiptURL)
            return receipt
        }
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            var receipt = try JSONDecoder().decode(Receipt.self, from: read(receiptURL, limit: 2_000_000))
            guard receipt.requestSHA256 == digest else { throw ProgramImportService.Failure.invalid("Request UUID collision; original receipt retained.") }
            if receipt.status == "interrupted" {
                // Main-actor execution never suspends. A later handler can see
                // an intent without a commit only after the prior run ended.
                receipt.status = "rejected"
                receipt.message = "Prior request interrupted before commit. No program change or automatic retry occurred."
                try write(receipt, to: receiptURL)
            }
            return receipt
        }
        var receipt = Receipt(requestID: id, requestSHA256: digest, status: "interrupted", message: "Request interrupted before a committed result. Submit a new request after checking status.")
        // Durable no-retry intent before any operation. A lost response cannot
        // leave an apply waiting to execute on a later launch.
        try write(receipt, to: receiptURL)
        do {
            let allowed: Set<String> = ["protocolVersion", "id", "action", "expiresAt", "revision", "previewID", "approvalToken", "revisionSHA256"]
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw ProgramImportService.Failure.invalid("Unknown command fields.") }
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            guard request.protocolVersion == 1, request.id == id else { throw ProgramImportService.Failure.invalid("Request ID or protocol mismatch.") }
            guard request.expiresAt.isFinite, request.expiresAt > now, request.expiresAt <= now + lifetime + 5 else {
                receipt.status = "expired"; receipt.message = "Request expired or expiry exceeds 15 minutes."
                try write(receipt, to: receiptURL); return receipt
            }
            guard !context.hasChanges else { throw ProgramImportService.Failure.invalid("Pending edits; no program changes made.") }
            switch request.action {
            case "status", "starter":
                guard request.revision == nil, request.previewID == nil, request.approvalToken == nil, request.revisionSHA256 == nil else { throw ProgramImportService.Failure.invalid("Unexpected status fields.") }
                let starter = try ProgramImportService.revisionStarter(context: context)
                let preview = try ProgramImportService.preview(starter, context: context)
                receipt.starter = starter; receipt.blockedByDraft = preview.blockedByDraft
                receipt.sourceSHA256 = hash(Data(preview.fingerprint.utf8))
                receipt.status = "ok"; receipt.message = "Current program exported; no program changes made."
            case "preview":
                guard let revision = request.revision, request.previewID == nil, request.approvalToken == nil, request.revisionSHA256 == nil else { throw ProgramImportService.Failure.invalid("Preview requires revision bytes only.") }
                let preview = try ProgramImportService.preview(ProgramImportService.decode(revision), context: context)
                receipt.status = "previewed"; receipt.message = "Preview only; no program changes made."
                receipt.proposedRevision = preview.package
                let catalog = try context.fetch(FetchDescriptor<Exercise>())
                receipt.exerciseReferences = preview.package.definition.exercises.values.compactMap { $0.resolve(in: catalog) }
                    .sorted { $0.id.uuidString < $1.id.uuidString }.map { .init(id: $0.id, name: $0.name, setup: $0.notes) }
                receipt.changes = preview.changes; receipt.upcoming = preview.upcoming; receipt.blockedByDraft = preview.blockedByDraft
                receipt.previewID = id; receipt.approvalToken = UUID().uuidString.lowercased()
                receipt.revisionSHA256 = hash(revision); receipt.sourceSHA256 = hash(Data(preview.fingerprint.utf8)); receipt.expiresAt = request.expiresAt
                try write(PreviewRecord(revision: revision, fingerprint: preview.fingerprint, receipt: receipt), to: path("previews", id, root: root))
            case "apply":
                guard request.revision == nil, let previewID = request.previewID, let token = request.approvalToken, let revisionHash = request.revisionSHA256 else { throw ProgramImportService.Failure.invalid("Apply requires exact preview ID, approval token and revision hash.") }
                let record = try JSONDecoder().decode(PreviewRecord.self, from: read(path("previews", previewID, root: root), limit: 2_000_000))
                guard record.receipt.previewID == previewID, record.receipt.approvalToken == token,
                      record.receipt.revisionSHA256 == revisionHash, hash(record.revision) == revisionHash,
                      let expiry = record.receipt.expiresAt, expiry > now else { throw ProgramImportService.Failure.invalid("Preview approval is invalid or expired; preview again.") }
                let package = try ProgramImportService.decode(record.revision)
                let preview = try ProgramImportService.preview(package, context: context)
                guard preview.fingerprint == record.fingerprint else { throw ProgramImportService.Failure.invalid("Source state changed since preview; preview again.") }
                guard !preview.blockedByDraft else { throw ProgramImportService.Failure.invalid("Finish the current workout before applying. Draft unchanged; this request will not retry.") }
                receipt.status = "applied"; receipt.message = "Approved revision applied with a verified backup."
                receipt.appliedVersion = package.definition.programVersionID; receipt.revisionSHA256 = revisionHash
                _ = try ProgramImportService.apply(preview, context: context, snapshot: snapshot, save: save, beforeSave: { template, backup in
                    receipt.appliedTemplateID = template.id
                    receipt.backupPath = backup.path
                    let encoded = try JSONEncoder().encode(receipt)
                    context.insert(TrainingPreference(key: key, modeRawValue: String(decoding: encoded, as: UTF8.self)))
                })
                // Test seam models process loss after the atomic store commit.
                try afterCommit()
            default: throw ProgramImportService.Failure.invalid("Unsupported bridge action.")
            }
        } catch {
            // Do not overwrite an atomically committed result after receipt I/O
            // failure or process interruption. Replay resolves from its marker.
            if (try? context.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == key })) == true { throw error }
            receipt.status = "rejected"; receipt.message = error.localizedDescription
        }
        try write(receipt, to: receiptURL)
        return receipt
    }
}
