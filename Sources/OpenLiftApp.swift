import SwiftUI
import SwiftData

@main
struct OpenLiftApp: App {
    private static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Exercise.self,
            CycleSlot.self,
            CycleDay.self,
            RotationPoolEntry.self,
            RotationPool.self,
            CycleTemplate.self,
            RotationIndex.self,
            ActiveCycleInstance.self,
            Session.self,
            SetEntry.self,
            SessionSlotOverride.self
        ])
        return makeContainer(schema: schema)
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(Self.sharedModelContainer)
    }

    private static func makeContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            print("SwiftData container failed on first attempt: \(error)")
            quarantineLikelyCorruptStoreFiles()

            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                print("SwiftData container failed after store quarantine: \(error)")

                let inMemoryConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )

                do {
                    print("Falling back to in-memory SwiftData store for this launch.")
                    return try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
                } catch {
                    fatalError("Failed to create any SwiftData container: \(error)")
                }
            }
        }
    }

    private static func quarantineLikelyCorruptStoreFiles() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantineDirectory = appSupportURL.appendingPathComponent("CorruptStoreBackups/\(timestamp)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create corrupt store backup directory: \(error)")
            return
        }

        let candidateNames = ["default.store", "default.store-wal", "default.store-shm"]
        for name in candidateNames {
            let sourceURL = appSupportURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let destinationURL = quarantineDirectory.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                print("Failed moving \(name) to corrupt store backup: \(error)")
            }
        }
    }
}
