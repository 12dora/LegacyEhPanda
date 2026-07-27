//
//  DatabaseClient.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/02.
//

import SwiftUI
import Combine
import CoreData
import ComposableArchitecture

struct DatabaseClient {
    let prepareDatabase: () async -> Result<Void, AppError>
    let dropDatabase: () async -> Result<Void, AppError>
    private let saveContext: () -> Result<Void, AppError>
    private let materializedObjects: (NSManagedObjectContext, NSPredicate) -> [NSManagedObject]
}

extension DatabaseClient {
    static let live: Self = .init(
        prepareDatabase: {
            await withCheckedContinuation { continuation in
                PersistenceController.shared.prepare { result in
                    continuation.resume(returning: result)
                }
            }
        },
        dropDatabase: {
            await withCheckedContinuation { continuation in
                PersistenceController.shared.rebuild { result in
                    continuation.resume(returning: result)
                }
            }
        },
        saveContext: {
            let context = PersistenceController.shared.container.viewContext
            var result: Result<Void, AppError> = .success(())
            AppUtil.dispatchMainSync {
                result = DatabaseClient.save(context)
            }
            return result
        },
        materializedObjects: { context, predicate in
            var objects = [NSManagedObject]()
            for object in context.registeredObjects where !object.isFault {
                guard object.entity.attributesByName.keys.contains("gid"),
                      predicate.evaluate(with: object)
                else { continue }
                objects.append(object)
            }
            return objects
        }
    )
}

// MARK: Foundation
extension DatabaseClient {
    /// Saves a context, rolling its unsaved changes back on failure. Release builds must
    /// keep running: a disk, protection or store failure is reported, never fatal.
    @discardableResult
    fileprivate static func save(_ context: NSManagedObjectContext) -> Result<Void, AppError> {
        guard context.hasChanges else { return .success(()) }
        do {
            try context.save()
            return .success(())
        } catch {
            Logger.error("Failed in saving context.", context: ["error": error])
            context.rollback()
            return .failure(.databaseUnavailable("\(error)"))
        }
    }

    /// Non-throwing wrapper that lets the existing call sites keep ignoring the outcome.
    @discardableResult
    private func saveViewContext() -> Result<Void, AppError> {
        saveContext()
    }

    /// Distinguishes a failed fetch from an empty one, so that a caller never mistakes
    /// an unreadable store for absent rows and inserts a duplicate.
    private func batchFetchResult<MO: NSManagedObject>(
        entityType: MO.Type, fetchLimit: Int = 0, predicate: NSPredicate? = nil,
        findBeforeFetch: Bool = true, sortDescriptors: [NSSortDescriptor]? = nil
    ) -> Result<[MO], AppError> {
        var result: Result<[MO], AppError> = .success([])
        let context = PersistenceController.shared.container.viewContext
        AppUtil.dispatchMainSync {
            if findBeforeFetch, let predicate = predicate {
                if let objects = materializedObjects(context, predicate) as? [MO], !objects.isEmpty {
                    result = .success(objects)
                    return
                }
            }
            let request = NSFetchRequest<MO>(
                entityName: String(describing: entityType)
            )
            request.predicate = predicate
            request.fetchLimit = fetchLimit
            request.sortDescriptors = sortDescriptors
            do {
                result = .success(try context.fetch(request))
            } catch {
                Logger.error(
                    "Failed in fetching managed objects.",
                    context: ["entity": String(describing: entityType), "error": error]
                )
                result = .failure(.databaseUnavailable("\(error)"))
            }
        }
        return result
    }

    private func batchFetch<MO: NSManagedObject>(
        entityType: MO.Type, fetchLimit: Int = 0, predicate: NSPredicate? = nil,
        findBeforeFetch: Bool = true, sortDescriptors: [NSSortDescriptor]? = nil
    ) -> [MO] {
        let result = batchFetchResult(
            entityType: entityType, fetchLimit: fetchLimit, predicate: predicate,
            findBeforeFetch: findBeforeFetch, sortDescriptors: sortDescriptors
        )
        return (try? result.get()) ?? []
    }

