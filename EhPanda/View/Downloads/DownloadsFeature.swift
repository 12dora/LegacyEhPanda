//
//  DownloadsFeature.swift
//  EhPanda
//
//  iOS 16-compatible backport of the 3.0 offline download feature.
//

import ImageIO
import SwiftUI
import CryptoKit
import Kingfisher
import KingfisherWebP
import ComposableArchitecture

enum GalleryDownloadStatus: String, Codable, Equatable {
    case preparing
    case downloading
    case paused
    case completed
    case failed
}

struct GalleryDownload: Codable, Equatable, Identifiable {
    static let manifestVersion = 2

    var id: String { gallery.id }
    var gid: String { gallery.id }
    var completedCount: Int { fileNames.count }
    var progress: Double {
        guard gallery.pageCount > 0 else { return 0 }
        return min(1, Double(completedCount) / Double(gallery.pageCount))
    }
    var canReadOffline: Bool {
        gallery.pageCount > 0 && completedCount >= gallery.pageCount
    }

    let version: Int
    // Bumped whenever the stored pages are replaced. Resolver records, session task
    // descriptions and delegate callbacks all carry it, so work started by a previous
    // generation can never write into the manifest that replaced it.
    var generation: UUID
    var gallery: Gallery
    var detail: GalleryDetail
    var previewConfig: PreviewConfig
    var folderName: String
    var status: GalleryDownloadStatus
    var fileNames: [Int: String]
    var remoteURLs: [Int: URL]
    // Resolution timestamps for `remoteURLs`. Signed image URLs are short lived, so a
    // resumed download has to re-resolve anything that has aged out instead of retrying
    // a spent signature forever.
    var remoteURLDates: [Int: Date]
    var failureDescription: String?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case version, generation, gallery, detail, previewConfig, folderName
        case status, fileNames, remoteURLs, remoteURLDates, failureDescription, updatedAt
    }

    init(
        gallery: Gallery,
        detail: GalleryDetail,
        previewConfig: PreviewConfig,
        folderName: String = DownloadManager.defaultFolder
    ) {
        version = Self.manifestVersion
        generation = UUID()
        self.gallery = gallery
        self.detail = detail
        self.previewConfig = previewConfig
        self.folderName = folderName
        status = .preparing
        fileNames = [:]
        remoteURLs = [:]
        remoteURLDates = [:]
        updatedAt = Date()
    }

    // Manifests written before the generation and URL-age fields existed still describe
    // usable galleries, so missing keys fall back to safe defaults instead of discarding
    // the download and stranding its page files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        generation = try container.decodeIfPresent(UUID.self, forKey: .generation) ?? UUID()
        gallery = try container.decode(Gallery.self, forKey: .gallery)
        detail = try container.decode(GalleryDetail.self, forKey: .detail)
        previewConfig = try container.decode(PreviewConfig.self, forKey: .previewConfig)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
            ?? DownloadManager.defaultFolder
        status = try container.decode(GalleryDownloadStatus.self, forKey: .status)
        fileNames = try container.decodeIfPresent([Int: String].self, forKey: .fileNames) ?? [:]
        remoteURLs = try container.decodeIfPresent([Int: URL].self, forKey: .remoteURLs) ?? [:]
        remoteURLDates = try container.decodeIfPresent([Int: Date].self, forKey: .remoteURLDates) ?? [:]
        failureDescription = try container.decodeIfPresent(String.self, forKey: .failureDescription)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func freshRemoteURL(at index: Int, lifetime: TimeInterval) -> URL? {
        guard let url = remoteURLs[index], let resolvedAt = remoteURLDates[index],
              Date().timeIntervalSince(resolvedAt) < lifetime
        else { return nil }
        return url
    }

    func freshRemoteURLIndices(lifetime: TimeInterval) -> Set<Int> {
        let now = Date()
        return Set(remoteURLDates.compactMap { index, resolvedAt -> Int? in
            now.timeIntervalSince(resolvedAt) < lifetime ? index : nil
        })
    }
}

private enum DownloadPaths {
    static let stagingName = "Staging"
    static let quarantineName = "Quarantine"

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EhPandaDownloads", isDirectory: true)
    }

    static func galleryDirectory(_ gid: String) -> URL {
        root.appendingPathComponent(gid, isDirectory: true)
    }

    static func manifest(_ gid: String) -> URL {
        galleryDirectory(gid).appendingPathComponent("manifest.json")
    }

    static var folders: URL {
        root.appendingPathComponent("folders.json")
    }

    // Finished transfers land here first. Staging outside of any gallery directory keeps a
    // late callback from recreating a directory that was just deleted or replaced.
    static var staging: URL {
        root.appendingPathComponent(stagingName, isDirectory: true)
    }

    // Galleries whose manifest is gone or unparsable are moved aside instead of being
    // silently ignored on every launch while their page files keep occupying storage.
    static var quarantine: URL {
        root.appendingPathComponent(quarantineName, isDirectory: true)
    }
}

private struct DownloadTaskIdentity {
    let gid: String
    let index: Int
    let generation: UUID
}

private struct DownloadSnapshot {
    var downloads = [GalleryDownload]()
    var folders = [DownloadManager.defaultFolder]
    var quarantinedCount = 0
    var unsupportedCount = 0
    // False when at least one gallery directory could not be read or is newer than this
    // build understands. Such a restoration must never be treated as the whole truth.
    var isComplete = true
}

private enum DownloadPersistenceError: LocalizedError {
    case galleryUnavailable
    case manifestUnavailable
    case unsupportedManifest
    case staleGeneration

    var errorDescription: String? {
        switch self {
        case .galleryUnavailable:
            return "The download was removed while a page was being saved."
        case .manifestUnavailable:
            return "The download manifest could not be read while a page was being saved."
        case .unsupportedManifest:
            return "The download was created by a newer version of the app."
        case .staleGeneration:
            return "The download was replaced while a page was being saved."
        }
    }

    // Only a gallery that is genuinely gone, or a generation that was replaced, may drop a
    // completed page silently. Everything else has to be retried and rescheduled.
    var discardsPageSilently: Bool {
        switch self {
        case .galleryUnavailable, .staleGeneration:
            return true
        case .manifestUnavailable, .unsupportedManifest:
            return false
        }
    }
}

