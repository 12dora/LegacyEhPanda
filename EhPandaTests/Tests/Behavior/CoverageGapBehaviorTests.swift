//
//  CoverageGapBehaviorTests.swift
//  EhPandaTests
//

import Combine
import ComposableArchitecture
import Kanna
import UIKit
import XCTest
@testable import EhPanda

final class CoverageGapBehaviorTests: XCTestCase, TestHelper {
    private var tempURLs = [URL]()

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        DataRequest.setTransportForTests(nil)
        DownloadPersistenceTestSupport.setSaveFoldersHook(nil)
        await DownloadManagerTestSupport.installResetFolderSaveDrainHook(nil)
        await DownloadManagerTestSupport.installTransferScheduler(nil)
        let didReset = await DownloadManagerTestSupport.reset()
        XCTAssertTrue(didReset)
        guard didReset else {
            try await super.tearDown()
            return
        }
        DownloadPersistenceTestSupport.resetRoot()
        tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        tempURLs.removeAll()
        try await super.tearDown()
    }

    // MARK: - COV-01 Download persistence

    func testDownloadPersistenceRestoresRepairsPromotesAndDeletes() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var download = makeDownload(gid: "101", pageCount: 3)
        download.fileNames = [1: "page-1.png", 2: "page-2.png"]
        try await DownloadPersistenceTestSupport.commit(download)
        let galleryDirectory = DownloadPersistenceTestSupport.galleryDirectory(download.gid)
        try validPNGData().write(to: galleryDirectory.appendingPathComponent("page-1.png"))

        let pendingBeforeRepair = await DownloadPersistenceTestSupport.pendingIndices(
            gid: download.gid,
            pageCount: download.gallery.pageCount,
            fileNames: download.fileNames
        )
        XCTAssertEqual(pendingBeforeRepair, [2, 3])
        let existingFileNames = await DownloadPersistenceTestSupport.existingFileNames(
            gid: download.gid,
            fileNames: download.fileNames
        )
        XCTAssertEqual(existingFileNames, [1: "page-1.png"])

        let staged = root.appendingPathComponent("stage-page-2.png")
        try validPNGData().write(to: staged)
        let promoted = await DownloadPersistenceTestSupport.promote(
            staged: staged,
            gid: download.gid,
            index: 2,
            fileExtension: "png",
            generation: download.generation
        )
        XCTAssertEqual(promoted, .success("page-2.png"))
        let promotedPageURL = galleryDirectory.appendingPathComponent("page-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: promotedPageURL.path))

        let staleStage = root.appendingPathComponent("stage-stale.png")
        try validPNGData().write(to: staleStage)
        let stale = await DownloadPersistenceTestSupport.promote(
            staged: staleStage,
            gid: download.gid,
            index: 3,
            fileExtension: "png",
            generation: UUID()
        )
        guard case .failure(let staleMessage) = stale else {
            return XCTFail("Expected stale generation rejection")
        }
        XCTAssertTrue(staleMessage.contains("replaced"))
        let invalidPage = DownloadPersistenceTestSupport.validatePage(
            Data("<html>not an image</html>".utf8),
            statusCode: 200,
            mimeType: "text/html",
            expectedLength: 0
        )
        guard case .failure(let invalidPageMessage) = invalidPage else {
            return XCTFail("Expected corrupt page validation failure")
        }
        XCTAssertTrue(invalidPageMessage.contains("instead of an image"))

        var snapshot = await DownloadPersistenceTestSupport.load()
        XCTAssertEqual(snapshot.downloads.map(\.gid), ["101"])
        XCTAssertEqual(snapshot.downloads.first?.status, .preparing)

        try await DownloadPersistenceTestSupport.commit(makeDownload(gid: "202", pageCount: 1))
        try validPNGData().write(
            to: DownloadPersistenceTestSupport.galleryDirectory("202").appendingPathComponent("page-1.png")
        )
        try Data("not-json".utf8).write(to: DownloadPersistenceTestSupport.manifestURL("202"))
        try FileManager.default.createDirectory(
            at: DownloadPersistenceTestSupport.galleryDirectory("303"),
            withIntermediateDirectories: true
        )
        let orphanedPageURL = DownloadPersistenceTestSupport.galleryDirectory("303")
            .appendingPathComponent("page-1.png")
        try validPNGData().write(to: orphanedPageURL)
        snapshot = await DownloadPersistenceTestSupport.load()
        XCTAssertEqual(snapshot.quarantinedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadPersistenceTestSupport.quarantineURL().path))

        await DownloadPersistenceTestSupport.deletePageFiles(gid: download.gid)
        let pendingAfterPageDeletion = await DownloadPersistenceTestSupport.pendingIndices(
            gid: download.gid,
            pageCount: download.gallery.pageCount,
            fileNames: [1: "page-1.png", 2: "page-2.png"]
        )
        XCTAssertEqual(pendingAfterPageDeletion, [1, 2, 3])
        await DownloadPersistenceTestSupport.deleteGallery(gid: download.gid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: galleryDirectory.path))
    }

    func testDownloadPersistenceRestoresFoldersAndRunningStateAfterRelaunch() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        var first = makeDownload(gid: "301", pageCount: 2)
        first.status = .downloading
        try await DownloadPersistenceTestSupport.commit(first)
        await DownloadPersistenceTestSupport.saveFolders(["Zeta", "Default", "Alpha"])

        let snapshot = await DownloadPersistenceTestSupport.load()
        XCTAssertEqual(snapshot.folders, ["Alpha", "Default", "Zeta"])
        XCTAssertEqual(snapshot.downloads.first?.gid, "301")
        XCTAssertEqual(snapshot.downloads.first?.status, .preparing)
    }

    @MainActor
    func testDownloadManagerStartPausePersistsAndDeleteCleansFolder() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        await DownloadManagerTestSupport.reset()
        let manager = DownloadManager.shared
        let gallery = makeGallery(gid: "401", pageCount: 2, galleryURL: nil)
        var detail = GalleryDetail.empty
        detail.title = gallery.title
        detail.pageCount = gallery.pageCount

        await manager.start(gallery: gallery, detail: detail, previewConfig: .normal(rows: 4))
        XCTAssertEqual(DownloadManagerTestSupport.downloads().map(\.gid), ["401"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadPersistenceTestSupport.manifestURL("401").path))

        await manager.pause(gid: "401")
        XCTAssertEqual(DownloadManagerTestSupport.downloads().first?.status, .paused)
        let pausedSnapshot = await DownloadPersistenceTestSupport.load()
        XCTAssertEqual(pausedSnapshot.downloads.first?.status, .paused)

        await manager.delete(gid: "401")
        XCTAssertEqual(DownloadManagerTestSupport.downloads(), [])
        let deletedDirectory = DownloadPersistenceTestSupport.galleryDirectory("401")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDirectory.path))
    }

    @MainActor
    func testDownloadManagerDelegateCompletionRepairFoldersAndRelaunchRestore() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        await DownloadManagerTestSupport.reset()
        let manager = DownloadManager.shared
        let gallery = makeGallery(
            gid: "402",
            pageCount: 2,
            galleryURL: URL(string: "https://e-hentai.org/g/402/token/")!
        )
        var detail = GalleryDetail.empty
        detail.title = gallery.title
        detail.pageCount = gallery.pageCount

        await manager.start(gallery: gallery, detail: detail, previewConfig: .normal(rows: 4))
        await manager.pause(gid: gallery.gid)
        let generation = try XCTUnwrap(DownloadManagerTestSupport.downloads().first?.generation)
        manager.createFolder("Offline")
        manager.move(gid: gallery.gid, to: "Offline")
        XCTAssertEqual(DownloadManagerTestSupport.downloads().first?.folderName, "Offline")

        await DownloadManagerTestSupport.adoptExistingTransfers([
            .init(gid: gallery.gid, index: 1, generation: generation)
        ], restorationIsComplete: true)
        let corruptMessage = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 1,
            generation: generation,
            data: Data("<html>quota placeholder</html>".utf8),
            mimeType: "text/html"
        )
        XCTAssertTrue(corruptMessage?.contains("instead of an image") == true)
        XCTAssertEqual(DownloadManagerTestSupport.localPageURLs(gid: gallery.gid), [:])

        let pageData = validPNGData()
        await DownloadManagerTestSupport.adoptExistingTransfers([
            .init(gid: gallery.gid, index: 1, generation: generation),
            .init(gid: gallery.gid, index: 2, generation: generation)
        ], restorationIsComplete: true)
        let firstCompletion = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 1,
            generation: generation,
            data: pageData
        )
        XCTAssertNil(firstCompletion)
        let secondCompletion = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 2,
            generation: generation,
            data: pageData
        )
        XCTAssertNil(secondCompletion)
        await manager.resume(gid: gallery.gid)
        await DownloadManagerTestSupport.reconcile(gid: gallery.gid, generation: generation)
        let completed = try XCTUnwrap(DownloadManagerTestSupport.downloads().first)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertTrue(completed.canReadOffline)
        XCTAssertEqual(DownloadManagerTestSupport.localPageURLs(gid: gallery.gid).keys.sorted(), [1, 2])

        await manager.updateAllPages(gid: gallery.gid)
        let replacementGeneration = try XCTUnwrap(DownloadManagerTestSupport.downloads().first?.generation)
        XCTAssertNotEqual(replacementGeneration, generation)
        let staleMessage = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 1,
            generation: generation,
            data: pageData
        )
        XCTAssertEqual(staleMessage, "The download task was not active.")
        XCTAssertEqual(DownloadManagerTestSupport.localPageURLs(gid: gallery.gid), [:])

        await DownloadManagerTestSupport.adoptExistingTransfers([
            .init(gid: gallery.gid, index: 1, generation: replacementGeneration)
        ], restorationIsComplete: true)
        let replacementCompletion = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 1,
            generation: replacementGeneration,
            data: pageData
        )
        XCTAssertNil(replacementCompletion)
        await manager.repair(gid: gallery.gid)
        let repaired = try XCTUnwrap(DownloadManagerTestSupport.downloads().first)
        XCTAssertEqual(repaired.fileNames.keys.sorted(), [1])

        await DownloadManagerTestSupport.adoptExistingTransfers([
            .init(gid: gallery.gid, index: 2, generation: replacementGeneration)
        ], restorationIsComplete: true)
        let replacementSecondCompletion = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 2,
            generation: replacementGeneration,
            data: pageData
        )
        XCTAssertNil(replacementSecondCompletion)
        await manager.resume(gid: gallery.gid)
        await DownloadManagerTestSupport.reconcile(gid: gallery.gid, generation: replacementGeneration)

        await DownloadManagerTestSupport.reset()
        await DownloadManagerTestSupport.restore()
        let restored = try XCTUnwrap(DownloadManagerTestSupport.downloads().first)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.folderName, "Offline")
        XCTAssertEqual(DownloadManagerTestSupport.localPageURLs(gid: gallery.gid).keys.sorted(), [1, 2])

        await manager.delete(gid: gallery.gid)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DownloadPersistenceTestSupport.galleryDirectory(gallery.gid).path
        ))
    }

    @MainActor
    func testResetWaitsForOrderedFolderSaveChainBeforeCleanup() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        await DownloadManagerTestSupport.reset()

        let gate = FolderSaveSequenceProbe(heldFolderName: "Alpha")
        DownloadPersistenceTestSupport.setSaveFoldersHook { folders in
            gate.recordAndBlockIfNeeded(folders)
        }
        DownloadManager.shared.createFolder("Alpha")
        await gate.waitForSnapshots(1)
        DownloadManager.shared.createFolder("Beta")

        let resetResult = AsyncResultProbe<Bool>()
        let resetDrain = AsyncSignalProbe()
        await DownloadManagerTestSupport.installResetFolderSaveDrainHook {
            resetDrain.signal()
        }
        Task { @MainActor in
            await resetResult.finish(DownloadManagerTestSupport.reset())
        }
        await resetDrain.wait()
        let prematureResetResult = await resetResult.value()
        XCTAssertNil(prematureResetResult)

        gate.releaseHeldSnapshot()
        await gate.waitForSnapshots(2)
        let completedResetResult = await resetResult.waitForValue()
        XCTAssertTrue(completedResetResult)
        DownloadPersistenceTestSupport.setSaveFoldersHook(nil)
        await DownloadManagerTestSupport.installResetFolderSaveDrainHook(nil)
        XCTAssertFalse(DownloadManagerTestSupport.hasFolderSaveTask())
        XCTAssertEqual(DownloadManagerTestSupport.folders(), [DownloadManager.defaultFolder])
        let snapshot = await DownloadPersistenceTestSupport.load()
        XCTAssertEqual(snapshot.folders, ["Alpha", "Beta", DownloadManager.defaultFolder])
    }

    @MainActor
    func testDownloadManagerAdoptsOnlyCurrentTransferInventoryAfterRestore() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root)
        await DownloadManagerTestSupport.reset()
        let manager = DownloadManager.shared
        let gallery = makeGallery(gid: "403", pageCount: 3, galleryURL: URL(string: "https://e-hentai.org/g/403/t/")!)
        var detail = GalleryDetail.empty
        detail.title = gallery.title
        detail.pageCount = gallery.pageCount

        await manager.start(gallery: gallery, detail: detail, previewConfig: .normal(rows: 4))
        await manager.pause(gid: gallery.gid)
        let generation = try XCTUnwrap(DownloadManagerTestSupport.downloads().first?.generation)
        try await DownloadPersistenceTestSupport.commit(try XCTUnwrap(DownloadManagerTestSupport.downloads().first))

        await DownloadManagerTestSupport.reset()
        await DownloadManagerTestSupport.restore()
        let currentComplete = DownloadManagerTestSupport.TransferInventory(
            gid: gallery.gid, index: 1, generation: generation
        )
        let staleComplete = DownloadManagerTestSupport.TransferInventory(
            gid: gallery.gid, index: 2, generation: UUID()
        )
        let foreignComplete = DownloadManagerTestSupport.TransferInventory(
            gid: "foreign", index: 1, generation: generation
        )
        let malformedComplete = DownloadManagerTestSupport.TransferInventory(taskDescription: nil)
        await DownloadManagerTestSupport.adoptExistingTransfers(
            [currentComplete, staleComplete, foreignComplete, malformedComplete],
            restorationIsComplete: true
        )
        XCTAssertFalse(currentComplete.isCancelled)
        XCTAssertTrue(staleComplete.isCancelled)
        XCTAssertTrue(foreignComplete.isCancelled)
        XCTAssertTrue(malformedComplete.isCancelled)
        XCTAssertEqual(DownloadManagerTestSupport.activeTransferIndices(gid: gallery.gid), [1])

        let currentIncomplete = DownloadManagerTestSupport.TransferInventory(
            gid: gallery.gid, index: 2, generation: generation
        )
        let staleIncomplete = DownloadManagerTestSupport.TransferInventory(
            gid: gallery.gid, index: 3, generation: UUID()
        )
        let foreignIncomplete = DownloadManagerTestSupport.TransferInventory(
            gid: "foreign", index: 2, generation: generation
        )
        let malformedIncomplete = DownloadManagerTestSupport.TransferInventory(taskDescription: "bad")
        await DownloadManagerTestSupport.adoptExistingTransfers(
            [currentIncomplete, staleIncomplete, foreignIncomplete, malformedIncomplete],
            restorationIsComplete: false
        )
        XCTAssertFalse(currentIncomplete.isCancelled)
        XCTAssertTrue(staleIncomplete.isCancelled)
        XCTAssertFalse(foreignIncomplete.isCancelled)
        XCTAssertTrue(malformedIncomplete.isCancelled)
        XCTAssertEqual(DownloadManagerTestSupport.activeTransferIndices(gid: gallery.gid), [1, 2])

        let adoptedCompletion = await DownloadManagerTestSupport.completeDownloadedPage(
            gid: gallery.gid,
            index: 1,
            generation: generation,
            data: validPNGData(seed: 3)
        )
        XCTAssertNil(adoptedCompletion)
        await manager.resume(gid: gallery.gid)
        await DownloadManagerTestSupport.reconcile(gid: gallery.gid, generation: generation)
        let restored = try XCTUnwrap(DownloadManagerTestSupport.downloads().first)
        XCTAssertEqual(restored.fileNames.keys.sorted(), [1])
        XCTAssertEqual(restored.status, .failed)
    }

    // MARK: - COV-02 Reader cache and reducer integration

    func testReaderImageCacheAliasesEvictsAndPipelineRejectsInvalidLocalData() async throws {
        let root = makeTempDirectory()
        let cache = ReaderImageDataCache(rootURL: root)
        let urlA = try XCTUnwrap(URL(string: "https://a.hath.network/h/abc-123-320-480-jpg?dl=1&kept=yes"))
        let urlB = try XCTUnwrap(URL(string: "https://b.hath.network/h/abc-123-320-480-jpg?download=1&kept=yes"))
        let data = validPNGData()

        try await cache.store(data, forKey: urlA.readerImageCacheKeys[0])
        let aliasedData = await cache.data(forKeys: urlB.readerImageCacheKeys)
        XCTAssertEqual(aliasedData, data)
        await cache.removeAllMemory()
        let diskData = await cache.data(forKeys: urlB.readerImageCacheKeys)
        XCTAssertEqual(diskData, data)
        await cache.removeData(forKeys: urlA.readerImageCacheKeys)
        let evictedData = await cache.data(forKeys: urlB.readerImageCacheKeys)
        XCTAssertNil(evictedData)

        let pipeline = ReaderImagePipeline(dataCache: cache)
        let validFile = root.appendingPathComponent("page.png")
        try data.write(to: validFile)
        let asset = try await pipeline.asset(for: validFile)
        XCTAssertEqual(asset.data, data)

        let invalidFile = root.appendingPathComponent("invalid.bin")
        try Data("html login page".utf8).write(to: invalidFile)
        do {
            _ = try await pipeline.asset(for: invalidFile)
            XCTFail("Expected invalid local reader data to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .parseFailed)
        }

        XCTAssertTrue(validJPEGData().looksLikeReaderImageData)
        XCTAssertTrue(validGIFData().looksLikeReaderImageData)
        XCTAssertTrue(Data("RIFFxxxxWEBPVP8 ".utf8).looksLikeReaderImageData)
        XCTAssertFalse(Data("<html>not image</html>".utf8).looksLikeReaderImageData)
    }

    func testReaderImagePipelineRemoteTransferCoalescesAliasesCancelsAndDecodesFormats() async throws {
        let root = makeTempDirectory()
        let cache = ReaderImageDataCache(rootURL: root)
        let aliasA = URL(string: "https://a.hath.network/h/shared-4096-64-64-png?dl=1&kept=yes")!
        let aliasB = URL(string: "https://b.hath.network/h/shared-4096-64-64-png?download=1&kept=yes")!
        let payload = validPNGData(seed: 1)
        let coalescedGate = GatedReaderDownloader(data: payload)
        let pipeline = ReaderImagePipeline(dataCache: cache, downloader: coalescedGate.downloader())

        let first = Task { try await pipeline.asset(for: aliasA) }
        let second = Task { try await pipeline.asset(for: aliasB) }
        await coalescedGate.waitForStarts(1)
        await pipeline.waitForWaiterCountForTests(for: aliasA, count: 2)
        await coalescedGate.releaseAll()
        let remoteAssets = try await [first.value, second.value]
        XCTAssertEqual(remoteAssets.map(\.data), [payload, payload])
        let coalescedStarts = await coalescedGate.startedURLs()
        let coalescedCancellations = await coalescedGate.cancellationCount()
        XCTAssertEqual(coalescedStarts, [aliasA])
        XCTAssertEqual(coalescedCancellations, 0)

        let oneCancelA = URL(string: "https://c.hath.network/h/one-cancel-4096-64-64-png?dl=1")!
        let oneCancelB = URL(string: "https://d.hath.network/h/one-cancel-4096-64-64-png?download=1")!
        let oneCancelGate = GatedReaderDownloader(data: payload)
        let oneCancelPipeline = ReaderImagePipeline(
            dataCache: ReaderImageDataCache(rootURL: makeTempDirectory()),
            downloader: oneCancelGate.downloader()
        )
        let firstWaiter = Task { try await oneCancelPipeline.asset(for: oneCancelA) }
        let secondWaiter = Task { try await oneCancelPipeline.asset(for: oneCancelB) }
        await oneCancelGate.waitForStarts(1)
        await oneCancelPipeline.waitForWaiterCountForTests(for: oneCancelA, count: 2)
        firstWaiter.cancel()
        await oneCancelPipeline.waitForWaiterCountForTests(for: oneCancelA, count: 1)
        let oneCancelWaitersAfterCancel = await oneCancelPipeline.waiterCountForTests(for: oneCancelA)
        let oneCancelCancellationsBeforeRelease = await oneCancelGate.cancellationCount()
        XCTAssertEqual(oneCancelWaitersAfterCancel, 1)
        XCTAssertEqual(oneCancelCancellationsBeforeRelease, 0)
        await oneCancelGate.releaseAll()
        do {
            _ = try await firstWaiter.value
            XCTFail("Expected cancelled waiter to throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let secondWaiterAsset = try await secondWaiter.value
        XCTAssertEqual(secondWaiterAsset.data, payload)
        let oneCancelCancellationsAfterRelease = await oneCancelGate.cancellationCount()
        XCTAssertEqual(oneCancelCancellationsAfterRelease, 0)

        let allCancelA = URL(string: "https://e.hath.network/h/all-cancel-4096-64-64-png?dl=1")!
        let allCancelB = URL(string: "https://f.hath.network/h/all-cancel-4096-64-64-png?download=1")!
        let allCancelGate = GatedReaderDownloader(data: payload)
        let allCancelPipeline = ReaderImagePipeline(
            dataCache: ReaderImageDataCache(rootURL: makeTempDirectory()),
            downloader: allCancelGate.downloader()
        )
        let cancelA = Task { try await allCancelPipeline.asset(for: allCancelA) }
        let cancelB = Task { try await allCancelPipeline.asset(for: allCancelB) }
        await allCancelGate.waitForStarts(1)
        await allCancelPipeline.waitForWaiterCountForTests(for: allCancelA, count: 2)
        cancelA.cancel()
        cancelB.cancel()
        await allCancelGate.waitForCancellations(1)
        _ = await cancelA.result
        _ = await cancelB.result
        let allCancelCancellations = await allCancelGate.cancellationCount()
        XCTAssertEqual(allCancelCancellations, 1)

        let cachedOnly = ReaderImagePipeline(
            dataCache: cache,
            downloader: ReaderImageDownloader { _, _, _ in throw AppError.networkingFailed }
        )
        let cachedAliasAsset = try await cachedOnly.asset(for: aliasB)
        XCTAssertEqual(cachedAliasAsset.data, payload)

        let formatFixtures = [
            ("jpg", validJPEGData()),
            ("gif", validGIFData()),
            ("webp", validWebPData())
        ]
        for (format, data) in formatFixtures {
            let formatRoot = makeTempDirectory()
            let formatCache = ReaderImageDataCache(rootURL: formatRoot)
            let sourceURL = URL(string: "https://format.test/h/\(format)-\(data.count)-64-64-\(format)")!
            let formatPipeline = ReaderImagePipeline(
                dataCache: formatCache,
                downloader: ReaderImageDownloader { _, _, _ in
                    data
                }
            )
            let remoteFormatAsset = try await formatPipeline.asset(for: sourceURL)
            XCTAssertEqual(remoteFormatAsset.data, data)
            await formatPipeline.removeAllMemory()
            let cachedOnly = ReaderImagePipeline(
                dataCache: formatCache,
                downloader: ReaderImageDownloader { _, _, _ in throw AppError.networkingFailed }
            )
            let cachedFormatAsset = try await cachedOnly.asset(for: sourceURL)
            XCTAssertEqual(cachedFormatAsset.data, data)
        }

        let corruptURL = URL(string: "https://format.test/h/corrupt-5-64-64-png")!
        let corruptPipeline = ReaderImagePipeline(
            dataCache: ReaderImageDataCache(rootURL: makeTempDirectory()),
            downloader: ReaderImageDownloader { _, _, _ in
                Data("html".utf8)
            }
        )
        do {
            _ = try await corruptPipeline.asset(for: corruptURL)
            XCTFail("Expected corrupt remote data to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .parseFailed)
        }

        let signedCorruptFixtures = [
            ("png", Data(validPNGData().prefix(32))),
            ("jpg", Data(validJPEGData().prefix(12))),
            ("webp", Data("RIFF0000WEBPVP8 ".utf8))
        ]
        for (format, corruptData) in signedCorruptFixtures {
            XCTAssertTrue(corruptData.looksLikeReaderImageData)
            let corruptCache = ReaderImageDataCache(rootURL: makeTempDirectory())
            let corruptSignedURL = URL(string: "https://format.test/h/corrupt-\(format)-4096-64-64-\(format)")!
            var corruptStarts = 0
            let signedCorruptPipeline = ReaderImagePipeline(
                dataCache: corruptCache,
                downloader: ReaderImageDownloader { _, _, _ in
                    corruptStarts += 1
                    return corruptData
                }
            )
            do {
                _ = try await signedCorruptPipeline.asset(for: corruptSignedURL)
                XCTFail("Expected signed but truncated \(format) data to fail")
            } catch {
                XCTAssertEqual(error as? AppError, .parseFailed)
            }
            XCTAssertEqual(corruptStarts, 1)

            let cachedOnlyPipeline = ReaderImagePipeline(
                dataCache: corruptCache,
                downloader: ReaderImageDownloader { _, _, _ in throw AppError.networkingFailed }
            )
            do {
                _ = try await cachedOnlyPipeline.asset(for: corruptSignedURL)
                XCTFail("Expected rejected \(format) data not to be cached")
            } catch {
                XCTAssertEqual(error as? AppError, .networkingFailed)
            }
        }
    }

    @MainActor
    func testReadingReducerFetchImageDrivesRealPipelineImageClientAndCompletionState() async throws {
        let url = URL(string: "https://reader.test/h/reducer-4096-64-64-png")!
        let data = validPNGData(seed: 2)
        let image = try decodedImage(from: data)
        var requestedURLs = [URL]()
        let pipeline = ReaderImagePipeline(
            dataCache: ReaderImageDataCache(rootURL: makeTempDirectory()),
            downloader: ReaderImageDownloader { requestedURL, _, _ in
                requestedURLs.append(requestedURL)
                return data
            }
        )
        let store = TestStore(
            initialState: ReadingReducer.State(),
            reducer: { ReadingReducer() },
            withDependencies: {
                $0.hapticsClient = .noop
                $0.imageClient = ImageClient(
                    prefetchImages: { _ in },
                    saveImageToPhotoLibrary: { _, _ in false },
                    downloadImage: { _ in .failure(AppError.notFound) },
                    retrieveImage: { _ in .failure(AppError.notFound) },
                    loadReaderImageAsset: { requestedURL, _ in
                        do {
                            return .success(try await pipeline.asset(for: requestedURL))
                        } catch {
                            return .failure(error)
                        }
                    }
                )
            }
        )

        await store.send(ReadingReducer.Action.fetchImage(.share(false), url))
        await store.receive({ action in
            guard case .fetchImageDone(.share(false), url, .success(let asset)) = action else { return false }
            return asset.data == data
        })
        var routedImage: UIImage?
        await store.receive({ action in
            guard case .setNavigation(.share(.image(let image))) = action else { return false }
            routedImage = image
            return true
        }, assert: {
            $0.route = .share(.image(routedImage ?? image))
        })
        XCTAssertEqual(requestedURLs, [url])
    }

    // MARK: - COV-03 Requests

    func testDataRequestCancellationRetryAndStatusMapping() async throws {
        let gatedURL = URL(string: "https://requests.test/gated")!
        let prestartGate = GatedDataRequestTransport(url: gatedURL, data: Data("suppressed".utf8))
        DataRequest.setTransportForTests { url in
            prestartGate.publisher(for: url)
        }
        let gatedTask = Task {
            await DataRequest(url: gatedURL, requiresBencodedPayload: false).response()
        }
        await prestartGate.waitForScheduledStarts(1)
        gatedTask.cancel()
        let gatedResult = await gatedTask.value
        XCTAssertEqual(gatedResult.failure, .networkingFailed)
        prestartGate.open()
        let prestartSubscriptions = prestartGate.subscriptionCount()
        let prestartScheduledStarts = prestartGate.scheduledStartCount()
        let prestartCancellations = prestartGate.cancellationCount()
        let prestartStarts = prestartGate.startCount()
        XCTAssertEqual(prestartSubscriptions, 1)
        XCTAssertEqual(prestartScheduledStarts, 1)
        XCTAssertEqual(prestartCancellations, 1)
        XCTAssertEqual(prestartStarts, 0)

        let controlURL = URL(string: "https://requests.test/gated-control")!
        let controlGate = GatedDataRequestTransport(url: controlURL, data: Data("control".utf8))
        DataRequest.setTransportForTests { url in
            controlGate.publisher(for: url)
        }
        let controlTask = Task {
            await DataRequest(url: controlURL, requiresBencodedPayload: false).response()
        }
        await controlGate.waitForScheduledStarts(1)
        XCTAssertEqual(controlGate.startCount(), 0)
        controlGate.open()
        let controlData = try await controlTask.value.get()
        XCTAssertEqual(controlData, Data("control".utf8))
        XCTAssertEqual(controlGate.subscriptionCount(), 1)
        XCTAssertEqual(controlGate.scheduledStartCount(), 1)
        XCTAssertEqual(controlGate.cancellationCount(), 0)
        XCTAssertEqual(controlGate.startCount(), 1)
        DataRequest.setTransportForTests(nil)

        let unsubscribedURL = URL(string: "https://requests.test/unsubscribed")!
        var unsubscribedAttempts = 0
        StubURLProtocol.stub(unsubscribedURL) { _ in
            unsubscribedAttempts += 1
            return .immediate(status: 200, data: Data())
        }
        _ = DataRequest(url: unsubscribedURL, requiresBencodedPayload: false).publisher
        XCTAssertEqual(unsubscribedAttempts, 0)

        let slowURL = URL(string: "https://requests.test/slow")!
        let didStart = expectation(description: "slow request started")
        StubURLProtocol.stub(slowURL) { _ in
            didStart.fulfill()
            return .delayed(status: 200, data: Data("ok".utf8), delay: 1)
        }
        let slowTask = Task {
            await DataRequest(url: slowURL, requiresBencodedPayload: false).response()
        }
        await fulfillment(of: [didStart], timeout: 2)
        slowTask.cancel()
        let slowResult = await slowTask.value
        XCTAssertEqual(slowResult.failure, .networkingFailed)

        let retryURL = URL(string: "https://requests.test/retry")!
        var attempts = 0
        StubURLProtocol.stub(retryURL) { _ in
            attempts += 1
            if attempts < 4 {
                throw URLError(.timedOut)
            }
            return .immediate(status: 200, data: Data("d4:infodee".utf8))
        }
        let retryData = try (await DataRequest(url: retryURL).response()).get()
        XCTAssertEqual(retryData, Data("d4:infodee".utf8))
        XCTAssertEqual(attempts, 4)

        let serverErrorURL = URL(string: "https://requests.test/server-error")!
        StubURLProtocol.stub(serverErrorURL) { _ in .immediate(status: 500, data: Data()) }
        let serverError = await DataRequest(url: serverErrorURL).response()
        XCTAssertEqual(serverError.failure, .networkingFailed)

        let missingURL = URL(string: "https://requests.test/missing")!
        StubURLProtocol.stub(missingURL) { _ in .immediate(status: 404, data: Data()) }
        let missing = await DataRequest(url: missingURL).response()
        XCTAssertEqual(missing.failure, .notFound)
    }

    func testImageURLBatchSkipsFailuresRespectsConcurrencyAndCancels() async throws {
        let delayedURLs = [
            1: URL(string: "https://requests.test/delayed-thumb/1")!,
            2: URL(string: "https://requests.test/delayed-thumb/2")!,
            3: URL(string: "https://requests.test/delayed-thumb/3")!
        ]
        let lock = NSLock()
        var active = 0
        var maxActive = 0
        for (index, url) in delayedURLs {
            StubURLProtocol.stub(url) { _ in
                lock.lock()
                active += 1
                maxActive = max(maxActive, active)
                lock.unlock()
                return .delayed(status: 200, data: Self.normalImageHTML(index), delay: 0.05, onDelivered: {
                    lock.lock()
                    active -= 1
                    lock.unlock()
                })
            }
        }
        let delayedBatch = try (await GalleryNormalImageURLsRequest(
            thumbnailURLs: delayedURLs,
            maxConcurrentRequests: 2
        ).response()).get()
        XCTAssertEqual(delayedBatch.0.keys.sorted(), [1, 2, 3])
        XCTAssertLessThanOrEqual(maxActive, 2)

        let cancelURL = URL(string: "https://requests.test/cancel-thumb/1")!
        let cancelStarted = expectation(description: "batch request started")
        let cancelStopped = expectation(description: "batch request transport stopped")
        let noValue = expectation(description: "cancelled batch emits no value")
        noValue.isInverted = true
        StubURLProtocol.stub(cancelURL) { _ in
            cancelStarted.fulfill()
            return .delayed(status: 200, data: Self.normalImageHTML(1), delay: 0.2, onStopped: {
                cancelStopped.fulfill()
            })
        }
        let cancellable = GalleryNormalImageURLsRequest(thumbnailURLs: [1: cancelURL])
            .publisher
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in noValue.fulfill() })
        await fulfillment(of: [cancelStarted], timeout: 2)
        cancellable.cancel()
        await fulfillment(of: [cancelStopped], timeout: 2)
        await fulfillment(of: [noValue], timeout: 0.3)
        XCTAssertEqual(StubURLProtocol.stopCount(for: cancelURL), 1)

        let urls = [
            1: URL(string: "https://requests.test/thumb/1")!,
            2: URL(string: "https://requests.test/thumb/2")!,
            3: URL(string: "https://requests.test/thumb/3")!
        ]
        StubURLProtocol.stub(urls[1]!) { _ in .immediate(status: 200, data: Self.normalImageHTML(1)) }
        StubURLProtocol.stub(urls[2]!) { _ in .immediate(status: 404, data: Data()) }
        StubURLProtocol.stub(urls[3]!) { _ in .immediate(status: 200, data: Self.normalImageHTML(3)) }

        let batch = try (await GalleryNormalImageURLsRequest(
            thumbnailURLs: urls,
            maxConcurrentRequests: 2
        ).response()).get()
        XCTAssertEqual(batch.0.keys.sorted(), [1, 3])
        XCTAssertEqual(batch.0[1]?.absoluteString, "https://images.test/1.jpg")
        XCTAssertEqual(batch.0[3]?.absoluteString, "https://images.test/3.jpg")
    }

    func testRefetchAndMPVRequestVariants() async throws {
        let storedThumbnailURL = URL(string: "https://requests.test/refetch-thumb")!
        let renewedThumbnailURL = storedThumbnailURL.appending(queryItems: [.skipServerIdentifier: "skip-refetch"])
        StubURLProtocol.stub(storedThumbnailURL) { _ in
            .immediate(status: 200, data: Self.normalImageHTML(4, skipServerIdentifier: "skip-refetch"))
        }
        StubURLProtocol.stub(renewedThumbnailURL) { _ in
            .immediate(status: 200, data: Self.normalImageHTML(4, imageHost: "renewed.test"))
        }
        let refetch = try (await GalleryNormalImageURLRefetchRequest(
            index: 4,
            pageNum: 0,
            galleryURL: URL(string: "https://e-hentai.org/g/4/token/")!,
            thumbnailURL: storedThumbnailURL,
            storedImageURL: URL(string: "https://images.test/4.jpg")!
        ).response()).get()
        XCTAssertEqual(refetch.0[4]?.absoluteString, "https://renewed.test/4.jpg")
        XCTAssertEqual(refetch.1?.statusCode, 200)

        StubURLProtocol.stub(Defaults.URL.api) { request in
            let json = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(json["nl"] as? String, "skip-old")
            return .immediate(
                status: 200,
                data: Data(#"{"i":"https://images.test/mpv.jpg","lf":"fullimg.php?gid=1&page=1","s":42}"#.utf8)
            )
        }
        let mpv = try (await GalleryMPVImageURLRequest(
            gid: 1,
            index: 1,
            mpvKey: "mpv",
            mpvImageKey: "img",
            skipServerIdentifier: "skip-old"
        ).response()).get()
        XCTAssertEqual(mpv.0.absoluteString, "https://images.test/mpv.jpg")
        XCTAssertEqual(mpv.1?.absoluteString, "https://e-hentai.org/fullimg.php?gid=1&page=1")
        XCTAssertEqual(mpv.2, "42")

        StubURLProtocol.stub(Defaults.URL.api) { _ in
            .immediate(status: 200, data: Data(#"{"i":"https://images.test/mpv2.jpg","s":"next-server"}"#.utf8))
        }
        let stringSkip = try (await GalleryMPVImageURLRequest(
            gid: 1,
            index: 2,
            mpvKey: "mpv",
            mpvImageKey: "img2",
            skipServerIdentifier: nil
        ).response()).get()
        XCTAssertEqual(stringSkip.2, "next-server")

        StubURLProtocol.stub(Defaults.URL.api) { _ in
            .immediate(status: 200, data: Data(#"{"error":"bad image"}"#.utf8))
        }
        let mpvError = await GalleryMPVImageURLRequest(
            gid: 1,
            index: 3,
            mpvKey: "mpv",
            mpvImageKey: "img3",
            skipServerIdentifier: nil
        ).response()
        XCTAssertEqual(mpvError.failure, .parseFailed)
    }

    // MARK: - COV-04 Parser variants

    func testParserNegativeAndSiteVariantBranches() throws {
        let archive = try Parser.parseGalleryArchive(doc: html("""
        <table><tr>
        <td><p>Original</p><p>1.2 GiB</p><p>Free</p></td>
        <td><p>1280x</p><p>N/A</p></td>
        <td><p>broken</p><p>9 GP</p></td>
        </tr></table>
        """))
        XCTAssertEqual(archive.hathArchives.map(\.resolution), [.original, .x1280])
        XCTAssertEqual(archive.hathArchives.map(\.isValid), [true, false])

        let torrents = try Parser.parseGalleryTorrents(doc: html("""
        <form><table>
        <tr><td>Posted: 2024-01-02 03:04</td><td>Size: 12 MiB</td></tr>
        <tr><td>Seeds: 5</td><td>Peers: 6</td><td>Downloads: 7</td><td>Uploader: tester</td></tr>
        <tr><td><a href="https://e-hentai.org/torrent/abcdef.torrent">fixture.torrent</a></td></tr>
        </table></form>
        <form><table><tr><td>Posted: bad</td></tr></table></form>
        """))
        XCTAssertEqual(torrents.count, 1)
        XCTAssertEqual(torrents[0].hash, "abcdef")
        XCTAssertEqual(torrents[0].magnetURL, "magnet:?xt=urn:btih:abcdef")

        XCTAssertEqual(try Parser.parseCurrentFunds(doc: html("<p>1,234 GP [?] 5,678 Credits</p>")).0, "1234")
        XCTAssertThrowsError(try Parser.parseCurrentFunds(doc: html("<p>No balance here</p>"))) {
            XCTAssertEqual($0 as? AppError, .parseFailed)
        }
        XCTAssertThrowsError(try Parser.parseUserInfo(doc: html("<table class='ipbtable'><tr></tr></table>"))) {
            XCTAssertEqual($0 as? AppError, .parseFailed)
        }
        XCTAssertThrowsError(try Parser.parseAPIKey(doc: html("<script>var apikey = '';</script>"))) {
            XCTAssertEqual($0 as? AppError, .parseFailed)
        }

        let comments = try Parser.parseComments(doc: html("""
        <div id="cdiv"><div class="c1">
        <div class="c3">Posted on 02 January 2024, 03:04 by: <a href="/uploader/tester">tester</a></div>
        <div class="c4 nosel"><a id="vote_up_1" style="color:blue"></a><a onclick="edit_comment(1)"></a></div>
        <div class="c5 nosel"><span>+12</span></div>
        <div class="c6" id="comment_99">hello &amp; world</div>
        </div></div>
        """))
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].author, "tester")
        XCTAssertTrue(comments[0].votedUp)
        XCTAssertEqual(comments[0].score, "+12")
        let variantComments = try Parser.parseComments(doc: html("""
        <div id="cdiv"><div class="c1">
        <div class="c3">Posted on
        02&nbsp;January&nbsp;2024,
        03:04 by: <a href="/uploader/tester">tester</a></div>
        <div class="c4 nosel"><a id="vote_up_1" style="color:blue"></a><a onclick="edit_comment(1)"></a></div>
        <div class="c5 nosel"><span>+12</span></div>
        <div class="c6" id="comment_99">hello &amp; world</div>
        </div></div>
        """))
        XCTAssertEqual(variantComments.map(\.commentDate), comments.map(\.commentDate))
        XCTAssertEqual(variantComments.map(\.author), comments.map(\.author))
        XCTAssertEqual(variantComments[0].contents.map(\.text), comments[0].contents.map(\.text))

        let ordinaryDetailHTML = try htmlString(filename: .galleryDetail)
        let dashVariantDetailHTML = ordinaryDetailHTML.replacingOccurrences(
            of: "Showing 1 - 40 of 156 images",
            with: "Showing 1 — 40 of 156 images"
        )
        let ordinaryDetail = try Parser.parseGalleryDetail(doc: html(ordinaryDetailHTML), gid: "2725078")
        let dashVariantDetail = try Parser.parseGalleryDetail(doc: html(dashVariantDetailHTML), gid: "2725078")
        XCTAssertEqual(dashVariantDetail.0.pageCount, ordinaryDetail.0.pageCount)
        XCTAssertEqual(dashVariantDetail.1.previewConfig, ordinaryDetail.1.previewConfig)

        let favoriteCategories = try Parser.parseFavoriteCategories(doc: html("""
        <div id="favsel">
        <input name="favorite_0" value="Reading">
        <input name="favorite_1" value="Queued">
        <input name="favorite_9" value="Archive">
        <input name="all" value="Ignored">
        </div>
        """))
        XCTAssertEqual(favoriteCategories, [-1: "Ignored", 0: "Reading", 1: "Queued", 9: "Archive"])
        XCTAssertThrowsError(try Parser.parseFavoriteCategories(doc: html("<div id='favsel'></div>"))) {
            XCTAssertEqual($0 as? AppError, .parseFailed)
        }

        let profile = try Parser.parseProfileIndex(doc: html("""
        <select name="profile_set">
        <option value="1">Default</option>
        <option value="7">EhPanda</option>
        </select>
        """))
        XCTAssertEqual(profile, VerifyEhProfileResponse(profileValue: 7, isProfileNotFound: false))
        let missingProfile = try Parser.parseProfileIndex(doc: html("""
        <select name="profile_set"><option value="1">Default</option></select>
        """))
        XCTAssertEqual(missingProfile, VerifyEhProfileResponse(profileValue: nil, isProfileNotFound: true))

        let favoritedTimeSort = Parser.parseFavoritesSortOrder(
            doc: try html("<div class='ido'><div><div><a>Use Posted</a></div></div></div>")
        )
        XCTAssertEqual(favoritedTimeSort, .favoritedTime)
        let lastUpdateSort = Parser.parseFavoritesSortOrder(
            doc: try html("<div class='ido'><div><div><a>Use Favorited</a></div></div></div>")
        )
        XCTAssertEqual(lastUpdateSort, .lastUpdateTime)

        XCTAssertThrowsError(try Parser.parseGalleryDetail(
            doc: html("<div class='d'><p>This gallery has been removed.</p></div>"),
            gid: "404"
        )) {
            XCTAssertEqual($0 as? AppError, .expunged("This gallery has been removed."))
        }

        XCTAssertThrowsError(try Parser.parseGalleries(doc: html("<html><body>unexpected layout</body></html>"))) {
            XCTAssertEqual($0 as? AppError, .parseFailed)
        }
        XCTAssertEqual(try Parser.parseGalleries(doc: html("<div class='ido'>No hits found</div>")), [])
    }

    // MARK: - COV-05 Vertical smoke

    @MainActor
    func testVerticalFixtureParserReaderDownloadPersistenceRelaunchOfflineRead() async throws {
        let root = makeTempDirectory()
        DownloadPersistenceTestSupport.useRoot(root.appendingPathComponent("downloads", isDirectory: true))
        let cache = ReaderImageDataCache(rootURL: root.appendingPathComponent("reader-cache", isDirectory: true))
        let pipeline = ReaderImagePipeline(dataCache: cache)
        await DownloadManagerTestSupport.reset()

        let galleryURL = URL(string: "https://e-hentai.org/g/501/token/")!
        let detailPageURL = URLUtil.detailPage(url: galleryURL, pageNum: 0)
        let thumbnailURLs = [
            1: URL(string: "https://requests.test/vertical/thumb/1")!,
            2: URL(string: "https://requests.test/vertical/thumb/2")!
        ]
        StubURLProtocol.stub(detailPageURL) { _ in
            .immediate(status: 200, data: Self.thumbnailPageHTML(thumbnailURLs: thumbnailURLs))
        }
        StubURLProtocol.stub(thumbnailURLs[1]!) { _ in
            .immediate(status: 200, data: Self.normalImageHTML(1, imageHost: "vertical.test"))
        }
        StubURLProtocol.stub(thumbnailURLs[2]!) { _ in
            .immediate(status: 200, data: Self.normalImageHTML(2, imageHost: "vertical.test"))
        }

        let requestedThumbnails = try (await ThumbnailURLsRequest(
            galleryURL: galleryURL,
            pageNum: 0
        ).response()).get()
        XCTAssertEqual(requestedThumbnails, thumbnailURLs)
        let imageURLs = try (await GalleryNormalImageURLsRequest(
            thumbnailURLs: requestedThumbnails,
            maxConcurrentRequests: 2
        ).response()).get()
        XCTAssertEqual(imageURLs.0[1]?.absoluteString, "https://vertical.test/1.jpg")
        XCTAssertEqual(imageURLs.0[2]?.absoluteString, "https://vertical.test/2.jpg")

        let gallery = makeGallery(gid: "501", pageCount: 2, galleryURL: galleryURL)
        var detail = GalleryDetail.empty
        detail.title = gallery.title
        detail.pageCount = gallery.pageCount
        DownloadManager.shared.createFolder("Vertical")
        var scheduledTransfers = [(requestURL: URL, taskDescription: String)]()
        let scheduledExpectation = expectation(description: "manager schedules parsed image URLs")
        scheduledExpectation.expectedFulfillmentCount = 2
        DownloadManagerTestSupport.installTransferScheduler { request, taskDescription in
            guard let requestURL = request.url else { return }
            scheduledTransfers.append((requestURL, taskDescription))
            scheduledExpectation.fulfill()
        }
        await DownloadManager.shared.start(
            gallery: gallery,
            detail: detail,
            previewConfig: .normal(rows: 4)
        )
        let generation = try XCTUnwrap(DownloadManagerTestSupport.downloads().first?.generation)
        DownloadManager.shared.move(gid: gallery.gid, to: "Vertical")
        await fulfillment(of: [scheduledExpectation], timeout: 4)
        XCTAssertEqual(
            scheduledTransfers.map(\.requestURL).sorted { $0.absoluteString < $1.absoluteString },
            [try XCTUnwrap(imageURLs.0[1]), try XCTUnwrap(imageURLs.0[2])]
        )

        let pagePayloads = [
            1: validPNGData(seed: 11),
            2: validPNGData(seed: 12)
        ]
        let arbitraryURLMessage = await DownloadManagerTestSupport.completeScheduledTransfer(
            taskDescription: scheduledTransfers[0].taskDescription,
            responseURL: URL(string: "https://unrequested.test/not-scheduled.png")!,
            data: pagePayloads[1]!
        )
        XCTAssertEqual(arbitraryURLMessage, "The download response URL was not scheduled.")

        let scheduledByURL = Dictionary(
            uniqueKeysWithValues: scheduledTransfers.map { ($0.requestURL, $0.taskDescription) }
        )
        let firstCompletion = await DownloadManagerTestSupport.completeScheduledTransfer(
            taskDescription: try XCTUnwrap(scheduledByURL[try XCTUnwrap(imageURLs.0[1])]),
            responseURL: try XCTUnwrap(imageURLs.0[1]),
            data: pagePayloads[1]!
        )
        let secondCompletion = await DownloadManagerTestSupport.completeScheduledTransfer(
            taskDescription: try XCTUnwrap(scheduledByURL[try XCTUnwrap(imageURLs.0[2])]),
            responseURL: try XCTUnwrap(imageURLs.0[2]),
            data: pagePayloads[2]!
        )
        XCTAssertNil(firstCompletion)
        XCTAssertNil(secondCompletion)
        await DownloadManagerTestSupport.reconcile(gid: gallery.gid, generation: generation)

        await DownloadManagerTestSupport.reset()
        await DownloadManagerTestSupport.restore()
        let restored = try XCTUnwrap(DownloadManagerTestSupport.downloads().first)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.folderName, "Vertical")
        let offlineURLs = DownloadManagerTestSupport.localPageURLs(gid: gallery.gid)
        XCTAssertEqual(offlineURLs.keys.sorted(), [1, 2])

        let firstAsset = try await pipeline.asset(for: try XCTUnwrap(offlineURLs[1]))
        let secondAsset = try await pipeline.asset(for: try XCTUnwrap(offlineURLs[2]))
        XCTAssertEqual(firstAsset.data, pagePayloads[1])
        XCTAssertEqual(secondAsset.data, pagePayloads[2])
        XCTAssertNotEqual(firstAsset.data, secondAsset.data)
        XCTAssertGreaterThan(firstAsset.image.size.width, 0)
        XCTAssertGreaterThan(secondAsset.image.size.width, 0)
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EhPandaTests-\(UUID().uuidString)", isDirectory: true)
        tempURLs.append(url)
        return url
    }

    private func makeDownload(gid: String, pageCount: Int) -> GalleryDownload {
        let gallery = makeGallery(
            gid: gid,
            pageCount: pageCount,
            galleryURL: URL(string: "https://e-hentai.org/g/\(gid)/token/")!
        )
        var detail = GalleryDetail.empty
        detail.title = gallery.title
        detail.pageCount = pageCount
        return GalleryDownload(gallery: gallery, detail: detail, previewConfig: .normal(rows: 4))
    }

    private func makeGallery(gid: String, pageCount: Int, galleryURL: URL?) -> Gallery {
        Gallery(
            gid: gid,
            token: "token",
            title: "Fixture \(gid)",
            rating: 4,
            tags: [],
            category: .doujinshi,
            uploader: "tester",
            pageCount: pageCount,
            postedDate: Date(timeIntervalSince1970: 1_700_000_000),
            coverURL: nil,
            galleryURL: galleryURL
        )
    }

    private func validPNGData(seed: Int = 0) -> Data {
        let size = CGSize(width: 512, height: 512)
        var data = UIGraphicsImageRenderer(size: size).pngData { context in
            let base = CGFloat((seed * 37) % 255) / 255
            UIColor(red: base, green: 0.35, blue: 0.75, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for offset in stride(from: 0, through: 512, by: 4) {
                let component = CGFloat((offset + seed * 13) % 255) / 255
                UIColor(red: component, green: 0.8 - component / 2, blue: 0.2, alpha: 1).setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: CGFloat(offset)))
                path.addLine(to: CGPoint(x: CGFloat(offset), y: 0))
                path.lineWidth = 1
                path.stroke()
            }
        }
        return data
    }

    private func validJPEGData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.8) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    private func validGIFData() -> Data {
        Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
            0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
            0x01, 0x00, 0x3B
        ])
    }

    private func validWebPData() -> Data {
        Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
            ?? Data("RIFFxxxxWEBPVP8 ".utf8)
    }

    private func decodedImage(from data: Data) throws -> UIImage {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw AppError.parseFailed
        }
        return image
    }

    private func html(_ string: String) throws -> HTMLDocument {
        try Kanna.HTML(html: string, encoding: .utf8)
    }

    private static func normalImageHTML(
        _ index: Int,
        imageHost: String = "images.test",
        skipServerIdentifier: String = "skip-next"
    ) -> Data {
        Data("""
        <div id="i3"><img src="https://\(imageHost)/\(index).jpg"></div>
        <div id="i7"><a href="https://images.test/original-\(index).jpg">Original</a></div>
        <div id="i6"><a id="loadfail" onclick="nl('\(skipServerIdentifier)')">skip</a></div>
        """.utf8)
    }

    private static func thumbnailPageHTML(thumbnailURLs: [Int: URL]) -> Data {
        let links = thumbnailURLs.keys.sorted().map { index in
            """
            <a href="\(thumbnailURLs[index]!.absoluteString)">
              <div class="gdtm" title="Page \(index): page-\(index)"
                   style="background:url(https://thumbs.test/\(index).jpg)"></div>
            </a>
            """
        }.joined(separator: "\n")
        return Data("<div id=\"gdt\">\(links)</div>".utf8)
    }

    private static func jsonBody(from request: URLRequest) -> [String: Any]? {
        let data: Data?
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = Data(bytes)
        } else {
            data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

private final class FolderSaveSequenceProbe: @unchecked Sendable {
    private let heldFolderName: String
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var snapshots = [[String]]()
    private var snapshotWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var hasBlockedHeldSnapshot = false

    init(heldFolderName: String) {
        self.heldFolderName = heldFolderName
    }

    func recordAndBlockIfNeeded(_ folders: [String]) {
        let shouldBlock: Bool
        lock.lock()
        snapshots.append(folders)
        shouldBlock = folders.contains(heldFolderName) && !folders.contains("Beta") && !hasBlockedHeldSnapshot
        if shouldBlock {
            hasBlockedHeldSnapshot = true
        }
        let ready = snapshotWaiters.filter { snapshots.count >= $0.count }.map(\.continuation)
        snapshotWaiters.removeAll { snapshots.count >= $0.count }
        lock.unlock()
        ready.forEach { $0.resume() }
        if shouldBlock {
            semaphore.wait()
        }
    }

    func waitForSnapshots(_ count: Int) async {
        if hasSnapshots(count) { return }
        await withCheckedContinuation { continuation in
            enqueueSnapshotWaiter(count: count, continuation: continuation)
        }
    }

    private func hasSnapshots(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count >= count
    }

    private func enqueueSnapshotWaiter(count: Int, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if snapshots.count >= count {
            continuation.resume()
            return
        }
        snapshotWaiters.append((count, continuation))
    }

    func releaseHeldSnapshot() {
        semaphore.signal()
    }
}

private final class AsyncSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        lock.lock()
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        if signaled() { return }
        await withCheckedContinuation { continuation in
            enqueueWaiter(continuation)
        }
    }

    private func signaled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignaled
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if isSignaled {
            continuation.resume()
            return
        }
        waiters.append(continuation)
    }
}

