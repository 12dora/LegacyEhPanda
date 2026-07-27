//
//  LibraryClient.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/02.
//

import SwiftUI
import Combine
import Foundation
import Kingfisher
import KingfisherWebP
import SwiftyBeaver
import UIImageColors
import ComposableArchitecture

struct LibraryClient {
    let initializeLogger: () -> Void
    let initializeWebImage: () -> Void
    let clearWebImageCache: () async -> Void
    let analyzeImageColors: (UIImage) async -> UIImageColors?
    let calculateWebImageDiskCacheSize: () async -> UInt?
}

extension LibraryClient {
    static let live: Self = .init(
        initializeLogger: {
            LibraryClient.purgeCredentialBearingLogsIfNeeded()
            // MARK: SwiftyBeaver
            let file = FileDestination()
            let console = ConsoleDestination()
            let format = [
                "$Dyyyy-MM-dd HH:mm:ss.SSS$d",
                "$C$L$c $N.$F:$l - $M $X"
            ].joined(separator: " ")

            file.format = format
            file.logFileAmount = 10
            file.calendar = Calendar(identifier: .gregorian)
            file.logFileURL = FileUtil.logsDirectoryURL?
                .appendingPathComponent(Defaults.FilePath.ehpandaLog)

            console.format = format
            console.calendar = Calendar(identifier: .gregorian)
            console.asynchronously = false
            console.levelColor.verbose = "😪"
            console.levelColor.warning = "⚠️"
            console.levelColor.error = "‼️"
            console.levelColor.debug = "🐛"
            console.levelColor.info = "📖"

            SwiftyBeaver.addDestination(file)
            #if DEBUG
            SwiftyBeaver.addDestination(console)
            #endif
        },
        initializeWebImage: {
            Task { @MainActor in
                _ = ReaderImageCacheLifecycle.shared
            }
            let config = KingfisherManager.shared.downloader.sessionConfiguration
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpAdditionalHeaders = [
                "Accept": "image/webp,image/png,image/gif,image/jpeg,image/*,*/*;q=0.8"
            ]
            KingfisherManager.shared.downloader.sessionConfiguration = config
            // H@H nodes are frequently slow to the first byte; the 15s default turns
            // slow-but-healthy nodes into spurious load failures.
            KingfisherManager.shared.downloader.downloadTimeout = 30
            KingfisherManager.shared.defaultOptions += [
                .processor(WebPProcessor.default),
                // The reader serializer wraps `WebPSerializer` and additionally rejects
                // known site placeholders. Registering it here rather than relying on a
                // later append makes the placeholder-evicting path deterministic.
                .cacheSerializer(ReaderImageCacheSerializer.default)
            ]
        },
        clearWebImageCache: {
            // One awaitable operation. Speculative transfers are stopped first so nothing
            // repopulates the stores mid-clear, then both Kingfisher stores and both reader
            // stores are dropped before the caller recalculates the published size.
            await MainActor.run {
                ReaderImagePrefetchCoordinator.shared.stopAll()
            }
            KingfisherManager.shared.cache.clearMemoryCache()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                KingfisherManager.shared.cache.clearDiskCache {
                    continuation.resume()
                }
            }
            await ReaderImagePipeline.shared.removeAllMemory()
            try? await ReaderImageDataCache.shared.removeAll()
        },
        analyzeImageColors: { image in
            await withCheckedContinuation { continuation in
                image.getColors(quality: .lowest) { colors in
                    continuation.resume(returning: colors)
                }
            }
        },
        calculateWebImageDiskCacheSize: {
            let kingfisherSize: UInt? = await withCheckedContinuation { continuation in
                KingfisherManager.shared.cache.calculateDiskStorageSize {
                    continuation.resume(returning: try? $0.get())
                }
            }
            let readerSize = await ReaderImageDataCache.shared.totalSize()
            return (kingfisherSize ?? 0) + UInt(readerSize)
        }
    )

    // Logs written before action logging was reduced to payload-free events can still
    // contain plaintext passwords and reusable cookies, and they live in the file-sharing
    // enabled Documents directory. Delete them exactly once, before any destination is
    // attached and can append to them.
    private static let credentialLogPurgeKey = "logs.credentialBearingPurge.v1"

    private static func purgeCredentialBearingLogsIfNeeded() {
        let userDefaults = UserDefaults.standard
        guard !userDefaults.bool(forKey: credentialLogPurgeKey) else { return }
        userDefaults.set(true, forKey: credentialLogPurgeKey)

        guard let directoryURL = FileUtil.logsDirectoryURL,
              let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        else { return }

        for fileName in fileNames where fileName.contains(Defaults.FilePath.ehpandaLog) {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(fileName))
        }
    }
}

// MARK: API
enum LibraryClientKey: DependencyKey {
    static let liveValue = LibraryClient.live
    static let previewValue = LibraryClient.noop
    static let testValue = LibraryClient.unimplemented
}

extension DependencyValues {
    var libraryClient: LibraryClient {
        get { self[LibraryClientKey.self] }
        set { self[LibraryClientKey.self] = newValue }
    }
}

// MARK: Test
extension LibraryClient {
    static let noop: Self = .init(
        initializeLogger: {},
        initializeWebImage: {},
        clearWebImageCache: {},
        analyzeImageColors: { _ in .none },
        calculateWebImageDiskCacheSize: { .none }
    )

    static let unimplemented: Self = .init(
        initializeLogger: XCTestDynamicOverlay.unimplemented("\(Self.self).initializeLogger"),
        initializeWebImage: XCTestDynamicOverlay.unimplemented("\(Self.self).initializeWebImage"),
        clearWebImageCache: XCTestDynamicOverlay.unimplemented("\(Self.self).clearWebImageCache"),
        analyzeImageColors: XCTestDynamicOverlay.unimplemented("\(Self.self).analyzeImageColors"),
        calculateWebImageDiskCacheSize:
            XCTestDynamicOverlay.unimplemented("\(Self.self).calculateWebImageDiskCacheSize")
    )
}