    private func fetch<MO: NSManagedObject>(
        entityType: MO.Type, predicate: NSPredicate? = nil,
        findBeforeFetch: Bool = true, commitChanges: ((MO?) -> Void)? = nil
    ) -> MO? {
        let managedObject = batchFetch(
            entityType: entityType, fetchLimit: 1,
            predicate: predicate, findBeforeFetch: findBeforeFetch
        ).first
        commitChanges?(managedObject)
        return managedObject
    }

    /// Reconciles rows that an earlier fetch failure duplicated, and returns the survivor.
    /// Fetch order must never decide which row lives: the most populated row wins, ties are
    /// broken by object ID, every optional value the winner lacks is folded in from the
    /// losers, and optional dates keep their newest value. Only then are the losers deleted.
    fileprivate static func mergeDuplicates<MO: NSManagedObject>(
        _ storedMOs: [MO], in context: NSManagedObjectContext
    ) -> MO? {
        guard storedMOs.count > 1 else { return storedMOs.first }
        let optionalNames = storedMOs[0].entity.attributesByName.values
            .filter(\.isOptional).map(\.name)
        func populatedCount(_ managedObject: MO) -> Int {
            optionalNames.filter { managedObject.value(forKey: $0) != nil }.count
        }
        let ordered = storedMOs.sorted { lhs, rhs in
            let lhsCount = populatedCount(lhs)
            let rhsCount = populatedCount(rhs)
            guard lhsCount == rhsCount else { return lhsCount > rhsCount }
            return lhs.objectID.uriRepresentation().absoluteString
            < rhs.objectID.uriRepresentation().absoluteString
        }
        guard let winner = ordered.first else { return nil }
        for name in optionalNames {
            let values: [Any] = ordered.compactMap { $0.value(forKey: name) }
            guard let winningValue = winner.value(forKey: name) else {
                if let value = values.first {
                    winner.setValue(value, forKey: name)
                }
                continue
            }
            if let winningDate = winningValue as? Date,
               let latestDate = values.compactMap({ $0 as? Date }).max(), latestDate > winningDate {
                winner.setValue(latestDate, forKey: name)
            }
        }
        Logger.error(
            "Merging duplicated managed objects...",
            context: ["entity": winner.entity.name ?? "", "count": storedMOs.count]
        )
        ordered.dropFirst().forEach { context.delete($0) }
        return winner
    }

    /// Reports a failure rather than inserting when the store cannot be read: the logical
    /// row may well exist and would otherwise be durably duplicated.
    private func fetchOrCreate<MO: NSManagedObject>(
        entityType: MO.Type, predicate: NSPredicate? = nil,
        commitChanges: ((MO?) -> Void)? = nil
    ) -> Result<MO, AppError> {
        var result: Result<MO, AppError> = .failure(.databaseUnavailable(nil))
        AppUtil.dispatchMainSync {
            let context = PersistenceController.shared.container.viewContext
            switch batchFetchResult(entityType: entityType, predicate: predicate, findBeforeFetch: false) {
            case .success(let storedMOs):
                guard let storedMO = Self.mergeDuplicates(storedMOs, in: context) else {
                    let newMO = MO(context: context)
                    commitChanges?(newMO)
                    result = saveViewContext().map { _ in newMO }
                    return
                }
                commitChanges?(storedMO)
                result = storedMOs.count > 1 ? saveViewContext().map { _ in storedMO } : .success(storedMO)
            case .failure(let error):
                result = .failure(error)
            }
        }
        return result
    }