// Every manifest read, manifest write and page-file mutation happens here so the MainActor
// never enumerates the download root or rewrites a growing manifest while the UI or the
// reader is busy. Serialising them also orders promotion against deletion and replacement,
// which is what keeps a late transfer from resurrecting a gallery that is gone.
private actor DownloadPersistence {
    static let shared = DownloadPersistence()

    private static let stagedFileLifetime: TimeInterval = 60 * 60

    private let fileManager = FileManager.default

    private enum ManifestReadResult {
        case decoded(GalleryDownload)
        // No manifest at all, or bytes that are not a manifest.
        case orphaned
        // Present but unreadable right now (file protection, transient I/O). Never
        // quarantined, because the gallery is very likely intact.
        case unavailable
        // Written by a newer build. Left completely untouched so a downgrade cannot
        // quarantine galleries that a later upgrade would read again.
        case unsupported
    }

    private struct ManifestVersionProbe: Decodable {
        let version: Int
    }

    // MARK: - Restoration

    func load() -> DownloadSnapshot {
        var snapshot = DownloadSnapshot()
        try? fileManager.createDirectory(at: DownloadPaths.root, withIntermediateDirectories: true)
        purgeStaleStagedFiles()

        if let data = try? Data(contentsOf: DownloadPaths.folders),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            snapshot.folders = Array(Set(stored + [DownloadManager.defaultFolder]))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        guard let directories = try? fileManager.contentsOfDirectory(
            at: DownloadPaths.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return snapshot }

        for directory in directories {
            let name = directory.lastPathComponent
            guard name != DownloadPaths.stagingName, name != DownloadPaths.quarantineName,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            switch readManifest(at: directory) {
            case .decoded(var item):
                if item.status == .downloading || item.status == .preparing {
                    item.status = .preparing
                }
                snapshot.downloads.append(item)
            case .orphaned:
                if quarantine(directory: directory) { snapshot.quarantinedCount += 1 }
            case .unavailable:
                snapshot.isComplete = false
            case .unsupported:
                snapshot.unsupportedCount += 1
                snapshot.isComplete = false
            }
        }
        snapshot.downloads.sort { $0.updatedAt > $1.updatedAt }
        return snapshot
    }

    private func readManifest(at directory: URL) -> ManifestReadResult {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifest.path) else { return .orphaned }
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            return .unavailable
        }
        // The version is probed on its own: a manifest from a newer build may well fail to
        // decode into this build's model, and must still be recognised as unsupported rather
        // than mistaken for an orphan and quarantined.
        guard let probe = try? JSONDecoder().decode(ManifestVersionProbe.self, from: data) else {
            return .orphaned
        }
        guard probe.version <= GalleryDownload.manifestVersion else { return .unsupported }
        guard let item = try? JSONDecoder().decode(GalleryDownload.self, from: data) else {
            return .orphaned
        }
        return .decoded(item)
    }

    private func quarantine(directory: URL) -> Bool {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard contents.contains(where: { $0.lastPathComponent.hasPrefix("page-") }) else {
            try? fileManager.removeItem(at: directory)
            return false
        }
        let destination = DownloadPaths.quarantine.appendingPathComponent(
            "\(directory.lastPathComponent)-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: DownloadPaths.quarantine, withIntermediateDirectories: true)
            try fileManager.moveItem(at: directory, to: destination)
            return true
        } catch {
            return false
        }
    }

    private func purgeStaleStagedFiles() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: DownloadPaths.staging,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.stagedFileLifetime)
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let created, created < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Manifests

    // Durable, and the caller has to handle the failure. Used before anything that a
    // transfer or the UI would otherwise assume is already recorded.
    func commit(_ download: GalleryDownload) throws {
        try writeManifest(download)
    }

    // Best effort checkpoint of an already published state. The manager only ever hands over
    // the live snapshot it holds right now, so a late checkpoint can never revive a deleted
    // gallery or overwrite a newer generation with an older one.
    func checkpoint(_ download: GalleryDownload) {
        try? writeManifest(download)
    }

    func saveFolders(_ folders: [String]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? fileManager.createDirectory(at: DownloadPaths.root, withIntermediateDirectories: true)
        try? data.write(to: DownloadPaths.folders, options: .atomic)
    }

    private func writeManifest(_ download: GalleryDownload) throws {
        let directory = DownloadPaths.galleryDirectory(download.gid)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(download)
        try data.write(to: DownloadPaths.manifest(download.gid), options: .atomic)
    }

    // MARK: - Page files

    // A page is pending when the manifest has no file name for it *or* the file it names is
    // gone. The previous predicate appended an empty component for missing names and then
    // tested the gallery directory itself, so a fresh manifest reported every page as done.
    func pendingIndices(gid: String, pageCount: Int, fileNames: [Int: String]) -> [Int] {
        guard pageCount > 0 else { return [] }
        let directory = DownloadPaths.galleryDirectory(gid)
        return (1...pageCount).filter { index in
            guard let fileName = fileNames[index] else { return true }
            return !fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    func existingFileNames(gid: String, fileNames: [Int: String]) -> [Int: String] {
        let directory = DownloadPaths.galleryDirectory(gid)
        return fileNames.filter { _, fileName in
            fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    // The staged bytes only become a page once the on-disk manifest still exists and still
    // carries the generation that started the transfer. Both checks happen inside the actor,
    // so a delete or an Update All can never race a promotion into an orphan or a mismatch.
    func promote(
        staged: URL, gid: String, index: Int, fileExtension: String, generation: UUID
    ) throws -> String {
        let directory = DownloadPaths.galleryDirectory(gid)
        switch readManifest(at: directory) {
        case .decoded(let item):
            guard item.generation == generation else { throw DownloadPersistenceError.staleGeneration }
        case .orphaned:
            throw DownloadPersistenceError.galleryUnavailable
        case .unavailable:
            throw DownloadPersistenceError.manifestUnavailable
        case .unsupported:
            throw DownloadPersistenceError.unsupportedManifest
        }

        removePageFiles(gid: gid, index: index)
        let fileName = "page-\(index).\(fileExtension)"
        try fileManager.moveItem(at: staged, to: directory.appendingPathComponent(fileName))
        return fileName
    }

    func discard(staged: URL) {
        try? fileManager.removeItem(at: staged)
    }

    func deleteGallery(gid: String) {
        try? fileManager.removeItem(at: DownloadPaths.galleryDirectory(gid))
    }

    func deletePageFiles(gid: String) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: DownloadPaths.galleryDirectory(gid),
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("page-") {
            try? fileManager.removeItem(at: file)
        }
    }

    private func removePageFiles(gid: String, index: Int) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: DownloadPaths.galleryDirectory(gid),
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("page-\(index).") {
            try? fileManager.removeItem(at: file)
        }
    }

    // Called from the session delegate queue: the system temporary file disappears as soon
    // as the delegate returns, so it has to be moved out synchronously.
    static func stage(_ location: URL, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: DownloadPaths.staging, withIntermediateDirectories: true)
        let destination = DownloadPaths.staging
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }
}

