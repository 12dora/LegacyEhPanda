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
        guard let size = readerImagePixelSize else { return nil }
        return CGFloat(size.width) / CGFloat(size.height)
    }

    // The same fields give the decoded cost of a page before a single byte is
    // fetched, which is what the prefetch window has to be budgeted against.
    var readerImageDecodedPixelCount: Int? {
        guard let size = readerImagePixelSize else { return nil }
        // The dimensions come from an untrusted path component, so the product is
        // computed with overflow reporting and rejected rather than trapped on.
        let (product, overflowed) = size.width.multipliedReportingOverflow(by: size.height)
        guard !overflowed else { return nil }
        return min(product, Self.maxPlausibleImagePixelCount)
    }

    // A 30000x30000 page is already far beyond anything the site serves; anything
    // larger is malformed or hostile and must not reach a budget calculation.
    private static let maxPlausibleImageDimension = 30_000
    private static let maxPlausibleImagePixelCount = 30_000 * 30_000

    private var readerImagePixelSize: (width: Int, height: Int)? {
        let supportedFormats = ["jpg", "jpeg", "png", "gif", "webp"]
        for component in pathComponents.reversed() {
            let fields = component.split(separator: "-")
            guard fields.count >= 5,
                  let format = fields.last?.lowercased(),
                  supportedFormats.contains(String(format)),
                  let width = Int(fields[fields.count - 3]),
                  let height = Int(fields[fields.count - 2]),
                  width > 0, height > 0,
                  width <= Self.maxPlausibleImageDimension,
                  height <= Self.maxPlausibleImageDimension
            else { continue }
            return (width, height)
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

// The site answers quota exhaustion and expired sessions with fixed error artwork.
// Those bytes decode successfully, so only their fingerprint distinguishes them from
// a real page.
enum ReaderImagePlaceholderFingerprint {
    private static let fingerprints: [(count: Int, sha1: String)] = [
        (144_844, "e48ed350e902a51581246d2a764fa7827e8e6988"),
        (28_658, "f54b887b017694dc25eb1a1404f71981885f8ed9")
    ]

    static func matches(_ data: Data) -> Bool {
        guard let fingerprint = fingerprints.first(where: { $0.count == data.count }) else {
            return false
        }
        let sha1 = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return sha1 == fingerprint.sha1
    }
}

extension Data {
    // The byte-only prefetch never decodes, so a container sniff replaces the decode
    // as the check that only plausible image bytes reach the shared page cache.
    var looksLikeReaderImageData: Bool {
        let signatures: [(offset: Int, bytes: [UInt8])] = [
            (0, [0xFF, 0xD8, 0xFF]),                // JPEG
            (0, [0x89, 0x50, 0x4E, 0x47]),          // PNG
            (0, [0x47, 0x49, 0x46, 0x38]),          // GIF
            (0, Array("RIFF".utf8)),                // WebP (RIFF container)
            (4, Array("ftyp".utf8))                 // HEIF/HEIC
        ]
        return signatures.contains { signature in
            guard count >= signature.offset + signature.bytes.count else { return false }
            let start = index(startIndex, offsetBy: signature.offset)
            let end = index(start, offsetBy: signature.bytes.count)
            return Array(self[start..<end]) == signature.bytes
        }
    }
}

// Prefetching wants the bytes and nothing else, but `ImageDownloader` treats a nil
// processor result as a failure and would otherwise drop the data. WebPProcessor fully
// decodes a WebP frame before the original data is even handed back, which is exactly
// the decode burst prefetching is supposed to avoid, so the prefetch path substitutes a
// zero-cost placeholder image and keeps `originalData`. Its identifier never reaches a
// cache: the coordinator stores the bytes itself under the display processor's key.
struct ReaderBytesOnlyProcessor: ImageProcessor {
    static let `default` = ReaderBytesOnlyProcessor()

    let identifier = "com.ehpanda.readerBytesOnlyProcessor"
    private static let placeholder = UIImage()

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case .image(let image):
            return image
        case .data:
            return Self.placeholder
        }
    }
}