private actor AsyncResultProbe<Value> {
    private var stored: Value?
    private var waiters = [CheckedContinuation<Value, Never>]()

    func finish(_ value: Value) {
        stored = value
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }

    func value() -> Value? {
        stored
    }

    func waitForValue() async -> Value {
        if let stored { return stored }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor GatedReaderDownloader {
    private let data: Data
    private var starts = [URL]()
    private var releaseContinuations = [CheckedContinuation<Void, Never>]()
    private var startWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var cancellationWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var cancellations = 0

    init(data: Data) {
        self.data = data
    }

    nonisolated func downloader() -> ReaderImageDownloader {
        ReaderImageDownloader { url, _, _ in
            await self.recordStart(url)
            try await self.waitForRelease()
            return await self.dataValue()
        }
    }

    func waitForStarts(_ count: Int) async {
        guard starts.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitForCancellations(_ count: Int) async {
        guard cancellations < count else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func startedURLs() -> [URL] {
        starts
    }

    func cancellationCount() -> Int {
        cancellations
    }

    private func dataValue() -> Data {
        data
    }

    private func recordStart(_ url: URL) {
        starts.append(url)
        let ready = startWaiters.filter { starts.count >= $0.count }
        startWaiters.removeAll { starts.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func waitForRelease() async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.recordCancellationAndRelease() }
        }
    }

    private func recordCancellationAndRelease() {
        cancellations += 1
        let releaseContinuations = releaseContinuations
        self.releaseContinuations.removeAll()
        releaseContinuations.forEach { $0.resume() }
        let ready = cancellationWaiters.filter { cancellations >= $0.count }
        cancellationWaiters.removeAll { cancellations >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class GatedDataRequestTransport: @unchecked Sendable {
    typealias Output = URLSession.DataTaskPublisher.Output

    private let url: URL
    private let data: Data
    private let statusCode: Int
    private let lock = NSLock()
    private var subscriptions = 0
    private var cancellations = 0
    private var starts = 0
    private var scheduledStarts = 0
    private var isOpen = false
    private var scheduledStartWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var openWaiters = [CheckedContinuation<Void, Never>]()

    init(url: URL, data: Data, statusCode: Int = 200) {
        self.url = url
        self.data = data
        self.statusCode = statusCode
    }

    func publisher(for requestedURL: URL) -> AnyPublisher<Output, URLError> {
        GatedDataRequestPublisher(gate: self, url: requestedURL).eraseToAnyPublisher()
    }

    func waitForScheduledStarts(_ count: Int) async {
        lock.lock()
        if scheduledStarts >= count {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            scheduledStartWaiters.append((count, continuation))
            lock.unlock()
        }
    }

    func subscriptionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions
    }

    func scheduledStartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledStarts
    }

    func cancellationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func startCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    fileprivate func waitUntilOpen() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
            lock.unlock()
        }
    }

    fileprivate func recordSubscriptionAndScheduledStart(url requestedURL: URL) {
        XCTAssertEqual(requestedURL, url)
        lock.lock()
        subscriptions += 1
        scheduledStarts += 1
        let waiters = scheduledStartWaiters.filter { scheduledStarts >= $0.count }
        scheduledStartWaiters.removeAll { scheduledStarts >= $0.count }
        lock.unlock()
        waiters.forEach { $0.continuation.resume() }
    }

    fileprivate func recordCancellation() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }

    fileprivate func startOutput() -> Output {
        lock.lock()
        starts += 1
        lock.unlock()
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data: data, response: response)
    }
}