    @discardableResult
    private func batchUpdate<MO: NSManagedObject>(
        entityType: MO.Type, predicate: NSPredicate? = nil, commitChanges: ([MO]) -> Void
    ) -> Result<Void, AppError> {
        let result = batchFetchResult(
            entityType: entityType,
            predicate: predicate,
            findBeforeFetch: false
        )
        switch result {
        case .success(let storedMOs):
            commitChanges(storedMOs)
            return saveViewContext()
        case .failure(let error):
            return .failure(error)
        }
    }
    @discardableResult
    private func update<MO: NSManagedObject>(
        entityType: MO.Type, predicate: NSPredicate? = nil,
        createIfNil: Bool = false, commitChanges: (MO) -> Void
    ) -> Result<Void, AppError> {
        var result: Result<Void, AppError> = .success(())
        AppUtil.dispatchMainSync {
            let storedMO: MO?
            if createIfNil {
                switch fetchOrCreate(entityType: entityType, predicate: predicate) {
                case .success(let createdMO):
                    storedMO = createdMO
                case .failure(let error):
                    result = .failure(error)
                    return
                }
            } else {
                switch batchFetchResult(
                    entityType: entityType, fetchLimit: 1,
                    predicate: predicate, findBeforeFetch: true
                ) {
                case .success(let storedMOs):
                    storedMO = storedMOs.first
                case .failure(let error):
                    result = .failure(error)
                    return
                }
            }
            if let storedMO = storedMO {
                commitChanges(storedMO)
                result = saveViewContext()
            }
        }
        return result
    }
}

// MARK: GalleryIdentifiable
extension DatabaseClient {
    private func fetch<MO: GalleryIdentifiable>(
        entityType: MO.Type, gid: String,
        findBeforeFetch: Bool = true,
        commitChanges: ((MO?) -> Void)? = nil
    ) -> MO? {
        fetch(
            entityType: entityType, predicate: NSPredicate(format: "gid == %@", gid),
            findBeforeFetch: findBeforeFetch, commitChanges: commitChanges
        )
    }
    private func fetchOrCreate<MO: GalleryIdentifiable>(
        entityType: MO.Type, gid: String
    ) -> Result<MO, AppError> {
        fetchOrCreate(
            entityType: entityType,
            predicate: NSPredicate(format: "gid == %@", gid),
            commitChanges: { $0?.gid = gid }
        )
    }
    @discardableResult
    private func update<MO: GalleryIdentifiable>(
        entityType: MO.Type, gid: String,
        createIfNil: Bool = false,
        commitChanges: @escaping ((MO) -> Void)
    ) -> Result<Void, AppError> {
        var result: Result<Void, AppError> = .success(())
        AppUtil.dispatchMainSync {
            let storedMO: MO?
            if createIfNil {
                switch fetchOrCreate(entityType: entityType, gid: gid) {
                case .success(let createdMO):
                    storedMO = createdMO
                case .failure(let error):
                    result = .failure(error)
                    return
                }
            } else {
                switch batchFetchResult(
                    entityType: entityType, fetchLimit: 1,
                    predicate: NSPredicate(format: "gid == %@", gid),
                    findBeforeFetch: true
                ) {
                case .success(let storedMOs):
                    storedMO = storedMOs.first
                case .failure(let error):
                    result = .failure(error)
                    return
                }
            }
            if let storedMO = storedMO {
                commitChanges(storedMO)
                result = saveViewContext()
            }
        }
        return result
    }

    /// Fetch-or-insert for `GalleryMO` on the single serialized writer. `cacheGalleries`
    /// upserts the same entity there, and two contexts racing the same absent GID would
    /// each insert it, durably recreating the duplicates that M-52 removes.
    @discardableResult
    private func upsertGallery(
        gid: String, commitChanges: @escaping (GalleryMO) -> Void
    ) async -> Result<Void, AppError> {
        let context = PersistenceController.shared.backgroundContext
        return await context.perform {
            let request = NSFetchRequest<GalleryMO>(entityName: "GalleryMO")
            request.predicate = NSPredicate(format: "gid == %@", gid)
            let storedMOs: [GalleryMO]
            do {
                storedMOs = try context.fetch(request)
            } catch {
                Logger.error("Failed in fetching a gallery.", context: ["gid": gid, "error": error])
                return .failure(.databaseUnavailable("\(error)"))
            }
            let galleryMO: GalleryMO
            if let storedMO = Self.mergeDuplicates(storedMOs, in: context) {
                galleryMO = storedMO
            } else {
                galleryMO = GalleryMO(context: context)
                galleryMO.gid = gid
            }
            commitChanges(galleryMO)
            return Self.save(context)
        }
    }
}

