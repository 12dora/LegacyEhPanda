//
//  CoreDataMigrationStep.swift
//  CoreDataMigration-Example
//
//  Created by William Boles on 11/09/2017.
//  Copyright © 2017 William Boles. All rights reserved.
//

import CoreData

struct CoreDataMigrationStep {
    let sourceModel: NSManagedObjectModel
    let destinationModel: NSManagedObjectModel
    let mappingModel: NSMappingModel

    init(sourceVersion: CoreDataMigrationVersion, destinationVersion: CoreDataMigrationVersion) throws {
        let sourceModel = try NSManagedObjectModel.managedObjectModel(forResource: sourceVersion.rawValue)
        let destinationModel = try NSManagedObjectModel.managedObjectModel(forResource: destinationVersion.rawValue)

        guard let mappingModel = CoreDataMigrationStep.mappingModel(
            fromSourceModel: sourceModel, toDestinationModel: destinationModel
        ) else {
            throw AppError.databaseCorrupted("Expected modal mapping not present.")
        }
        CoreDataMigrationStep.customize(
            mappingModel: mappingModel, fromSourceVersion: sourceVersion, toDestinationVersion: destinationVersion
        )

        self.sourceModel = sourceModel
        self.destinationModel = destinationModel
        self.mappingModel = mappingModel
    }

    private static func mappingModel(
        fromSourceModel sourceModel: NSManagedObjectModel,
        toDestinationModel destinationModel: NSManagedObjectModel
    ) -> NSMappingModel? {
        guard let customMapping = customMappingModel(
            fromSourceModel: sourceModel, toDestinationModel: destinationModel
        ) else {
            return inferredMappingModel(fromSourceModel: sourceModel, toDestinationModel: destinationModel)
        }
        return customMapping
    }
    private static func inferredMappingModel(
        fromSourceModel sourceModel: NSManagedObjectModel,
        toDestinationModel destinationModel: NSManagedObjectModel
    ) -> NSMappingModel? {
        try? NSMappingModel.inferredMappingModel(forSourceModel: sourceModel, destinationModel: destinationModel)
    }
    private static func customMappingModel(
        fromSourceModel sourceModel: NSManagedObjectModel,
        toDestinationModel destinationModel: NSManagedObjectModel
    ) -> NSMappingModel? {
        NSMappingModel(from: [Bundle.main], forSourceModel: sourceModel, destinationModel: destinationModel)
    }

    // MARK: Customization
    /// Repairs the attribute mappings that an inferred model cannot derive on its own.
    /// Both steps below drop a renamed/reshaped attribute otherwise, silently resetting
    /// user data on upgrade, and neither one owns a bundled mapping model.
    private static func customize(
        mappingModel: NSMappingModel,
        fromSourceVersion sourceVersion: CoreDataMigrationVersion,
        toDestinationVersion destinationVersion: CoreDataMigrationVersion
    ) {
        switch (sourceVersion, destinationVersion) {
        // `GalleryDetailMO.isVisible` became the `visibility` blob. An unmapped
        // `visibility` reads back as `.yes`, turning legacy hidden galleries visible.
        case (.version1, .version2):
            entityMapping(in: mappingModel, destinationEntityName: "GalleryDetailMO")?
                .entityMigrationPolicyClassName = "EhPanda.GalleryDetailMO1toGalleryDetailMO2MigrationPolicy"

        // The single `AppEnvMO.filter` became `globalFilter` and `searchFilter`. It applied
        // to every range back then, so it is carried into both to preserve the behavior.
        case (.version4, .version5):
            guard let appEnvMapping = entityMapping(in: mappingModel, destinationEntityName: "AppEnvMO")
            else { return }
            let destinationNames = ["globalFilter", "searchFilter"]
            var attributeMappings = (appEnvMapping.attributeMappings ?? []).filter {
                !destinationNames.contains($0.name ?? "")
            }
            attributeMappings += destinationNames.map { name -> NSPropertyMapping in
                let propertyMapping = NSPropertyMapping()
                propertyMapping.name = name
                propertyMapping.valueExpression = NSExpression(format: "FUNCTION($source, 'valueForKey:', 'filter')")
                return propertyMapping
            }
            appEnvMapping.attributeMappings = attributeMappings

        default:
            break
        }
    }
    private static func entityMapping(
        in mappingModel: NSMappingModel, destinationEntityName: String
    ) -> NSEntityMapping? {
        mappingModel.entityMappings?.first { $0.destinationEntityName == destinationEntityName }
    }
}

// MARK: Policies
/// Carries the Model 1 `isVisible` flag into the Model 2 `visibility` blob.
// swiftlint:disable:next type_name
final class GalleryDetailMO1toGalleryDetailMO2MigrationPolicy: NSEntityMigrationPolicy {
    override func createDestinationInstances(
        forSource sourceInstance: NSManagedObject, in mapping: NSEntityMapping, manager: NSMigrationManager
    ) throws {
        try super.createDestinationInstances(forSource: sourceInstance, in: mapping, manager: manager)
        guard let destinationGalleryDetailMO = manager.destinationInstances(
            forEntityMappingName: mapping.name, sourceInstances: [sourceInstance]
        ).first else {
            throw AppError.databaseCorrupted("Was expected a GalleryDetailMO.")
        }
        // Model 1 stored no reason, and `nil` materializes as visible, so an empty
        // reason is the closest lossless representation of a hidden legacy gallery.
        let isVisible = sourceInstance.value(forKey: "isVisible") as? Bool ?? true
        destinationGalleryDetailMO.setValue(
            isVisible ? nil : GalleryVisibility.no(reason: "").toData(), forKey: "visibility"
        )
    }
}