private struct GatedDataRequestPublisher: Publisher {
    typealias Output = URLSession.DataTaskPublisher.Output
    typealias Failure = URLError

    let gate: GatedDataRequestTransport
    let url: URL

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        let subscription = GatedDataRequestSubscription(subscriber: subscriber, gate: gate, url: url)
        subscriber.receive(subscription: subscription)
    }
}

private final class GatedDataRequestSubscription<S: Subscriber>: Subscription
where S.Input == URLSession.DataTaskPublisher.Output, S.Failure == URLError {
    private let lock = NSLock()
    private var subscriber: S?
    private let gate: GatedDataRequestTransport
    private let url: URL
    private var hasRecordedSubscription = false

    init(subscriber: S, gate: GatedDataRequestTransport, url: URL) {
        self.subscriber = subscriber
        self.gate = gate
        self.url = url
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        lock.lock()
        let shouldRecord = !hasRecordedSubscription
        hasRecordedSubscription = true
        lock.unlock()
        if shouldRecord {
            gate.recordSubscriptionAndScheduledStart(url: url)
            Task { [weak self] in
                await self?.startWhenGateOpens()
            }
        }
    }

    func cancel() {
        lock.lock()
        let hadSubscriber = subscriber != nil
        subscriber = nil
        lock.unlock()
        if hadSubscriber {
            gate.recordCancellation()
        }
    }

    private func startWhenGateOpens() async {
        await gate.waitUntilOpen()
        lock.lock()
        guard let subscriber else {
            lock.unlock()
            return
        }
        self.subscriber = nil
        lock.unlock()
        _ = subscriber.receive(gate.startOutput())
        subscriber.receive(completion: .finished)
    }
}