// The disk cache can still hold placeholder bytes written before the download guard
// below existed. A cache serializer is the single point every disk read and write passes
// through and, unlike a processor, it is not part of the cache key, so validating here
// turns a poisoned entry into an ordinary cache miss without invalidating correctly
// cached pages.
struct ReaderImageCacheSerializer: CacheSerializer {
    static let `default` = ReaderImageCacheSerializer()

    var originalDataUsed: Bool { WebPSerializer.default.originalDataUsed }

    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        if let original, ReaderImagePlaceholderFingerprint.matches(original) { return nil }
        return WebPSerializer.default.data(with: image, original: original)
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        guard !ReaderImagePlaceholderFingerprint.matches(data) else { return nil }
        return WebPSerializer.default.image(with: data, options: options)
    }
}

// Display, prefetch and the reader pipeline all download through the shared Kingfisher
// downloader, so validating here is the only place that covers every caller. The URL is
// available at this stage, which is what makes it possible to evict both the stable page
// key and the absolute key before the transfer is reported as a retryable failure
// instead of being cached and rendered as a successful page.
final class ReaderImagePlaceholderGuard: ImageDownloaderDelegate {
    static let shared = ReaderImagePlaceholderGuard()

    private static let processorIdentifiers = [
        WebPProcessor.default.identifier, DefaultImageProcessor.default.identifier
    ]