// MARK: Fetch
extension DatabaseClient {
    func fetchGallery(gid: String) -> Gallery? {
        guard gid.isValidGID else { return nil }
        var entity: Gallery?
        AppUtil.dispatchMainSync {
            entity = fetch(entityType: GalleryMO.self, gid: gid)?.toEntity()
        }
        return entity
    }
    func fetchGalleryDetail(gid: String) -> GalleryDetail? {
        guard gid.isValidGID else { return nil }
        var entity: GalleryDetail?
        AppUtil.dispatchMainSync {
            entity = fetch(entityType: GalleryDetailMO.self, gid: gid)?.toEntity()
        }
        return entity
    }
    @MainActor func fetchAppEnv() -> AppEnv {
        (try? fetchOrCreate(entityType: AppEnvMO.self).get())?.toEntity() ?? Self.defaultAppEnv
    }
    func fetchAppEnvSynchronously() -> AppEnv {
        (try? fetchOrCreate(entityType: AppEnvMO.self).get())?.toEntity() ?? Self.defaultAppEnv
    }
    @MainActor func fetchGalleryState(gid: String) async -> GalleryState? {
        guard gid.isValidGID else { return nil }
        return (try? fetchOrCreate(entityType: GalleryStateMO.self, gid: gid).get())?.toEntity()
    }
    /// Reads history on a private queue, in batches, so that a long history never blocks
    /// the first screen. `keyword` filters in the store instead of walking a retained array,
    /// and the default limit bounds how many rows a single call can ever materialize; use
    /// `fetchOffset` to page beyond it.
    func fetchHistoryGalleries(
        fetchLimit: Int = 500, fetchOffset: Int = 0, keyword: String = ""
    ) async -> [Gallery] {
        let context = PersistenceController.shared.container.newBackgroundContext()
        return await context.perform {
            var predicates = [NSPredicate(format: "lastOpenDate != nil")]
            if !keyword.isEmpty {
                predicates.append(NSPredicate(format: "title CONTAINS[cd] %@", keyword))
            }
            let request = NSFetchRequest<GalleryMO>(entityName: "GalleryMO")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \GalleryMO.lastOpenDate, ascending: false)]
            request.fetchLimit = fetchLimit
            request.fetchOffset = fetchOffset
            request.fetchBatchSize = Self.fetchBatchSize
            do {
                return try context.fetch(request).map { $0.toEntity() }
            } catch {
                Logger.error("Failed in fetching history galleries.", context: ["error": error])
                return []
            }
        }
    }

    private static let fetchBatchSize = 50
    private static let defaultAppEnv = AppEnv(
        user: User(), setting: Setting(), searchFilter: Filter(), globalFilter: Filter(),
        watchedFilter: Filter(), tagTranslator: TagTranslator(),
        historyKeywords: [String](), quickSearchWords: [QuickSearchWord]()
    )
}
// MARK: FetchAccessor
extension DatabaseClient {
    func fetchFilterSynchronously(range: FilterRange) -> Filter {
        switch range {
        case .search:
            return fetchAppEnvSynchronously().searchFilter
        case .global:
            return fetchAppEnvSynchronously().globalFilter
        case .watched:
            return fetchAppEnvSynchronously().watchedFilter
        }
    }
    @MainActor func fetchQuickSearchWords() -> [QuickSearchWord] {
        fetchAppEnv().quickSearchWords
    }
}

