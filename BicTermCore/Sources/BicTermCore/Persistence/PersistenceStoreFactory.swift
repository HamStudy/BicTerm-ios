import Foundation
import SwiftData

public enum PersistenceStoreFactory {
    public static func makeConfigurationStore(
        inMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) throws(PersistenceError) -> SwiftDataConfigurationStore {
        let schema = Schema([StoredConnection.self, StoredCoderServer.self])
        let container = try makeContainer(
            name: "BicTermConfigurations",
            schema: schema,
            inMemoryOnly: inMemoryOnly,
            storeURL: storeURL
        )
        return SwiftDataConfigurationStore(modelContainer: container)
    }

    public static func makeHostKeyStore(
        inMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) throws(PersistenceError) -> SwiftDataHostKeyStore {
        let schema = Schema([StoredHostKeyRecord.self])
        let container = try makeContainer(
            name: "BicTermHostKeys",
            schema: schema,
            inMemoryOnly: inMemoryOnly,
            storeURL: storeURL
        )
        return SwiftDataHostKeyStore(modelContainer: container)
    }

    public static func makeSessionSnapshotStore(
        inMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) throws(PersistenceError) -> SwiftDataSessionSnapshotStore {
        let schema = Schema([StoredSessionSnapshot.self])
        let container = try makeContainer(
            name: "BicTermSessionSnapshots",
            schema: schema,
            inMemoryOnly: inMemoryOnly,
            storeURL: storeURL
        )
        return SwiftDataSessionSnapshotStore(modelContainer: container)
    }

    private static func makeContainer(
        name: String,
        schema: Schema,
        inMemoryOnly: Bool,
        storeURL: URL?
    ) throws(PersistenceError) -> ModelContainer {
        do {
            let configuration: ModelConfiguration
            if inMemoryOnly {
                configuration = ModelConfiguration(
                    name,
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            } else {
                let url = try storeURL ?? defaultStoreURL(filename: "\(name).store")
                configuration = ModelConfiguration(name, schema: schema, url: url)
            }
            return try ModelContainer(for: schema, configurations: configuration)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw .initializationFailed(name)
        }
    }

    private static func defaultStoreURL(
        filename: String
    ) throws(PersistenceError) -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw .initializationFailed("application support directory unavailable")
        }

        let directory = applicationSupport.appendingPathComponent(
            "BicTerm",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .initializationFailed("unable to create application support directory")
        }
        return directory.appendingPathComponent(filename)
    }
}
