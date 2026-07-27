//
//  Persistence.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/04.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()
    let migrator = CoreDataMigrator()

    let container: NSPersistentCloudKitContainer
    /// A private queue context that serializes background writes, so that batch
    /// upserts and cleanups never block the main thread nor contend with each other.
    let backgroundContext: NSManagedObjectContext

    init() {
        let container = NSPersistentCloudKitContainer(name: "Model")
        let description = container.persistentStoreDescriptions.first
        description?.shouldInferMappingModelAutomatically = false
        description?.shouldMigrateStoreAutomatically = false
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let backgroundContext = container.newBackgroundContext()
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.container = container
        self.backgroundContext = backgroundContext
    }
}

// MARK: Preparation
extension PersistenceController {
    func prepare(completion: @escaping (Result<Void, AppError>) -> Void) {
        do {
           try loadPersistentStore(completion: completion)
        } catch {
            completion(.failure(Self.classify(error)))
        }
    }
    func rebuild(completion: @escaping (Result<Void, AppError>) -> Void) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            completion(.failure(.databaseCorrupted("PersistentContainer was not set up properly.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            backUpStore(at: storeURL)
            do {
                try NSPersistentStoreCoordinator.destroyStore(at: storeURL)
            } catch {
                completion(.failure(Self.classify(error)))
                return
            }
            container.loadPersistentStores { _, error in
                if let error = error {
                    completion(.failure(Self.classify(error)))
                    return
                }
                completion(.success(()))
            }
        }
    }
    private func loadPersistentStore(completion: @escaping (Result<Void, AppError>) -> Void) throws {
        try migrateStoreIfNeeded { result in
            switch result {
            case .success:
                container.loadPersistentStores { _, error in
                    if let error = error {
                        completion(.failure(Self.classify(error)))
                        return
                    }
                    completion(.success(()))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    private func migrateStoreIfNeeded(completion: @escaping (Result<Void, AppError>) -> Void) throws {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            throw AppError.databaseCorrupted("PersistentContainer was not set up properly.")
        }

        if try migrator.requiresMigration(at: storeURL, toVersion: try CoreDataMigrationVersion.current()) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try migrator.migrateStore(at: storeURL, toVersion: try CoreDataMigrationVersion.current())
                } catch {
                    completion(.failure(Self.classify(error)))
                    return
                }
                completion(.success(()))
            }
        } else {
            completion(.success(()))
        }
    }

    /// Best-effort copy of the SQLite store files, so that a confirmed corruption recovery
    /// never discards the only copy of the user's data. Only the newest backup is retained.
    private func backUpStore(at storeURL: URL) {
        let fileManager = FileManager.default
        let backupsURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        let destinationURL = backupsURL.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))", isDirectory: true
        )
        do {
            if fileManager.fileExists(atPath: backupsURL.path) {
                try fileManager.removeItem(at: backupsURL)
            }
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let sourceURL = URL(fileURLWithPath: storeURL.path + suffix)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                try fileManager.copyItem(
                    at: sourceURL, to: destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                )
            }
            Logger.info("Database was backed up before recovery.", context: ["url": destinationURL])
        } catch {
            Logger.error("Failed in backing up the database.", context: ["error": error])
        }
    }
}

// MARK: Classification
private extension PersistenceController {
    /// Preserves the underlying error in the log, then defers to the shared classification
    /// that `CoreDataMigrator` and the store coordinator helpers use as well.
    static func classify(_ error: Error) -> AppError {
        let nsError = error as NSError
        Logger.error("Persistent store error.", context: ["error": error, "userInfo": nsError.userInfo])
        return .database(error)
    }
}

// MARK: Definition
protocol ManagedObjectProtocol {
    associatedtype Entity
    func toEntity() -> Entity
}

protocol ManagedObjectConvertible {
    associatedtype ManagedObject: NSManagedObject, ManagedObjectProtocol

    @discardableResult
    func toManagedObject(in context: NSManagedObjectContext) -> ManagedObject
}

protocol GalleryIdentifiable: NSManagedObject {
    var gid: String { get set }
}