// MARK: UpdateGallery
extension DatabaseClient {
    /// Routed through the serialized writer that `cacheGalleries` also uses, so the two
    /// can never both miss the same GID and insert it twice.
    @discardableResult
    func updateGallery(gid: String, key: String, value: Any?) async -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return await upsertGallery(gid: gid) { $0.setValue(value, forKeyPath: key) }
    }
    @discardableResult
    func updateLastOpenDate(gid: String, date: Date = .now) async -> Result<Void, AppError> {
        await updateGallery(gid: gid, key: "lastOpenDate", value: date)
    }
    @discardableResult
    func clearHistoryGalleries() async -> Result<Void, AppError> {
        let context = PersistenceController.shared.backgroundContext
        return await context.perform {
            let request = NSFetchRequest<GalleryMO>(entityName: "GalleryMO")
            request.predicate = NSPredicate(format: "lastOpenDate != nil")
            request.fetchBatchSize = Self.fetchBatchSize
            do {
                for galleryMO in try context.fetch(request) {
                    galleryMO.lastOpenDate = nil
                }
            } catch {
                Logger.error("Failed in clearing history galleries.", context: ["error": error])
                context.reset()
                return .failure(.databaseUnavailable("\(error)"))
            }
            let result = Self.save(context)
            context.reset()
            return result
        }
    }
    /// Upserts a whole page of results with a single indexed `IN` fetch and a single save
    /// on the serialized background context, instead of one main queue fetch per result.
    @discardableResult
    func cacheGalleries(_ galleries: [Gallery]) async -> Result<Void, AppError> {
        let galleries = galleries.filter { $0.id.isValidGID }
        guard !galleries.isEmpty else { return .success(()) }
        let context = PersistenceController.shared.backgroundContext
        return await context.perform {
            let request = NSFetchRequest<GalleryMO>(entityName: "GalleryMO")
            request.predicate = NSPredicate(format: "gid IN %@", galleries.map(\.gid))
            let storedMOs: [GalleryMO]
            do {
                storedMOs = try context.fetch(request)
            } catch {
                Logger.error("Failed in fetching cached galleries.", context: ["error": error])
                context.reset()
                return .failure(.databaseUnavailable("\(error)"))
            }
            var galleryMOs = [String: [GalleryMO]](grouping: storedMOs, by: \.gid)
                .compactMapValues { Self.mergeDuplicates($0, in: context) }
            for gallery in galleries {
                guard let galleryMO = galleryMOs[gallery.gid] else {
                    galleryMOs[gallery.gid] = gallery.toManagedObject(in: context)
                    continue
                }
                galleryMO.category = gallery.category.rawValue
                galleryMO.coverURL = gallery.coverURL
                galleryMO.galleryURL = gallery.galleryURL
                // galleryMO.lastOpenDate = gallery.lastOpenDate
                galleryMO.pageCount = Int64(gallery.pageCount)
                galleryMO.postedDate = gallery.postedDate
                galleryMO.rating = gallery.rating
                galleryMO.tags = gallery.tags.toData()
                galleryMO.title = gallery.title
                galleryMO.token = gallery.token
                if let uploader = gallery.uploader {
                    galleryMO.uploader = uploader
                }
            }
            let result = Self.save(context)
            context.reset()
            return result
        }
    }
}

// MARK: UpdateGalleryDetail
extension DatabaseClient {
    @discardableResult
    @MainActor func cacheGalleryDetail(_ detail: GalleryDetail) -> Result<Void, AppError> {
        guard detail.gid.isValidGID else { return .success(()) }
        return update(entityType: GalleryDetailMO.self, gid: detail.gid, createIfNil: true) { managedObject in
            managedObject.archiveURL = detail.archiveURL
            managedObject.category = detail.category.rawValue
            managedObject.coverURL = detail.coverURL
            managedObject.isFavorited = detail.isFavorited
            managedObject.visibility = detail.visibility.toData()
            managedObject.jpnTitle = detail.jpnTitle
            managedObject.language = detail.language.rawValue
            managedObject.favoritedCount = Int64(detail.favoritedCount)
            managedObject.pageCount = Int64(detail.pageCount)
            managedObject.parentURL = detail.parentURL
            managedObject.postedDate = detail.postedDate
            managedObject.rating = detail.rating
            managedObject.userRating = detail.userRating
            managedObject.ratingCount = Int64(detail.ratingCount)
            managedObject.sizeCount = detail.sizeCount
            managedObject.sizeType = detail.sizeType
            managedObject.title = detail.title
            managedObject.torrentCount = Int64(detail.torrentCount)
            managedObject.uploader = detail.uploader
        }
    }
}