    func imageDownloader(_ downloader: ImageDownloader, didDownload data: Data, for url: URL) -> Data? {
        guard ReaderImagePlaceholderFingerprint.matches(data) else { return data }
        let keys = url.readerImageCacheKeys
        let cache = KingfisherManager.shared.cache
        for key in keys {
            for identifier in Self.processorIdentifiers {
                cache.removeImage(forKey: key, processorIdentifier: identifier)
            }
        }
        Task { await ReaderImageDataCache.shared.removeData(forKeys: keys) }
        Logger.error("Rejected known site placeholder", context: [
            "host": url.host ?? "nil", "byteCount": data.count
        ])
        return nil
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

    // Offline pages never reach the byte/decoded caches above, because they are not
    // downloaded and their file URL is not a stable page key. Without this entry every
    // auxiliary action (OCR, copy, save, share) reread and redecoded the whole page.
    private final class LocalAssetEntry {
        let image: UIImage
        let data: Data

        init(image: UIImage, data: Data) {
            self.image = image
            self.data = data
        }
    }

    private let dataCache: ReaderImageDataCache
    private let decodedCache = NSCache<NSString, UIImage>()
    private let localAssets = NSCache<NSString, LocalAssetEntry>()
    private var transfers = [String: Transfer]()

    init(dataCache: ReaderImageDataCache = .shared) {
        self.dataCache = dataCache
        decodedCache.totalCostLimit = 96 * 1_024 * 1_024
        localAssets.totalCostLimit = 48 * 1_024 * 1_024
    }

    func asset(
        for url: URL,
        priority: TaskPriority = .userInitiated,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> ReaderImageAsset {
        let keys = url.readerImageCacheKeys
        let primaryKey = keys[0]

        if url.isFileURL {
            let localKey = Self.localAssetKey(for: url)
            if let localKey, let entry = localAssets.object(forKey: localKey as NSString) {
                return ReaderImageAsset(image: entry.image, data: entry.data)
            }
            let data = try await Task.detached(priority: priority) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard !Self.isKnownSitePlaceholder(data),
                  let image = await Self.decode(data, priority: priority)
            else { throw AppError.parseFailed }
            cacheDecoded(image, data: data, key: primaryKey)
            if let localKey {
                // The entry retains the decoded bitmap, so the cost has to be the
                // decoded pixels plus the source bytes; charging `data.count` alone
                // let twenty compressed pages retain hundreds of MB of pixels.
                localAssets.setObject(
                    LocalAssetEntry(image: image, data: data),
                    forKey: localKey as NSString,
                    cost: Self.decodedByteCost(of: image) + data.count
                )
            }
            return ReaderImageAsset(image: image, data: data)
        }

        if let image = decodedCache.object(forKey: primaryKey as NSString),
           let data = await dataCache.data(forKeys: keys) {
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

        // Coalesce by the stable page key, not by the absolute URL: a renewed H@H
        // signature produces a different absolute URL for the very same page, and
        // keying by it duplicated the download and the decode.
        let download = try await transferData(
            for: url, key: primaryKey, priority: priority, onProgress: onProgress
        )
        try Task.checkCancellation()
        guard !Self.isKnownSitePlaceholder(download.data) else { throw AppError.parseFailed }
        let image = download.image
        try? await dataCache.store(download.data, forKey: primaryKey)
        cacheDecoded(image, data: download.data, key: primaryKey)
        return ReaderImageAsset(image: image, data: download.data)
    }

    private func cacheDecoded(_ image: UIImage, data: Data, key: String) {
        decodedCache.setObject(image, forKey: key as NSString, cost: Self.decodedByteCost(of: image))
    }

    // Bytes of decoded pixels the image retains, animated frames included. NSCache
    // limits only bound what they are told about, so every cache holding a decoded
    // page has to charge this rather than the compressed size.
    private static func decodedByteCost(of image: UIImage) -> Int {
        let width = Double(image.size.width * image.scale)
        let height = Double(image.size.height * image.scale)
        let frameCount = max(1, image.kf.imageFrameCount ?? image.images?.count ?? 1)
        let bytes = width * height * 4 * Double(frameCount)
        guard bytes.isFinite, bytes > 0 else { return 1 }
        return Int(min(bytes, Double(Int.max / 2)))
    }

    func removeAllMemory() async {
        decodedCache.removeAllObjects()
        localAssets.removeAllObjects()
        await dataCache.removeAllMemory()
    }

    // Canonical path plus the identity-bearing file metadata, so a repaired or
    // re-downloaded page invalidates its entry instead of serving stale bytes.
    private static func localAssetKey(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize else { return nil }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
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

    static func isKnownSitePlaceholder(_ data: Data) -> Bool {
        ReaderImagePlaceholderFingerprint.matches(data)
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

// Prefetching warms *bytes*, not bitmaps. The previous prefetcher decoded up to three
// full-resolution pages concurrently and put them in the memory cache, which on a
// 2400x3600 gallery is roughly 100 MB before neighbours, SwiftUI, OCR or export are
// accounted for. Kingfisher serializes reader pages as their original data anyway
// (WebPSerializer keeps the original bytes), so storing the downloaded data under the
// exact key/processor identifier the display path reads back is equivalent to what the
// prefetcher used to write — minus the eager full-size decode. The single
// full-resolution decode is left to the page actually being displayed or exported.
//
// Prefetches are incremental: turning a page keeps overlapping neighbour downloads
// running instead of cancelling and restarting them from byte zero, which previously
// meant nothing ever finished while the user was actively flipping pages.
@MainActor
final class ReaderImagePrefetchCoordinator {
    static let shared = ReaderImagePrefetchCoordinator()

    private struct Candidate {
        let key: String
        let url: URL
        let pixelCount: Int
    }

    private static let maxTrackedURLs = 10
    private static let maxConcurrentPrefetches = 3
    private static let assumedPixelCount = 2_400 * 3_600
    // Pages a reader may be holding warm at once, measured in decoded pixels rather
    // than in page counts, so high-resolution galleries shorten the window themselves.
    private static let basePixelBudget = 24_000_000
    private static let memoryPressureCooldown: TimeInterval = 30

    private var pending = [Candidate]()
    private var activeTasks = [String: DownloadTask]()
    private var wantedKeys = Set<String>()
    private var memoryPressureUntil: Date?

    func update(urls: [URL]) {
        var seen = Set<String>()
        var candidates = [Candidate]()
        var pixels = 0
        let trackedLimit = trackedURLLimit
        let budget = pixelBudget

        for url in urls where !url.isFileURL {
            guard candidates.count < trackedLimit else { break }
            let key = url.stableImageCacheKey ?? url.absoluteString
            guard seen.insert(key).inserted else { continue }
            let pixelCount = url.readerImageDecodedPixelCount ?? Self.assumedPixelCount
            if !candidates.isEmpty, pixels + pixelCount > budget { break }
            pixels += pixelCount
            candidates.append(.init(key: key, url: url, pixelCount: pixelCount))
        }
        wantedKeys = Set(candidates.map(\.key))

        for (key, task) in activeTasks where !wantedKeys.contains(key) {
            task.cancel()
            activeTasks[key] = nil
        }
        pending = candidates.filter { activeTasks[$0.key] == nil && !Self.isCached($0.key) }
        startNextIfPossible()
    }

    // Drop every speculative transfer without changing how aggressively the next window
    // may be refilled. This is what a user-initiated cache clear needs: nothing must
    // repopulate the stores mid-clear, but prefetching afterwards is legitimate.
    func stopAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        pending.removeAll()
        wantedKeys.removeAll()
    }

    // A memory warning means the reader is already over budget; stop everything and
    // stay conservative for a while instead of immediately refilling.
    func handleMemoryPressure() {
        memoryPressureUntil = Date().addingTimeInterval(Self.memoryPressureCooldown)
        stopAll()
    }

    private var isUnderMemoryPressure: Bool {
        guard let memoryPressureUntil else { return false }
        return Date() < memoryPressureUntil
    }

    private var pressureScale: Double {
        var scale: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            scale = 1
        case .fair:
            scale = 0.7
        case .serious:
            scale = 0.4
        case .critical:
            scale = 0.2
        @unknown default:
            scale = 0.5
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { scale *= 0.5 }
        if isUnderMemoryPressure { scale *= 0.5 }
        return scale
    }

    private var trackedURLLimit: Int {
        max(1, Int((Double(Self.maxTrackedURLs) * pressureScale).rounded()))
    }
    private var concurrencyLimit: Int {
        max(1, Int((Double(Self.maxConcurrentPrefetches) * pressureScale).rounded()))
    }
    private var pixelBudget: Int {
        max(Self.assumedPixelCount, Int(Double(Self.basePixelBudget) * pressureScale))
    }

    private static func isCached(_ key: String) -> Bool {
        KingfisherManager.shared.cache.imageCachedType(
            forKey: key, processorIdentifier: WebPProcessor.default.identifier
        ).cached
    }

    private func startNextIfPossible() {
        let limit = concurrencyLimit
        while activeTasks.count < limit, !pending.isEmpty {
            let next = pending.removeFirst()
            guard wantedKeys.contains(next.key), activeTasks[next.key] == nil else { continue }
            guard let task = Self.startTransfer(next) else { continue }
            activeTasks[next.key] = task
        }
    }

    private static func startTransfer(_ candidate: Candidate) -> DownloadTask? {
        KingfisherManager.shared.downloader.downloadImage(
            with: candidate.url,
            options: [
                .processor(ReaderBytesOnlyProcessor.default),
                .downloadPriority(0.2),
                .callbackQueue(.untouch)
            ],
            progressBlock: nil,
            completionHandler: { result in
                if case .success(let value) = result, value.originalData.looksLikeReaderImageData {
                    KingfisherManager.shared.cache.storeToDisk(
                        value.originalData,
                        forKey: candidate.key,
                        processorIdentifier: WebPProcessor.default.identifier
                    )
                }
                Task { @MainActor in
                    ReaderImagePrefetchCoordinator.shared.finish(key: candidate.key)
                }
            }
        )
    }

    private func finish(key: String) {
        activeTasks[key] = nil
        startNextIfPossible()
    }
}

@MainActor
final class ReaderImageCacheLifecycle {
    static let shared = ReaderImageCacheLifecycle()
    private var observers = [NSObjectProtocol]()
    // ImageDownloader keeps its delegate weakly.
    private let placeholderGuard = ReaderImagePlaceholderGuard.shared

    private init() {
        KingfisherManager.shared.downloader.delegate = placeholderGuard
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ReaderImagePrefetchCoordinator.shared.handleMemoryPressure()
                await ReaderImagePipeline.shared.removeAllMemory()
            }
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
