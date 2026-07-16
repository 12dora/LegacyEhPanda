//
//  ReaderImageCache.swift
//  EhPanda
//

import CryptoKit
import Foundation
import Kingfisher
import KingfisherWebP
import UIKit

// The reader owns the original bytes. This avoids downloading the same page again
// when its temporary image host or query parameters change, and keeps export and
// Live Text on the same data path as rendering.
actor ReaderImageDataCache {
    static let shared = ReaderImageDataCache()

    private let rootURL: URL
    private let memoryCache = NSCache<NSString, NSData>()
    private let maxDiskAge: TimeInterval = 7 * 24 * 60 * 60
    private let diskSizeLimit: UInt64 = 768 * 1_024 * 1_024
    private let fileManager: FileManager
    private var bytesWrittenSinceSweep: UInt64 = 0

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rootURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderImageData", isDirectory: true)
        memoryCache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func data(forKeys keys: [String]) -> Data? {
        for key in keys {
            let filename = Self.filename(forKey: key)
            if let value = memoryCache.object(forKey: filename as NSString) {
                return Data(referencing: value)
            }

            let url = rootURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if isExpired(url) {
                evict(url)
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            memoryCache.setObject(data as NSData, forKey: filename as NSString, cost: data.count)
            try? touch(url)
            return data
        }
        return nil
    }

    func store(_ data: Data, forKey key: String) throws {
        try ensureDirectory()
        let filename = Self.filename(forKey: key)
        let url = rootURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        memoryCache.setObject(data as NSData, forKey: filename as NSString, cost: data.count)
        try? touch(url)

        bytesWrittenSinceSweep += UInt64(data.count)
        if bytesWrittenSinceSweep >= diskSizeLimit / 8 {
            bytesWrittenSinceSweep = 0
            try sweepDisk()
        }
    }

    func removeData(forKeys keys: [String]) {
        for key in Set(keys) {
            let filename = Self.filename(forKey: key)
            memoryCache.removeObject(forKey: filename as NSString)
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(filename))
        }
    }

    func removeAllMemory() {
        memoryCache.removeAllObjects()
    }

    func removeAll() throws {
        memoryCache.removeAllObjects()
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try ensureDirectory()
        bytesWrittenSinceSweep = 0
    }

    func totalSize() -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: UInt64 = 0
        for case let url as URL in enumerator {
            autoreleasepool {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true {
                    size += UInt64(values?.fileSize ?? 0)
                }
            }
        }
        return size
    }

    func sweepDisk() throws {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var entries = [(url: URL, size: UInt64, date: Date)]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentAccessDateKey
            ])
            guard values.isRegularFile == true else { continue }
            let date = values.contentAccessDate ??
                ((try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
            if now.timeIntervalSince(date) > maxDiskAge {
                evict(url)
            } else {
                entries.append((url, UInt64(values.fileSize ?? 0), date))
            }
        }

        var size = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard size > diskSizeLimit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            evict(entry.url)
            size = size > entry.size ? size - entry.size : 0
            if size <= diskSizeLimit / 2 { break }
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = rootURL
        try? mutableURL.setResourceValues(values)
    }

    private func isExpired(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        let date = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
        return Date().timeIntervalSince(date) > maxDiskAge
    }

    private func touch(_ url: URL) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func evict(_ url: URL) {
        try? fileManager.removeItem(at: url)
        memoryCache.removeObject(forKey: url.lastPathComponent as NSString)
    }

    private static func filename(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension URL {
    private static let ignoredImageCacheQueryNames: Set<String> = [
        "dl", "download", "source", "from", "view"
    ]

    var stableImageCacheKey: String? {
        let normalizedPath = pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .compactMap(Self.normalizedImagePathComponent)
            .joined(separator: "/")
        guard !normalizedPath.isEmpty else { return nil }

        let namespace = isRotatingHAtHHost ? "" : "\(host?.lowercased() ?? "local")/"
        let items = normalizedImageCacheQueryItems
        guard !items.isEmpty else { return "reader::\(namespace)\(normalizedPath)" }
        let query = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "reader::\(namespace)\(normalizedPath)?\(query)"
    }

    var readerImageCacheKeys: [String] {
        var keys = [String]()
        if let stableImageCacheKey { keys.append(stableImageCacheKey) }
        keys.append(absoluteString)
        return keys
    }

    // H@H image paths end in "contentHash-byteCount-width-height-format".
    // Reserving this aspect ratio before decoding prevents iOS 16 LazyVStack
    // from shifting the viewport when a placeholder becomes the real image.
    var readerImageAspectRatio: CGFloat? {
        let supportedFormats = ["jpg", "jpeg", "png", "gif", "webp"]
        for component in pathComponents.reversed() {
            let fields = component.split(separator: "-")
            guard fields.count >= 5,
                  let format = fields.last?.lowercased(),
                  supportedFormats.contains(String(format)),
                  let width = Double(fields[fields.count - 3]),
                  let height = Double(fields[fields.count - 2]),
                  width > 0, height > 0
            else { continue }
            return CGFloat(width / height)
        }
        return nil
    }

    private var normalizedImageCacheQueryItems: [URLQueryItem] {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?
            .filter({ !($0.value ?? "").isEmpty }) else { return [] }
        let filtered = items.filter {
            !Self.ignoredImageCacheQueryNames.contains($0.name.lowercased())
        }
        return filtered.sorted {
            $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
        }
    }

    private var isRotatingHAtHHost: Bool {
        let normalizedHost = host?.lowercased() ?? ""
        if normalizedHost == "hath.network" || normalizedHost.hasSuffix(".hath.network") {
            return true
        }
        return pathComponents.contains { component in
            let fields = component.lowercased().split(separator: ";")
            return fields.contains(where: { $0.hasPrefix("keystamp=") })
                && fields.contains(where: { $0.hasPrefix("fileindex=") })
        }
    }

    // H@H URLs embed a short-lived keystamp alongside stable fileindex/xres
    // fields in a semicolon-delimited path component. Drop only the signature.
    private static func normalizedImagePathComponent(_ component: String) -> String? {
        let fields = component.split(separator: ";", omittingEmptySubsequences: true)
        guard fields.contains(where: { $0.lowercased().hasPrefix("keystamp=") }) else {
            return component
        }
        let stableFields = fields.filter { !$0.lowercased().hasPrefix("keystamp=") }
        return stableFields.isEmpty ? nil : stableFields.joined(separator: ";")
    }
}

struct ReaderImageAsset {
    let image: UIImage
    let data: Data

    var isAnimated: Bool {
        (image.kf.imageFrameCount ?? image.images?.count ?? 1) > 1
    }
}

private struct DownloadedReaderImage {
    let image: UIImage
    let data: Data
}

actor ReaderImagePipeline {
    static let shared = ReaderImagePipeline()

    private struct Transfer {
        let task: Task<DownloadedReaderImage, Error>
        var waiters: Set<UUID>
    }

    private let dataCache: ReaderImageDataCache
    private let decodedCache = NSCache<NSString, UIImage>()
    private var transfers = [String: Transfer]()

    init(dataCache: ReaderImageDataCache = .shared) {
        self.dataCache = dataCache
        decodedCache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func asset(
        for url: URL,
        priority: TaskPriority = .userInitiated,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> ReaderImageAsset {
        let keys = url.readerImageCacheKeys
        let primaryKey = keys[0]
        if let image = decodedCache.object(forKey: primaryKey as NSString),
           let data = await dataCache.data(forKeys: keys) {
            return ReaderImageAsset(image: image, data: data)
        }

        if url.isFileURL {
            let data = try await Task.detached(priority: priority) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Self.isKnownSitePlaceholder(data),
                  let image = await Self.decode(data, priority: priority)
            else { throw AppError.parseFailed }
            cacheDecoded(image, data: data, key: primaryKey)
            return ReaderImageAsset(image: image, data: data)
        }

        if let cached = await dataCache.data(forKeys: keys) {
            if !Self.isKnownSitePlaceholder(cached),
               let image = await Self.decode(cached, priority: priority) {
                cacheDecoded(image, data: cached, key: primaryKey)
                return ReaderImageAsset(image: image, data: cached)
            }
            // A truncated response or a cached 509/login image must become a cache
            // miss. Keeping it would strand every retry on the same bad bytes.
            await dataCache.removeData(forKeys: keys)
        }

        let download = try await transferData(
            for: url, key: url.absoluteString, priority: priority, onProgress: onProgress
        )
        try Task.checkCancellation()
        guard !Self.isKnownSitePlaceholder(download.data) else { throw AppError.parseFailed }
        let image = download.image
        try? await dataCache.store(download.data, forKey: primaryKey)
        cacheDecoded(image, data: download.data, key: primaryKey)
        return ReaderImageAsset(image: image, data: download.data)
    }

    private func cacheDecoded(_ image: UIImage, data: Data, key: String) {
        let pixelCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        decodedCache.setObject(image, forKey: key as NSString, cost: pixelCost)
    }

    func removeAllMemory() async {
        decodedCache.removeAllObjects()
        await dataCache.removeAllMemory()
    }

    private func transferData(
        for url: URL,
        key: String,
        priority: TaskPriority,
        onProgress: (@MainActor (Double) -> Void)?
    ) async throws -> DownloadedReaderImage {
        let waiter = UUID()
        let task: Task<DownloadedReaderImage, Error>
        if var existing = transfers[key] {
            existing.waiters.insert(waiter)
            transfers[key] = existing
            task = existing.task
        } else {
            task = Task(priority: priority) {
                try await Self.download(url: url, priority: priority, onProgress: onProgress)
            }
            transfers[key] = Transfer(task: task, waiters: [waiter])
        }

        return try await withTaskCancellationHandler {
            do {
                let data = try await task.value
                release(waiter: waiter, key: key)
                return data
            } catch {
                release(waiter: waiter, key: key)
                throw error
            }
        } onCancel: {
            Task { await self.cancel(waiter: waiter, key: key) }
        }
    }

    private func release(waiter: UUID, key: String) {
        guard var transfer = transfers[key] else { return }
        transfer.waiters.remove(waiter)
        if transfer.waiters.isEmpty {
            transfers[key] = nil
        } else {
            transfers[key] = transfer
        }
    }

    private func cancel(waiter: UUID, key: String) {
        guard var transfer = transfers[key] else { return }
        transfer.waiters.remove(waiter)
        if transfer.waiters.isEmpty {
            transfer.task.cancel()
            transfers[key] = nil
        } else {
            transfers[key] = transfer
        }
    }

    private static func download(
        url: URL,
        priority: TaskPriority,
        onProgress: (@MainActor (Double) -> Void)?
    ) async throws -> DownloadedReaderImage {
        var lastError: Error = AppError.networkingFailed
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await downloadOnce(
                    url: url, priority: priority, onProgress: onProgress
                )
            } catch {
                try Task.checkCancellation()
                lastError = error
                guard attempt < 2 else { break }
                let delay = UInt64(150_000_000 * (attempt + 1))
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }

    private static func downloadOnce(
        url: URL,
        priority: TaskPriority,
        onProgress: (@MainActor (Double) -> Void)?
    ) async throws -> DownloadedReaderImage {
        let holder = ReaderImageDownloadTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                holder.task = KingfisherManager.shared.downloader.downloadImage(
                    with: url,
                    options: [
                        .processor(WebPProcessor.default),
                        .backgroundDecode,
                        .downloadPriority(priority == .utility ? 0.25 : URLSessionTask.highPriority),
                        .callbackQueue(.untouch)
                    ],
                    progressBlock: { received, total in
                        guard total > 0, let onProgress else { return }
                        Task { @MainActor in
                            onProgress(min(Double(received) / Double(total), 1))
                        }
                    },
                    completionHandler: { result in
                        switch result {
                        case .success(let value):
                            continuation.resume(returning: DownloadedReaderImage(
                                image: value.image,
                                data: value.originalData
                            ))
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                )
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private static func decode(_ data: Data, priority: TaskPriority) async -> UIImage? {
        await Task.detached(priority: priority) {
            let options = KingfisherParsedOptionsInfo([
                .backgroundDecode,
                .processor(WebPProcessor.default),
                .scaleFactor(1)
            ])
            return WebPProcessor.default.process(item: .data(data), options: options)
        }.value
    }

    private static func isKnownSitePlaceholder(_ data: Data) -> Bool {
        let fingerprints: [(count: Int, sha1: String)] = [
            (144_844, "e48ed350e902a51581246d2a764fa7827e8e6988"),
            (28_658, "f54b887b017694dc25eb1a1404f71981885f8ed9")
        ]
        guard let fingerprint = fingerprints.first(where: { $0.count == data.count }) else {
            return false
        }
        let sha1 = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return sha1 == fingerprint.sha1
    }
}

private final class ReaderImageDownloadTaskHolder {
    private let lock = NSLock()
    private var storedTask: DownloadTask?
    private var isCancelled = false

    var task: DownloadTask? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedTask
        }
        set {
            lock.lock()
            let shouldCancel = isCancelled
            if !shouldCancel { storedTask = newValue }
            lock.unlock()
            if shouldCancel { newValue?.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = storedTask
        storedTask = nil
        lock.unlock()
        task?.cancel()
    }
}

// Reuse Kingfisher's cache-aware prefetch path. The previous custom transfer actor
// bypassed ImageCache, so already cached pages were downloaded again and stale
// persisted H@H URLs failed even when their images were available on disk.
//
// Prefetches are incremental: turning a page keeps overlapping neighbour downloads
// running instead of cancelling and restarting them from byte zero, which previously
// meant nothing ever finished while the user was actively flipping pages.
@MainActor
final class ReaderImagePrefetchCoordinator {
    static let shared = ReaderImagePrefetchCoordinator()

    private static let maxTrackedURLs = 10
    private static let maxConcurrentPrefetches = 3

    private var pending = [(key: String, resource: KF.ImageResource)]()
    private var activePrefetchers = [String: ImagePrefetcher]()
    private var wantedKeys = Set<String>()

    func update(urls: [URL]) {
        var seen = Set<String>()
        let resources: [(key: String, resource: KF.ImageResource)] = urls
            .prefix(Self.maxTrackedURLs)
            .compactMap { url in
                guard !url.isFileURL else { return nil }
                let key = url.stableImageCacheKey ?? url.absoluteString
                guard seen.insert(key).inserted else { return nil }
                return (key, KF.ImageResource(downloadURL: url, cacheKey: key))
            }
        wantedKeys = seen

        for (key, prefetcher) in activePrefetchers where !wantedKeys.contains(key) {
            prefetcher.stop()
            activePrefetchers[key] = nil
        }
        pending = resources.filter { activePrefetchers[$0.key] == nil }
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        while activePrefetchers.count < Self.maxConcurrentPrefetches, !pending.isEmpty {
            let next = pending.removeFirst()
            guard wantedKeys.contains(next.key), activePrefetchers[next.key] == nil else { continue }
            let prefetcher = ImagePrefetcher(
                resources: [next.resource],
                options: [
                    .processor(WebPProcessor.default),
                    .cacheSerializer(WebPSerializer.default),
                    .backgroundDecode,
                    .downloadPriority(0.2),
                    .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1)))
                ]
            ) { [weak self] _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activePrefetchers[next.key] = nil
                    self.startNextIfPossible()
                }
            }
            activePrefetchers[next.key] = prefetcher
            prefetcher.start()
        }
    }
}

@MainActor
final class ReaderImageCacheLifecycle {
    static let shared = ReaderImageCacheLifecycle()
    private var observers = [NSObjectProtocol]()

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await ReaderImagePipeline.shared.removeAllMemory() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await ReaderImagePipeline.shared.removeAllMemory()
                try? await ReaderImageDataCache.shared.sweepDisk()
            }
        })
    }
}