// MARK: UpdateGalleryState
extension DatabaseClient {
    @discardableResult
    @MainActor func updateGalleryState(
        gid: String, commitChanges: @escaping (GalleryStateMO) -> Void
    ) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return update(
            entityType: GalleryStateMO.self, gid: gid, createIfNil: true,
            commitChanges: commitChanges
        )
    }
    @discardableResult
    @MainActor func updateGalleryState(gid: String, key: String, value: Any?) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid) { stateMO in
            stateMO.setValue(value, forKeyPath: key)
        }
    }
    @discardableResult
    @MainActor func updateGalleryTags(gid: String, tags: [GalleryTag]) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid, key: "tags", value: tags.toData())
    }
    @discardableResult
    @MainActor func updatePreviewConfig(gid: String, config: PreviewConfig) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid, key: "previewConfig", value: config.toData())
    }
    @discardableResult
    @MainActor func updateReadingProgress(gid: String, progress: Int) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid, key: "readingProgress", value: Int64(progress))
    }
    @discardableResult
    @MainActor func updateComments(gid: String, comments: [GalleryComment]) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid, key: "comments", value: comments.toData())
    }

    @discardableResult
    @MainActor func removeImageURLs(gid: String) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid) { galleryStateMO in
            galleryStateMO.imageURLs = nil
            galleryStateMO.previewURLs = nil
            galleryStateMO.thumbnailURLs = nil
            galleryStateMO.originalImageURLs = nil
        }
    }
    @discardableResult
    @MainActor func removeImageURLs() -> Result<Void, AppError> {
        batchUpdate(entityType: GalleryStateMO.self) { galleryStateMOs in
            galleryStateMOs.forEach { galleryStateMO in
                galleryStateMO.imageURLs = nil
                galleryStateMO.previewURLs = nil
                galleryStateMO.thumbnailURLs = nil
                galleryStateMO.originalImageURLs = nil
            }
        }
    }
    /// Startup cleanup: two predicate driven fetches and one background transaction,
    /// instead of materializing the whole history and saving once per expired row.
    @discardableResult
    func removeExpiredImageURLs() async -> Result<Void, AppError> {
        let expirationDate = Date().addingTimeInterval(-TimeInterval.oneWeek)
        let context = PersistenceController.shared.backgroundContext
        return await context.perform {
            let galleryRequest = NSFetchRequest<NSDictionary>(entityName: "GalleryMO")
            galleryRequest.resultType = .dictionaryResultType
            galleryRequest.propertiesToFetch = ["gid"]
            galleryRequest.predicate = NSPredicate(
                format: "lastOpenDate != nil AND lastOpenDate < %@", expirationDate as NSDate
            )
            let stateRequest = NSFetchRequest<GalleryStateMO>(entityName: "GalleryStateMO")
            stateRequest.fetchBatchSize = Self.fetchBatchSize
            do {
                let gids = try context.fetch(galleryRequest).compactMap { $0["gid"] as? String }
                guard !gids.isEmpty else { return .success(()) }
                stateRequest.predicate = NSPredicate(format: "gid IN %@", gids)
                for galleryStateMO in try context.fetch(stateRequest) {
                    galleryStateMO.imageURLs = nil
                    galleryStateMO.previewURLs = nil
                    galleryStateMO.thumbnailURLs = nil
                    galleryStateMO.originalImageURLs = nil
                }
            } catch {
                Logger.error("Failed in removing expired image URLs.", context: ["error": error])
                context.reset()
                return .failure(.databaseUnavailable("\(error)"))
            }
            let result = Self.save(context)
            context.reset()
            return result
        }
    }
    @discardableResult
    @MainActor func updateThumbnailURLs(gid: String, thumbnailURLs: [Int: URL]) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid) { galleryStateMO in
            update(gid: gid, storedData: &galleryStateMO.thumbnailURLs, new: thumbnailURLs)
        }
    }
    @discardableResult
    @MainActor func updateImageURLs(
        gid: String, imageURLs: [Int: URL], originalImageURLs: [Int: URL]
    ) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid) { galleryStateMO in
            update(gid: gid, storedData: &galleryStateMO.imageURLs, new: imageURLs)
            update(gid: gid, storedData: &galleryStateMO.originalImageURLs, new: originalImageURLs)
        }
    }
    @discardableResult
    @MainActor func updatePreviewURLs(gid: String, previewURLs: [Int: URL]) -> Result<Void, AppError> {
        guard gid.isValidGID else { return .success(()) }
        return updateGalleryState(gid: gid) { galleryStateMO in
            update(gid: gid, storedData: &galleryStateMO.previewURLs, new: previewURLs)
        }
    }

    private func update<T: Codable>(
        gid: String, storedData: inout Data?, new: [Int: T]
    ) {
        guard !new.isEmpty, gid.isValidGID else { return }

        if let storedDictionary = storedData?.toObject() as [Int: T]? {
            storedData = storedDictionary.merging(
                new, uniquingKeysWith: { _, new in new }
            ).toData()
        } else {
            storedData = new.toData()
        }
    }
}

