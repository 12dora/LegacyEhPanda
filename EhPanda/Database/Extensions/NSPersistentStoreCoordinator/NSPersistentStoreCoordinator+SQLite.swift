//
//  NSPersistentStoreCoordinator+SQLite.swift
//  CoreDataMigration-Example
//
//  Created by William Boles on 15/09/2017.
//  Copyright © 2017 William Boles. All rights reserved.
//

import CoreData

extension NSPersistentStoreCoordinator {
    static func destroyStore(at storeURL: URL) throws {
        do {
            let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
        } catch let error {
            throw AppError.database(error, context: "Failed to destroy persistent store at \(storeURL).")
        }
    }
    static func replaceStore(at targetURL: URL, withStoreAt sourceURL: URL) throws {
        do {
            let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try persistentStoreCoordinator.replacePersistentStore(
                at: targetURL, destinationOptions: nil,
                withPersistentStoreFrom: sourceURL,
                sourceOptions: nil, ofType: NSSQLiteStoreType
            )
        } catch let error {
            let message = "Failed to replace persistent store at \(targetURL) with \(sourceURL)."
            throw AppError.database(error, context: message)
        }
    }

    static func metadata(at storeURL: URL) -> [String: Any]?  {
        try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: storeURL, options: nil
        )
    }

    func addPersistentStore(at storeURL: URL, options: [AnyHashable: Any]) throws -> NSPersistentStore {
        do {
            return try addPersistentStore(
                ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options
            )
        } catch {
            throw AppError.database(error, context: "Failed to add persistent store to coordinator.")
        }
    }
}