private extension Result where Failure == AppError {
    var failure: AppError? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let data: Data
        let headers: [String: String]
        let delay: TimeInterval
        let onDelivered: (() -> Void)?
        let onStopped: (() -> Void)?

        static func immediate(status: Int, data: Data, headers: [String: String] = [:]) -> Self {
            .init(status: status, data: data, headers: headers, delay: 0, onDelivered: nil, onStopped: nil)
        }

        static func delayed(
            status: Int,
            data: Data,
            delay: TimeInterval,
            onDelivered: (() -> Void)? = nil,
            onStopped: (() -> Void)? = nil
        ) -> Self {
            .init(
                status: status,
                data: data,
                headers: [:],
                delay: delay,
                onDelivered: onDelivered,
                onStopped: onStopped
            )
        }
    }

    typealias Handler = (URLRequest) throws -> Response

    private static let lock = NSLock()
    private static var handlers = [String: Handler]()
    private static var startCounts = [String: Int]()
    private static var stopCounts = [String: Int]()
    private var workItem: DispatchWorkItem?
    private var onStopped: (() -> Void)?

    static func stub(_ url: URL, handler: @escaping Handler) {
        lock.lock()
        handlers[url.absoluteString] = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handlers.removeAll()
        startCounts.removeAll()
        stopCounts.removeAll()
        lock.unlock()
    }

    static func stopCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCounts[url.absoluteString] ?? 0
    }

    static func startCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return startCounts[url.absoluteString] ?? 0
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        let canHandle = handlers[url.absoluteString] != nil
        lock.unlock()
        return canHandle
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let handler = Self.handlers[url.absoluteString]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            Self.lock.lock()
            Self.startCounts[url.absoluteString, default: 0] += 1
            Self.lock.unlock()
            let response = try handler(request)
            onStopped = response.onStopped
            let deliver = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: response.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: response.headers
                )!
                self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: response.data)
                self.client?.urlProtocolDidFinishLoading(self)
                response.onDelivered?()
            }
            workItem = deliver
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        workItem?.cancel()
        workItem = nil
        if let url = request.url {
            Self.lock.lock()
            Self.stopCounts[url.absoluteString, default: 0] += 1
            Self.lock.unlock()
        }
        onStopped?()
        onStopped = nil
    }
}