private enum PageValidationError: Error {
    case missingResponse
    case httpStatus(Int)
    case unexpectedContentType(String)
    case truncated
    case unrecognizedFormat
    case sitePlaceholder
    case undecodable

    var message: String {
        switch self {
        case .missingResponse:
            return "The server did not return an HTTP response."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .unexpectedContentType(let type):
            return "The server returned \(type) instead of an image."
        case .truncated:
            return "The downloaded page was incomplete."
        case .unrecognizedFormat:
            return "The downloaded page is not a supported image."
        case .sitePlaceholder:
            return "The site returned a placeholder image instead of the page."
        case .undecodable:
            return "The downloaded page could not be decoded."
        }
    }
}

// Offline pages have to be real, complete images. Status, content type, length, a full
// decode and the site's known placeholder fingerprints are all checked before the bytes are
// allowed anywhere near a manifest. Lives at file scope so the session delegate can run it
// off the MainActor.
private enum PageValidator {
    static let minimumByteCount = 1_024

    static func validate(
        _ data: Data, statusCode: Int?, mimeType: String?, expectedLength: Int64
    ) throws -> String {
        guard let statusCode else { throw PageValidationError.missingResponse }
        guard (200..<300).contains(statusCode) else { throw PageValidationError.httpStatus(statusCode) }
        // A missing Content-Type is tolerated on purpose: H@H nodes do serve pages without
        // one, and rejecting those would fail perfectly good downloads. Nothing is lost by
        // it, because an error page or a placeholder still has to survive the magic byte,
        // fingerprint and full decode checks below, none of which trust the header.
        if let mimeType = mimeType?.lowercased(), !isPlausibleImageMIMEType(mimeType) {
            throw PageValidationError.unexpectedContentType(mimeType)
        }
        guard data.count >= minimumByteCount else { throw PageValidationError.truncated }
        if expectedLength > 0, Int64(data.count) < expectedLength {
            throw PageValidationError.truncated
        }
        guard let fileExtension = data.knownImageFileExtension else {
            throw PageValidationError.unrecognizedFormat
        }
        guard !isKnownSitePlaceholder(data) else { throw PageValidationError.sitePlaceholder }
        guard decodesCompletely(data, fileExtension: fileExtension) else {
            throw PageValidationError.undecodable
        }
        return fileExtension
    }

    private static func isPlausibleImageMIMEType(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("image/")
            || mimeType == "application/octet-stream"
            || mimeType == "binary/octet-stream"
    }

    private static func decodesCompletely(_ data: Data, fileExtension: String) -> Bool {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(
               source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
           ),
           image.width > 0, image.height > 0 {
            return true
        }
        // ImageIO decodes WebP from iOS 14 onwards, but fall back to the bundled decoder so a
        // valid WebP page is never rejected where that support is missing.
        guard fileExtension == "webp" else { return false }
        return WebPProcessor.default.process(
            item: .data(data), options: KingfisherParsedOptionsInfo([.scaleFactor(1)])
        ) != nil
    }

    // The same fingerprints the reader's image pipeline uses for the login and quota
    // placeholders. Unifying the two into one shared validator is a worthwhile follow-up.
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

// Counts delegate results that have left the session's delegate queue but have not finished
// promoting and persisting yet. Incremented synchronously in the delegate so the window
// between the callback and its MainActor hop is covered too.
private final class PendingDelegateWork: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count == 0
    }

    func enter() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func leave() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }
}

private let pendingDelegateWork = PendingDelegateWork()

private func describeDownloadError(_ error: Error) -> String {
    if let appError = error as? AppError { return appError.localizedDescription }
    if let validation = error as? PageValidationError { return validation.message }
    return error.localizedDescription
}