// MARK: UpdateAppEnv
extension DatabaseClient {
    @discardableResult
    @MainActor func updateAppEnv(key: String, value: Any?) -> Result<Void, AppError> {
        update(
            entityType: AppEnvMO.self, createIfNil: true,
            commitChanges: { $0.setValue(value, forKeyPath: key) }
        )
    }
    @discardableResult
    @MainActor func updateSetting(_ setting: Setting) -> Result<Void, AppError> {
        updateAppEnv(key: "setting", value: setting.toData())
    }
    @discardableResult
    @MainActor func updateFilter(_ filter: Filter, range: FilterRange) -> Result<Void, AppError> {
        let key: String
        switch range {
        case .search:
            key = "searchFilter"
        case .global:
            key = "globalFilter"
        case .watched:
            key = "watchedFilter"
        }
        return updateAppEnv(key: key, value: filter.toData())
    }
    @discardableResult
    @MainActor func updateTagTranslator(_ tagTranslator: TagTranslator) -> Result<Void, AppError> {
        updateAppEnv(key: "tagTranslator", value: tagTranslator.toData())
    }
    @discardableResult
    @MainActor func updateUser(_ user: User) -> Result<Void, AppError> {
        updateAppEnv(key: "user", value: user.toData())
    }
    @discardableResult
    @MainActor func updateHistoryKeywords(_ keywords: [String]) -> Result<Void, AppError> {
        updateAppEnv(key: "historyKeywords", value: keywords.toData())
    }
    @discardableResult
    @MainActor func updateQuickSearchWords(_ words: [QuickSearchWord]) -> Result<Void, AppError> {
        updateAppEnv(key: "quickSearchWords", value: words.toData())
    }

    // Update User
    @discardableResult
    @MainActor func updateUserProperty(
        _ commitChanges: @escaping (inout User) -> Void
    ) -> Result<Void, AppError> {
        var user = fetchAppEnv().user
        commitChanges(&user)
        return updateUser(user)
    }
    @discardableResult
    @MainActor func updateGreeting(_ greeting: Greeting) -> Result<Void, AppError> {
        updateUserProperty { user in
            user.greeting = greeting
        }
    }
    @discardableResult
    @MainActor func updateGalleryFunds(galleryPoints: String, credits: String) -> Result<Void, AppError> {
        updateUserProperty { user in
            user.credits = credits
            user.galleryPoints = galleryPoints
        }
    }
}

// MARK: API
enum DatabaseClientKey: DependencyKey {
    static let liveValue = DatabaseClient.live
    static let previewValue = DatabaseClient.noop
    static let testValue = DatabaseClient.unimplemented
}

extension DependencyValues {
    var databaseClient: DatabaseClient {
        get { self[DatabaseClientKey.self] }
        set { self[DatabaseClientKey.self] = newValue }
    }
}

// MARK: Test
extension DatabaseClient {
    static let noop: Self = .init(
        prepareDatabase: { .success(()) },
        dropDatabase: { .success(()) },
        saveContext: { .success(()) },
        materializedObjects: { _, _ in .init() }
    )

    static let unimplemented: Self = .init(
        prepareDatabase: XCTestDynamicOverlay.unimplemented("\(Self.self).prepareDatabase"),
        dropDatabase: XCTestDynamicOverlay.unimplemented("\(Self.self).dropDatabase"),
        saveContext: XCTestDynamicOverlay.unimplemented("\(Self.self).saveContext"),
        materializedObjects: XCTestDynamicOverlay.unimplemented("\(Self.self).materializedObjects")
    )
}
