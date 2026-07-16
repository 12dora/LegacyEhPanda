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
    let clearWebImageDiskCache: () -> Void
    let analyzeImageColors: (UIImage) async -> UIImageColors?
    let calculateWebImageDiskCacheSize: () async -> UInt?
}

extension LibraryClient {
    static let live: Self = .init(
        initializeLogger: {
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
                .cacheSerializer(WebPSerializer.default)
            ]
        },
        clearWebImageDiskCache: {
            KingfisherManager.shared.cache.clearDiskCache()
            Task {
                await ReaderImagePipeline.shared.removeAllMemory()
                try? await ReaderImageDataCache.shared.removeAll()
            }
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
        clearWebImageDiskCache: {},
        analyzeImageColors: { _ in .none },
        calculateWebImageDiskCacheSize: { .none }
    )

    static let unimplemented: Self = .init(
        initializeLogger: XCTestDynamicOverlay.unimplemented("\(Self.self).initializeLogger"),
        initializeWebImage: XCTestDynamicOverlay.unimplemented("\(Self.self).initializeWebImage"),
        clearWebImageDiskCache: XCTestDynamicOverlay.unimplemented("\(Self.self).clearWebImageDiskCache"),
        analyzeImageColors: XCTestDynamicOverlay.unimplemented("\(Self.self).analyzeImageColors"),
        calculateWebImageDiskCacheSize:
            XCTestDynamicOverlay.unimplemented("\(Self.self).calculateWebImageDiskCacheSize")
    )
}