// Transport problems say nothing about the signature, so the URL is kept and its age alone
// decides whether the next pass re-resolves it. Anything else retires the URL.
private func invalidatesRemoteURL(_ error: NSError) -> Bool {
    guard error.domain == NSURLErrorDomain else { return true }
    switch error.code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
         NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed:
        return false
    default:
        return true
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    nonisolated static let defaultFolder = "Default"
    private static let sessionIdentifier = "com.ehpanda.legacy.gallery-downloads"
    // Only a handful of transfers and freshly signed URLs are kept alive at a time. The rest
    // of the gallery is resolved just in time as slots free up, instead of queueing hundreds
    // of tasks whose URLs expire long before their turn.
    private static let maxConcurrentTransfers = 4
    // Restoring several interrupted galleries would otherwise start a full window each; the
    // application wide ceiling caps the session no matter how many galleries are running.
    private static let maxTotalConcurrentTransfers = 8
    private static let remoteURLLifetime: TimeInterval = 30 * 60
    private static let maxAttemptsPerPage = 3
    private static let maxConsecutiveResolutionFailures = 3
    private static let checkpointInterval: UInt64 = 2_000_000_000
    // Bounded wait for outstanding delegate work, well inside the time iOS allows a
    // background session completion handler to take.
    private static let backgroundDrainInterval: UInt64 = 25_000_000
    private static let backgroundDrainAttempts = 200

    @Published private(set) var downloads = [GalleryDownload]()
    @Published private(set) var folders = [defaultFolder]
    // Surfaced when a manifest could not be written or unreadable galleries were quarantined,
    // so a download that silently stopped being durable is visible instead of pretending to
    // make progress.
    @Published private(set) var storageFailure: String?

    private struct ResolverRecord {
        let token: UUID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let persistence = DownloadPersistence.shared
    private var resolvers = [String: ResolverRecord]()
    private var pendingPumps = Set<String>()
    private var pageFailures = [String: [Int: String]]()
    private var pageAttempts = [String: [Int: Int]]()
    private var pagesAwaitingCommit = [String: Set<Int>]()
    // The authority on how many transfers are outstanding. `getAllTasks` cannot be used for
    // this: a task that has already delivered its bytes may still be listed, so a pass that
    // trusted it computed zero free slots and left pending pages with nothing to wake them.
    private var activeTransfers = [String: Set<Int>]()
    private var checkpointTasks = [String: Task<Void, Never>]()
    private var thumbnailCache = [String: [Int: [Int: URL]]]()
    private var mpvKeyCache = [String: (String, [Int: String])]()
    // Bumped on every published mutation so a durable write that was in flight can tell
    // whether the state it wrote is still the state the app is showing.
    private var stateRevisions = [String: UInt64]()
    private var restoreTask: Task<Void, Never>?
    private var restorationIsIncomplete = false
    private var backgroundCompletionHandler: (() -> Void)?
    private var session: URLSession!

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpCookieStorage = .shared
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // Interrupted downloads still resume without the user opening the tab, but the scan
        // itself now happens at a low priority on the persistence actor rather than inline.
        Task(priority: .utility) { [weak self] in
            await self?.restore()
        }
    }

    // MARK: - Restoration

    // Manifest enumeration and decoding are explicit and asynchronous, so merely building the
    // downloads tab no longer scans the whole download root on the MainActor.
    func restore() async {
        if let task = restoreTask {
            await task.value
            // A restoration that could not read every gallery is never cached as final, or a
            // single locked launch would hide those downloads until the process restarts.
            guard restorationIsIncomplete else { return }
            if restoreTask == task { restoreTask = nil }
        }
        if let task = restoreTask {
            await task.value
            return
        }
        let task = Task { [weak self] () -> Void in
            await self?.performRestore()
        }
        restoreTask = task
        await task.value
    }

    private func performRestore() async {
        let snapshot = await persistence.load()
        restorationIsIncomplete = !snapshot.isComplete
        folders = snapshot.folders
        var merged = snapshot.downloads
        for item in downloads where !merged.contains(where: { $0.gid == item.gid }) {
            merged.append(item)
        }
        downloads = merged
        sortDownloads()
        if snapshot.unsupportedCount > 0 {
            storageFailure = "\(snapshot.unsupportedCount) download(s) were created by a newer "
                + "version of the app and cannot be opened by this one."
        } else if snapshot.quarantinedCount > 0 {
            storageFailure = "\(snapshot.quarantinedCount) unreadable download(s) were moved to quarantine."
        } else if restorationIsIncomplete {
            storageFailure = "Some downloads could not be read yet and will be restored again later."
        }
        await adoptExistingTransfers(restorationIsComplete: snapshot.isComplete)
        for item in downloads where item.status == .preparing {
            pump(gid: item.gid)
        }
    }

    // Background transfers outlive the process, so the surviving ones are adopted into the
    // in-flight bookkeeping. A task is only retired when it is provably foreign: its
    // generation was replaced, or its gallery is unknown to a restoration that read
    // everything. An incomplete restoration retires nothing.
    private func adoptExistingTransfers(restorationIsComplete: Bool) async {
        for task in await allSessionTasks() {
            guard let identity = Self.taskIdentity(task.taskDescription) else {
                task.cancel()
                continue
            }
            guard let item = download(gid: identity.gid) else {
                if restorationIsComplete { task.cancel() }
                continue
            }
            guard item.generation == identity.generation else {
                task.cancel()
                continue
            }
            activeTransfers[identity.gid, default: []].insert(identity.index)
        }
    }

    // MARK: - Commands

    func start(
        gallery: Gallery,
        detail: GalleryDetail,
        previewConfig: PreviewConfig,
        replacingExisting: Bool = false
    ) async {
        await restore()
        let gid = gallery.id
        if replacingExisting {
            await cancelTransfers(gid: gid)
            await persistence.deletePageFiles(gid: gid)
        }
        // Snapshotted after the awaits so a page recorded meanwhile is not written back out.
        var item = download(gid: gid)
            ?? GalleryDownload(gallery: gallery, detail: detail, previewConfig: previewConfig)
        if replacingExisting {
            item.generation = UUID()
            item.fileNames = [:]
            item.remoteURLs = [:]
            item.remoteURLDates = [:]
        }
        item.gallery = gallery
        item.detail = detail
        item.previewConfig = previewConfig
        item.status = .preparing
        item.failureDescription = nil
        item.updatedAt = Date()
        resetPageOutcomes(gid: gid)
        guard await commit(item, insertIfNeeded: true) else { return }
        pumpAll()
    }

    func pause(gid: String) async {
        guard var item = download(gid: gid) else { return }
        item.status = .paused
        item.failureDescription = nil
        publishLocally(item)
        // The resolver and its transfers are retired before the paused state is made durable,
        // so no in-flight write can land on top of it.
        await cancelTransfers(gid: gid)
        guard var paused = download(gid: gid) else { return }
        paused.status = .paused
        paused.failureDescription = nil
        await commit(paused)
        // The retired transfers may have freed slots another gallery is waiting on.
        pumpAll()
    }

    func resume(gid: String) async {
        await restore()
        guard var item = download(gid: gid) else { return }
        resetPageOutcomes(gid: gid)
        // Signatures resolved before the interruption are usually spent; keeping them would
        // retry a dead URL until the user reached for the destructive Update All.
        let fresh = item.freshRemoteURLIndices(lifetime: Self.remoteURLLifetime)
        item.remoteURLs = item.remoteURLs.filter { fresh.contains($0.key) }
        item.remoteURLDates = item.remoteURLDates.filter { fresh.contains($0.key) }
        item.status = .preparing
        item.failureDescription = nil
        guard await commit(item) else { return }
        pumpAll()
    }

    func repair(gid: String) async {
        await restore()
        await cancelTransfers(gid: gid)
        guard let item = download(gid: gid) else { return }
        let verified = await persistence.existingFileNames(gid: gid, fileNames: item.fileNames)
        let dangling = Set(item.fileNames.keys).subtracting(verified.keys)
        // Only the references that were confirmed missing are dropped, so a page recorded
        // while the directory was being scanned survives the repair.
        guard var refreshed = download(gid: gid) else { return }
        for index in dangling {
            refreshed.fileNames[index] = nil
        }
        publishLocally(refreshed)
        await resume(gid: gid)
    }

    func updateAllPages(gid: String) async {
        await restore()
        guard download(gid: gid) != nil else { return }
        // Awaiting cancellation first guarantees no resolver or transfer from the outgoing
        // generation is still able to write into the manifest that replaces it.
        await cancelTransfers(gid: gid)
        await persistence.deletePageFiles(gid: gid)
        guard var item = download(gid: gid) else { return }
        item.generation = UUID()
        item.fileNames = [:]
        item.remoteURLs = [:]
        item.remoteURLDates = [:]
        item.status = .preparing
        item.failureDescription = nil
        item.updatedAt = Date()
        resetPageOutcomes(gid: gid)
        guard await commit(item) else { return }
        pumpAll()
    }

    func delete(gid: String) async {
        downloads.removeAll { $0.gid == gid }
        bumpRevision(gid: gid)
        await cancelTransfers(gid: gid)
        resetPageOutcomes(gid: gid)
        await persistence.deleteGallery(gid: gid)
        // A slot may have just been freed for a different gallery.
        pumpAll()
    }

    func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let snapshot = folders
        Task { [persistence] in
            await persistence.saveFolders(snapshot)
        }
    }

    func move(gid: String, to folder: String) {
        guard folders.contains(folder) else { return }
        update(gid: gid) {
            $0.folderName = folder
            $0.updatedAt = Date()
        }
    }

    func dismissStorageFailure() {
        storageFailure = nil
    }

    func localPageURLs(for download: GalleryDownload) -> [Int: URL] {
        download.fileNames.reduce(into: [:]) { result, entry in
            let url = DownloadPaths.galleryDirectory(download.gid).appendingPathComponent(entry.value)
            if FileManager.default.fileExists(atPath: url.path) {
                result[entry.key] = url
            }
        }
    }

    func handleEventsForBackgroundSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
        // A background relaunch has no downloads tab to trigger restoration for us.
        Task { [weak self] in
            await self?.restore()
        }
    }

    private func download(gid: String) -> GalleryDownload? {
        downloads.first { $0.gid == gid }
    }

    private func currentItem(gid: String, generation: UUID) -> GalleryDownload? {
        guard let item = download(gid: gid), item.generation == generation else { return nil }
        return item
    }

    // MARK: - Scheduling

    private func pump(gid: String) {
        guard let item = download(gid: gid),
              item.status == .preparing || item.status == .downloading
        else { return }
        guard resolvers[gid] == nil else {
            // A pass is already running; make sure the outcome that arrived meanwhile is
            // still examined once that pass releases the slot.
            pendingPumps.insert(gid)
            return
        }
        let token = UUID()
        let generation = item.generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runResolverPass(gid: gid, generation: generation, token: token)
            self.releaseResolver(gid: gid, token: token)
        }
        resolvers[gid] = ResolverRecord(token: token, generation: generation, task: task)
    }

    // Only the pass that still owns the slot may release it. A cancelled pass used to clear
    // the record of the pass that replaced it, which let a resumed download run unsupervised.
    private func releaseResolver(gid: String, token: UUID) {
        guard resolvers[gid]?.token == token else { return }
        resolvers[gid] = nil
        guard pendingPumps.remove(gid) != nil else { return }
        pump(gid: gid)
    }

    private func runResolverPass(gid: String, generation: UUID, token: UUID) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Resolve gallery download \(gid)"
        ) { [weak self] in
            Task { @MainActor in
                self?.resolvers[gid]?.task.cancel()
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        guard let item = currentItem(gid: gid, generation: generation) else { return }
        guard item.gallery.pageCount > 0 else {
            markFailed(gid: gid, generation: generation, message: "The gallery has no pages to download.")
            return
        }
        guard let galleryURL = item.gallery.galleryURL else {
            markFailed(gid: gid, generation: generation, message: "Gallery URL is unavailable.")
            return
        }

        let pending = await persistence.pendingIndices(
            gid: gid, pageCount: item.gallery.pageCount, fileNames: item.fileNames
        )
        guard isCurrentResolver(gid: gid, generation: generation, token: token) else { return }

        var inFlight = activeTransfers[gid] ?? []
        inFlight.formUnion(pagesAwaitingCommit[gid] ?? [])

        let schedulable = pending.filter { !inFlight.contains($0) && !isExhausted(gid: gid, index: $0) }
        guard !schedulable.isEmpty else {
            // Nothing left to start. Once the queue has fully drained the aggregate outcome
            // is decided from the per page records rather than from the last callback.
            if inFlight.isEmpty {
                await reconcile(gid: gid, generation: generation, pending: pending)
            }
            return
        }

        var slots = min(
            max(0, Self.maxConcurrentTransfers - inFlight.count),
            max(0, Self.maxTotalConcurrentTransfers - totalInFlightCount())
        )
        var consecutiveFailures = 0
        for index in schedulable {
            guard slots > 0, isCurrentResolver(gid: gid, generation: generation, token: token),
                  let snapshot = currentItem(gid: gid, generation: generation)
            else { return }

            let resolvedURL: URL
            if let cached = snapshot.freshRemoteURL(at: index, lifetime: Self.remoteURLLifetime) {
                resolvedURL = cached
            } else {
                do {
                    resolvedURL = try await resolveRemoteURL(
                        gid: gid, index: index, galleryURL: galleryURL, previewConfig: snapshot.previewConfig
                    )
                } catch {
                    guard isCurrentResolver(gid: gid, generation: generation, token: token) else { return }
                    recordPageFailure(
                        gid: gid, generation: generation, index: index,
                        message: describeDownloadError(error), invalidatesRemoteURL: true,
                        transferHasFinished: false
                    )
                    consecutiveFailures += 1
                    // A run of failures means the site or the network is unavailable. Stop the
                    // pass instead of hammering every remaining page; the retry budget per page
                    // still decides when the gallery is reported as failed.
                    guard consecutiveFailures < Self.maxConsecutiveResolutionFailures else { return }
                    continue
                }
            }
            consecutiveFailures = 0

            guard isCurrentResolver(gid: gid, generation: generation, token: token),
                  var scheduling = currentItem(gid: gid, generation: generation)
            else { return }
            scheduling.remoteURLs[index] = resolvedURL
            scheduling.remoteURLDates[index] = Date()
            scheduling.status = .downloading
            // The manifest that owns the transfer is durable before the transfer exists, so a
            // scheduled page can never outlive the record that describes it.
            guard await commit(scheduling) else { return }
            guard isCurrentResolver(gid: gid, generation: generation, token: token) else { return }
            scheduleTransfer(gid: gid, index: index, generation: generation, url: resolvedURL)
            slots -= 1
        }
    }

    // A pass may only keep working while it still owns the resolver slot, its generation is
    // still the live one and the gallery is still meant to be running. Cancellation alone is
    // not enough: `cancelTransfers` drops the record before the task observes the flag.
    private func isCurrentResolver(gid: String, generation: UUID, token: UUID) -> Bool {
        guard !Task.isCancelled, resolvers[gid]?.token == token,
              let item = currentItem(gid: gid, generation: generation),
              item.status == .preparing || item.status == .downloading
        else { return false }
        return true
    }

    private func scheduleTransfer(gid: String, index: Int, generation: UUID, url: URL) {
        var request = URLRequest(url: url)
        request.setValue("image/webp,image/png,image/gif,image/jpeg,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.makeTaskDescription(gid: gid, index: index, generation: generation)
        activeTransfers[gid, default: []].insert(index)
        task.resume()
    }

    private func totalInFlightCount() -> Int {
        activeTransfers.values.reduce(0) { $0 + $1.count }
            + pagesAwaitingCommit.values.reduce(0) { $0 + $1.count }
    }

    // A transfer leaves the window exactly once, when its terminal delegate callback has been
    // fully processed. Every gallery is then pumped, because a freed slot can unblock a
    // different gallery that was waiting on the application wide ceiling.
    private func transferDidFinish(gid: String, index: Int) {
        activeTransfers[gid]?.remove(index)
        if activeTransfers[gid]?.isEmpty == true { activeTransfers[gid] = nil }
    }

    private func pumpAll() {
        for item in downloads {
            pump(gid: item.gid)
        }
    }

    private func allSessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func cancelTransfers(gid: String) async {
        pendingPumps.remove(gid)
        checkpointTasks[gid]?.cancel()
        checkpointTasks[gid] = nil
        if let record = resolvers.removeValue(forKey: gid) {
            record.task.cancel()
            // Awaited, so a destructive replacement cannot start while the resolver is still
            // between a URL resolution and the commit that would schedule it.
            await record.task.value
        }
        let transfers = await allSessionTasks()
        transfers.filter { Self.taskIdentity($0.taskDescription)?.gid == gid }.forEach { $0.cancel() }
        pagesAwaitingCommit[gid] = nil
        activeTransfers[gid] = nil
    }

    private func resetPageOutcomes(gid: String) {
        pageFailures[gid] = nil
        pageAttempts[gid] = nil
        thumbnailCache[gid] = nil
        mpvKeyCache[gid] = nil
    }

    private func isExhausted(gid: String, index: Int) -> Bool {
        (pageAttempts[gid]?[index] ?? 0) >= Self.maxAttemptsPerPage
    }

    // MARK: - Resolution

    private func resolveRemoteURL(
        gid: String, index: Int, galleryURL: URL, previewConfig: PreviewConfig
    ) async throws -> URL {
        let pageNumber = previewConfig.pageNumber(index: index)
        let thumbnails = try await thumbnailURLs(gid: gid, galleryURL: galleryURL, pageNumber: pageNumber)
        guard let thumbnail = thumbnails[index] else { throw AppError.notFound }

        guard thumbnail.pathComponents.dropFirst().first == "mpv" else {
            // One page at a time. Resolving the whole batch up front produced a signed URL
            // for every remaining page, most of which expired before their slot came up.
            return try await GalleryNormalImageURLRequest(
                index: index, thumbnailURL: thumbnail
            ).response().get().1
        }

        let keys = try await mpvKeys(gid: gid, mpvURL: thumbnail)
        guard let gidValue = Int(gid), let imageKey = keys.1[index] else { throw AppError.parseFailed }
        return try await GalleryMPVImageURLRequest(
            gid: gidValue,
            index: index,
            mpvKey: keys.0,
            mpvImageKey: imageKey,
            skipServerIdentifier: nil
        ).response().get().0
    }

    private func thumbnailURLs(gid: String, galleryURL: URL, pageNumber: Int) async throws -> [Int: URL] {
        if let cached = thumbnailCache[gid]?[pageNumber] { return cached }
        let fetched = try await ThumbnailURLsRequest(
            galleryURL: galleryURL, pageNum: pageNumber
        ).response().get()
        thumbnailCache[gid, default: [:]][pageNumber] = fetched
        return fetched
    }

    private func mpvKeys(gid: String, mpvURL: URL) async throws -> (String, [Int: String]) {
        if let cached = mpvKeyCache[gid] { return cached }
        let fetched = try await MPVKeysRequest(mpvURL: mpvURL).response().get()
        mpvKeyCache[gid] = fetched
        return fetched
    }

    // MARK: - State

    // Progress-only updates reach the UI immediately and are checkpointed to disk on a
    // throttle, so a busy download does not rewrite the whole manifest once per page.
    private func publish(_ download: GalleryDownload) {
        publishLocally(download)
        scheduleCheckpoint(gid: download.gid)
    }

    // At most one pending checkpoint per gallery, and it reads the published state at write
    // time rather than carrying a snapshot. An in-flight checkpoint therefore cannot land
    // after a delete or an Update All and resurrect the state it captured earlier.
    private func scheduleCheckpoint(gid: String) {
        guard checkpointTasks[gid] == nil else { return }
        checkpointTasks[gid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.checkpointInterval)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.checkpointTasks[gid] = nil
            guard let item = self.download(gid: gid) else { return }
            await self.persistence.checkpoint(item)
        }
    }

    private func publishLocally(_ download: GalleryDownload, insertIfNeeded: Bool = false) {
        if let index = downloads.firstIndex(where: { $0.gid == download.gid }) {
            downloads[index] = download
        } else if insertIfNeeded {
            downloads.append(download)
        } else {
            // The gallery was deleted while this update was in flight; re-adding it would
            // resurrect a row whose files are gone.
            return
        }
        bumpRevision(gid: download.gid)
        sortDownloads()
    }

    private func bumpRevision(gid: String) {
        stateRevisions[gid] = (stateRevisions[gid] ?? 0) &+ 1
    }

    // Published before the write, never after it. Republishing the written snapshot once the
    // actor returned could undo a pause, a completed page or a delete that happened while the
    // write was in flight, leaving a download that is neither paused nor running.
    @discardableResult
    private func commit(_ download: GalleryDownload, insertIfNeeded: Bool = false) async -> Bool {
        let gid = download.gid
        publishLocally(download, insertIfNeeded: insertIfNeeded)
        let expected = stateRevisions[gid] ?? 0
        do {
            try await persistence.commit(download)
        } catch {
            storageFailure = "Could not save the download manifest: \(error.localizedDescription)"
            if (stateRevisions[gid] ?? 0) == expected, var failed = self.download(gid: gid) {
                failed.status = .failed
                failed.failureDescription = storageFailure
                publishLocally(failed)
            }
            return false
        }
        if (stateRevisions[gid] ?? 0) != expected, let current = self.download(gid: gid) {
            // Superseded during the write: leave the newer published state alone and make the
            // manifest match it instead.
            await persistence.checkpoint(current)
        }
        return true
    }

    private func update(gid: String, changes: (inout GalleryDownload) -> Void) {
        guard var item = download(gid: gid) else { return }
        changes(&item)
        publish(item)
    }

    private func markFailed(gid: String, generation: UUID, message: String) {
        guard var item = currentItem(gid: gid, generation: generation), item.status != .paused else { return }
        item.status = .failed
        item.failureDescription = message
        item.updatedAt = Date()
        publish(item)
    }

    // Runs only once nothing is in flight and nothing is schedulable. A sibling page's
    // success can no longer clear a failed page's description and leave the row downloading
    // with no task behind it.
    private func reconcile(gid: String, generation: UUID, pending: [Int]) async {
        guard var item = currentItem(gid: gid, generation: generation), item.status != .paused else { return }
        if pending.isEmpty {
            item.status = .completed
            item.failureDescription = nil
            resetPageOutcomes(gid: gid)
        } else {
            let failures = pageFailures[gid] ?? [:]
            let reason = pending.compactMap { failures[$0] }.first ?? "The pages could not be downloaded."
            item.status = .failed
            item.failureDescription = "\(pending.count) page(s) failed: \(reason)"
        }
        item.updatedAt = Date()
        await commit(item)
    }

    private func recordDownloadedPage(
        gid: String, index: Int, generation: UUID, staged: URL, fileExtension: String
    ) async {
        guard currentItem(gid: gid, generation: generation) != nil else {
            await persistence.discard(staged: staged)
            transferDidFinish(gid: gid, index: index)
            return
        }

        // Tracked while the promotion is in flight so a sibling completion cannot see this
        // page as pending and schedule a duplicate transfer for it.
        pagesAwaitingCommit[gid, default: []].insert(index)
        var promoted: String?
        var failure: Error?
        do {
            promoted = try await persistence.promote(
                staged: staged, gid: gid, index: index,
                fileExtension: fileExtension, generation: generation
            )
        } catch {
            failure = error
            await persistence.discard(staged: staged)
        }
        pagesAwaitingCommit[gid]?.remove(index)
        transferDidFinish(gid: gid, index: index)

        guard let fileName = promoted else {
            // Only a deleted gallery or a replaced generation may drop the bytes in silence.
            // A manifest that was merely unreadable for a moment has to be retried, or the
            // row would sit at .downloading forever with no callback left to wake it.
            if let failure, (failure as? DownloadPersistenceError)?.discardsPageSilently != true {
                recordPageFailure(
                    gid: gid, generation: generation, index: index,
                    message: describeDownloadError(failure), invalidatesRemoteURL: false,
                    transferHasFinished: false
                )
            } else {
                pumpAll()
            }
            return
        }

        guard var item = currentItem(gid: gid, generation: generation) else {
            pumpAll()
            return
        }
        item.fileNames[index] = fileName
        item.remoteURLs[index] = nil
        item.remoteURLDates[index] = nil
        if item.status != .paused {
            item.status = .downloading
        }
        pageFailures[gid]?[index] = nil
        publish(item)
        pumpAll()
    }

    // `transferHasFinished` is false for a resolution failure, which never occupied a slot.
    private func recordPageFailure(
        gid: String, generation: UUID, index: Int, message: String,
        invalidatesRemoteURL: Bool, transferHasFinished: Bool = true
    ) {
        if transferHasFinished { transferDidFinish(gid: gid, index: index) }
        guard var item = currentItem(gid: gid, generation: generation) else {
            pumpAll()
            return
        }
        pageFailures[gid, default: [:]][index] = message
        pageAttempts[gid, default: [:]][index, default: 0] += 1
        if invalidatesRemoteURL {
            // A rejected or spent signature must not be retried; the next pass re-resolves it.
            item.remoteURLs[index] = nil
            item.remoteURLDates[index] = nil
            publish(item)
        }
        pumpAll()
    }

    private func sortDownloads() {
        downloads.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func makeTaskDescription(gid: String, index: Int, generation: UUID) -> String {
        "\(gid)|\(index)|\(generation.uuidString)"
    }

    private nonisolated static func taskIdentity(_ description: String?) -> DownloadTaskIdentity? {
        guard let parts = description?.split(separator: "|"), parts.count == 3,
              let index = Int(parts[1]), let generation = UUID(uuidString: String(parts[2]))
        else { return nil }
        return DownloadTaskIdentity(gid: String(parts[0]), index: index, generation: generation)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let identity = Self.taskIdentity(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let statusCode = response?.statusCode
        let mimeType = response?.mimeType
        let expectedLength = downloadTask.countOfBytesExpectedToReceive
        pendingDelegateWork.enter()

        // Validation and staging are synchronous because the system temporary file is removed
        // as soon as this method returns; only the manifest update hops to the MainActor. The
        // transfer keeps its window slot until that update completes, so the page cannot be
        // scheduled a second time while it is being recorded.
        do {
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            let fileExtension = try PageValidator.validate(
                data, statusCode: statusCode, mimeType: mimeType, expectedLength: expectedLength
            )
            let staged = try DownloadPersistence.stage(location, fileExtension: fileExtension)
            Task { @MainActor [weak self] in
                defer { pendingDelegateWork.leave() }
                await self?.recordDownloadedPage(
                    gid: identity.gid, index: identity.index, generation: identity.generation,
                    staged: staged, fileExtension: fileExtension
                )
            }
        } catch {
            let message = describeDownloadError(error)
            // Rejected bytes always mean the resolved URL is spent (expired signature, quota
            // placeholder, error page), so it is invalidated and resolved again.
            let invalidates = error is PageValidationError
            Task { @MainActor [weak self] in
                defer { pendingDelegateWork.leave() }
                self?.recordPageFailure(
                    gid: identity.gid, generation: identity.generation, index: identity.index,
                    message: message, invalidatesRemoteURL: invalidates
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let identity = Self.taskIdentity(task.taskDescription) else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        let invalidates = invalidatesRemoteURL(nsError)
        pendingDelegateWork.enter()
        Task { @MainActor [weak self] in
            defer { pendingDelegateWork.leave() }
            self?.recordPageFailure(
                gid: identity.gid, generation: identity.generation, index: identity.index,
                message: error.localizedDescription, invalidatesRemoteURL: invalidates
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            await self?.finishBackgroundEvents()
        }
    }

    // The OS handler is what allows iOS to suspend the process, so it must not run while a
    // page is still only in staging, still being promoted, or recorded only in memory.
    // Resolver work needs no draining: a transfer's URL is always committed durably before
    // the transfer exists, and a resolver still waiting on the network has written nothing.
    private func finishBackgroundEvents() async {
        await restore()
        var waited = 0
        while !pendingDelegateWork.isEmpty, waited < Self.backgroundDrainAttempts {
            waited += 1
            try? await Task.sleep(nanoseconds: Self.backgroundDrainInterval)
        }
        await flushPendingCheckpoints()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    private func flushPendingCheckpoints() async {
        for gid in Array(checkpointTasks.keys) {
            checkpointTasks[gid]?.cancel()
            checkpointTasks[gid] = nil
            guard let item = download(gid: gid) else { continue }
            await persistence.checkpoint(item)
        }
    }
}

private extension Data {
    var knownImageFileExtension: String? {
        let bytes = [UInt8](prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: Array("GIF".utf8)) { return "gif" }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }
}

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @Binding private var setting: Setting
    private let blurRadius: Double

    @State private var keyword = ""
    @State private var selectedFolder: String?
    @State private var selectedDownload: GalleryDownload?
    @State private var newFolderName = ""
    @State private var showsNewFolderAlert = false

    init(setting: Binding<Setting>, blurRadius: Double) {
        _setting = setting
        self.blurRadius = blurRadius
    }

    private var filteredDownloads: [GalleryDownload] {
        manager.downloads.filter { item in
            let matchesFolder = selectedFolder == nil || item.folderName == selectedFolder
            let matchesKeyword = keyword.isEmpty
                || item.gallery.title.caseInsensitiveContains(keyword)
                || item.gallery.uploader?.caseInsensitiveContains(keyword) == true
            return matchesFolder && matchesKeyword
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    if let storageFailure = manager.storageFailure {
                        Text(storageFailure)
                            .font(.caption).foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground))
                            .onTapGesture { manager.dismissStorageFailure() }
                    }
                    downloadsContent
                }
            }
            .searchable(text: $keyword, prompt: L10n.Localizable.DownloadsView.Search.prompt)
            .navigationTitle(L10n.Localizable.DownloadsView.Title.downloads)
            .toolbar { toolbar }
        }
        .navigationViewStyle(.stack)
        .task { await manager.restore() }
        .fullScreenCover(item: $selectedDownload) { download in
            OfflineReadingContainer(
                download: download,
                imageURLs: manager.localPageURLs(for: download),
                setting: $setting,
                blurRadius: blurRadius,
                onDismiss: { selectedDownload = nil }
            )
        }
        .alert(L10n.Localizable.DownloadsView.Folder.new, isPresented: $showsNewFolderAlert) {
            TextField(L10n.Localizable.DownloadsView.Folder.name, text: $newFolderName)
            Button(L10n.Localizable.Common.Button.cancel, role: .cancel) { newFolderName = "" }
            Button(L10n.Localizable.Common.Button.confirm) {
                manager.createFolder(newFolderName)
                newFolderName = ""
            }
        }
    }

    @ViewBuilder private var downloadsContent: some View {
        if filteredDownloads.isEmpty {
            AlertView(
                symbol: .squareAndArrowDown,
                message: manager.downloads.isEmpty
                    ? L10n.Localizable.DownloadsView.Empty.downloads
                    : L10n.Localizable.DownloadsView.Empty.filtered
            ) { EmptyView() }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredDownloads) { item in
                DownloadRow(download: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if item.canReadOffline { selectedDownload = item }
                    }
                    .contextMenu { contextMenu(for: item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await manager.delete(gid: item.gid) }
                        } label: {
                            Label(L10n.Localizable.Common.Button.delete, systemImage: "trash")
                        }
                        if item.status == .downloading || item.status == .preparing {
                            Button { Task { await manager.pause(gid: item.gid) } } label: {
                                Label(L10n.Localizable.DownloadsView.Button.pause, systemImage: "pause.fill")
                            }
                            .tint(.indigo)
                        } else if item.status != .completed {
                            Button { Task { await manager.resume(gid: item.gid) } } label: {
                                Label(L10n.Localizable.DownloadsView.Button.resume, systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                    }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    selectedFolder = nil
                } label: {
                    Label(L10n.Localizable.DownloadsView.Folder.all, systemImage: "tray.full")
                }
                ForEach(manager.folders, id: \.self) { folder in
                    Button {
                        selectedFolder = folder
                    } label: {
                        Label(folder, systemImage: selectedFolder == folder ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button {
                    showsNewFolderAlert = true
                } label: {
                    Label(L10n.Localizable.DownloadsView.Folder.new, systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "folder")
            }
        }
    }

    @ViewBuilder private func contextMenu(for item: GalleryDownload) -> some View {
        if item.status == .downloading || item.status == .preparing {
            Button { Task { await manager.pause(gid: item.gid) } } label: {
                Label(L10n.Localizable.DownloadsView.Button.pause, systemImage: "pause.fill")
            }
        } else if item.status != .completed {
            Button { Task { await manager.resume(gid: item.gid) } } label: {
                Label(L10n.Localizable.DownloadsView.Button.resume, systemImage: "play.fill")
            }
        }
        Button { Task { await manager.repair(gid: item.gid) } } label: {
            Label(L10n.Localizable.DownloadsView.Button.repair, systemImage: "wrench.and.screwdriver")
        }
        Button { Task { await manager.updateAllPages(gid: item.gid) } } label: {
            Label(L10n.Localizable.DownloadsView.Button.update, systemImage: "arrow.clockwise")
        }
        Menu {
            ForEach(manager.folders, id: \.self) { folder in
                Button(folder) { manager.move(gid: item.gid, to: folder) }
            }
        } label: {
            Label(L10n.Localizable.DownloadsView.Button.move, systemImage: "folder")
        }
        Button(role: .destructive) { Task { await manager.delete(gid: item.gid) } } label: {
            Label(L10n.Localizable.Common.Button.delete, systemImage: "trash")
        }
    }
}

// fullScreenCover re-evaluates its content whenever the downloads list changes (e.g.
// another download makes progress); the reader's store must survive those
// re-evaluations or reading state resets mid-session.
private struct OfflineReadingContainer: View {
    @StateObject private var storeHolder: StoreHolder
    private let gid: String
    @Binding private var setting: Setting
    private let blurRadius: Double
    // Passing a dismiss callback is what tells ReadingView it is a standalone host: it runs
    // the full teardown and then invokes this exactly once, which clears the cover binding.
    private let onDismiss: () -> Void

    init(
        download: GalleryDownload,
        imageURLs: [Int: URL],
        setting: Binding<Setting>,
        blurRadius: Double,
        onDismiss: @escaping () -> Void
    ) {
        _storeHolder = StateObject(wrappedValue: StoreHolder(download: download, imageURLs: imageURLs))
        gid = download.gid
        _setting = setting
        self.blurRadius = blurRadius
        self.onDismiss = onDismiss
    }

    var body: some View {
        ReadingView(
            store: storeHolder.store,
            gid: gid,
            setting: $setting,
            blurRadius: blurRadius,
            onDismiss: onDismiss
        )
        .accentColor(setting.accentColor)
        .autoBlur(radius: blurRadius)
    }

    private final class StoreHolder: ObservableObject {
        let store: StoreOf<ReadingReducer>

        init(download: GalleryDownload, imageURLs: [Int: URL]) {
            store = Store(
                initialState: ReadingReducer.State.offline(download: download, imageURLs: imageURLs),
                reducer: ReadingReducer.init
            )
        }
    }
}

private struct DownloadRow: View {
    let download: GalleryDownload

    var body: some View {
        HStack(spacing: 12) {
            KFImage(download.gallery.coverURL)
                .placeholder { Color(.systemGray5) }
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text(download.gallery.title)
                    .font(.headline)
                    .lineLimit(2)
                ProgressView(value: download.progress)
                HStack {
                    Label(download.folderName, systemImage: "folder")
                    Spacer()
                    Text("\(download.completedCount)/\(download.gallery.pageCount)")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if let failure = download.failureDescription, download.status == .failed {
                    Text(failure).font(.caption2).foregroundColor(.red).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
