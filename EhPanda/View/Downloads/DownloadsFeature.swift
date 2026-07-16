//
//  DownloadsFeature.swift
//  EhPanda
//
//  iOS 16-compatible backport of the 3.0 offline download feature.
//

import SwiftUI
import Kingfisher
import ComposableArchitecture

enum GalleryDownloadStatus: String, Codable, Equatable {
    case preparing
    case downloading
    case paused
    case completed
    case failed
}

struct GalleryDownload: Codable, Equatable, Identifiable {
    static let manifestVersion = 1

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
    var gallery: Gallery
    var detail: GalleryDetail
    var previewConfig: PreviewConfig
    var folderName: String
    var status: GalleryDownloadStatus
    var fileNames: [Int: String]
    var remoteURLs: [Int: URL]
    var failureDescription: String?
    var updatedAt: Date

    init(
        gallery: Gallery,
        detail: GalleryDetail,
        previewConfig: PreviewConfig,
        folderName: String = DownloadManager.defaultFolder
    ) {
        version = Self.manifestVersion
        self.gallery = gallery
        self.detail = detail
        self.previewConfig = previewConfig
        self.folderName = folderName
        status = .preparing
        fileNames = [:]
        remoteURLs = [:]
        updatedAt = Date()
    }
}

private enum DownloadPaths {
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

    static func pageTemporary(_ gid: String, _ index: Int) -> URL {
        galleryDirectory(gid).appendingPathComponent("page-\(index).download")
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    nonisolated static let defaultFolder = "Default"
    private static let sessionIdentifier = "com.ehpanda.legacy.gallery-downloads"

    @Published private(set) var downloads = [GalleryDownload]()
    @Published private(set) var folders = [defaultFolder]

    private var resolutionTasks = [String: Task<Void, Never>]()
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
        loadFromDisk()
        Task { [weak self] in
            await self?.resumeInterruptedDownloads()
        }
    }

    func start(
        gallery: Gallery,
        detail: GalleryDetail,
        previewConfig: PreviewConfig,
        replacingExisting: Bool = false
    ) {
        if replacingExisting {
            deletePageFiles(gid: gallery.id)
        }
        var download = download(gid: gallery.id)
            ?? GalleryDownload(gallery: gallery, detail: detail, previewConfig: previewConfig)
        download.gallery = gallery
        download.detail = detail
        download.previewConfig = previewConfig
        download.status = .preparing
        download.failureDescription = nil
        download.updatedAt = Date()
        save(download)
        beginResolution(gid: gallery.id)
    }

    func pause(gid: String) {
        resolutionTasks[gid]?.cancel()
        resolutionTasks[gid] = nil
        update(gid: gid) {
            $0.status = .paused
            $0.failureDescription = nil
        }
        session.getAllTasks { tasks in
            tasks.filter { Self.taskIdentity($0.taskDescription)?.gid == gid }.forEach { $0.cancel() }
        }
    }

    func resume(gid: String) {
        guard download(gid: gid) != nil else { return }
        update(gid: gid) {
            $0.status = .preparing
            $0.failureDescription = nil
        }
        beginResolution(gid: gid)
    }

    func repair(gid: String) {
        removeMissingFileReferences(gid: gid)
        resume(gid: gid)
    }

    func updateAllPages(gid: String) {
        guard var item = download(gid: gid) else { return }
        pause(gid: gid)
        deletePageFiles(gid: gid)
        item.fileNames = [:]
        item.remoteURLs = [:]
        item.status = .preparing
        item.failureDescription = nil
        save(item)
        beginResolution(gid: gid)
    }

    func delete(gid: String) {
        pause(gid: gid)
        try? FileManager.default.removeItem(at: DownloadPaths.galleryDirectory(gid))
        downloads.removeAll { $0.gid == gid }
    }

    func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persistFolders()
    }

    func move(gid: String, to folder: String) {
        guard folders.contains(folder) else { return }
        update(gid: gid) { $0.folderName = folder }
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
    }

    private func download(gid: String) -> GalleryDownload? {
        downloads.first { $0.gid == gid }
    }

    private func beginResolution(gid: String) {
        guard resolutionTasks[gid] == nil else { return }
        resolutionTasks[gid] = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndSchedule(gid: gid)
            self.resolutionTasks[gid] = nil
        }
    }

    private func resolveAndSchedule(gid: String) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Resolve gallery download \(gid)"
        ) { [weak self] in
            Task { @MainActor in
                self?.resolutionTasks[gid]?.cancel()
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        guard var item = download(gid: gid), let galleryURL = item.gallery.galleryURL else {
            markFailed(gid: gid, message: "Gallery URL is unavailable.")
            return
        }

        let pending = (1...max(item.gallery.pageCount, 1)).filter { index in
            guard item.fileNames[index] == nil else { return false }
            return !FileManager.default.fileExists(
                atPath: DownloadPaths.galleryDirectory(gid)
                    .appendingPathComponent(item.fileNames[index] ?? "").path
            )
        }
        guard !pending.isEmpty else {
            update(gid: gid) { $0.status = .completed }
            return
        }

        var scheduledIndices = Set<Int>()
        let currentTasks = await allSessionTasks()
        currentTasks.compactMap { Self.taskIdentity($0.taskDescription) }
            .filter { $0.gid == gid }
            .forEach { scheduledIndices.insert($0.index) }

        do {
            var mpvKeys: (String, [Int: String])?
            var thumbnailBatches = [Int: [Int: URL]]()
            for pageIndex in pending where !Task.isCancelled {
                if scheduledIndices.contains(pageIndex) { continue }

                var remoteURL = item.remoteURLs[pageIndex]
                if remoteURL == nil {
                    let pageNumber = item.previewConfig.pageNumber(index: pageIndex)
                    let thumbnails: [Int: URL]
                    if let cached = thumbnailBatches[pageNumber] {
                        thumbnails = cached
                    } else {
                        let fetched = try await ThumbnailURLsRequest(
                            galleryURL: galleryURL,
                            pageNum: pageNumber
                        ).response().get()
                        thumbnailBatches[pageNumber] = fetched
                        thumbnails = fetched
                    }
                    guard let thumbnail = thumbnails[pageIndex] else { throw AppError.notFound }

                    if thumbnail.pathComponents.dropFirst().first == "mpv" {
                        if mpvKeys == nil {
                            mpvKeys = try await MPVKeysRequest(mpvURL: thumbnail).response().get()
                        }
                        guard let gidValue = Int(gid), let keys = mpvKeys,
                              let imageKey = keys.1[pageIndex]
                        else { throw AppError.parseFailed }
                        remoteURL = try await GalleryMPVImageURLRequest(
                            gid: gidValue,
                            index: pageIndex,
                            mpvKey: keys.0,
                            mpvImageKey: imageKey,
                            skipServerIdentifier: nil
                        ).response().get().0
                    } else {
                        let batch = thumbnails.filter { index, _ in
                            pending.contains(index)
                                && !scheduledIndices.contains(index)
                                && item.fileNames[index] == nil
                        }
                        let result = try await GalleryNormalImageURLsRequest(
                            thumbnailURLs: batch
                        ).response().get()
                        for (index, url) in result.0 {
                            item.remoteURLs[index] = url
                        }
                        item.status = .downloading
                        item.updatedAt = Date()
                        save(item)
                        for (index, url) in result.0 {
                            scheduleDownload(gid: gid, index: index, url: url)
                            scheduledIndices.insert(index)
                        }
                        guard result.0[pageIndex] != nil else { throw AppError.notFound }
                        continue
                    }
                }

                guard let remoteURL else { throw AppError.notFound }
                item.remoteURLs[pageIndex] = remoteURL
                item.status = .downloading
                item.updatedAt = Date()
                save(item)
                scheduleDownload(gid: gid, index: pageIndex, url: remoteURL)
            }
        } catch is CancellationError {
            return
        } catch {
            markFailed(gid: gid, message: error.localizedDescription)
        }
    }

    private func scheduleDownload(gid: String, index: Int, url: URL) {
        var request = URLRequest(url: url)
        request.setValue("image/webp,image/png,image/gif,image/jpeg,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.makeTaskDescription(gid: gid, index: index)
        task.resume()
    }

    private func allSessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func resumeInterruptedDownloads() async {
        for item in downloads where [.preparing, .downloading].contains(item.status) {
            beginResolution(gid: item.gid)
        }
    }

    private func loadFromDisk() {
        try? FileManager.default.createDirectory(
            at: DownloadPaths.root,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if let data = try? Data(contentsOf: DownloadPaths.folders),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            folders = Array(Set(stored + [Self.defaultFolder])).sorted()
        }

        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: DownloadPaths.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        downloads = directories.compactMap { directory in
            let manifest = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  var item = try? JSONDecoder().decode(GalleryDownload.self, from: data),
                  item.version == GalleryDownload.manifestVersion
            else { return nil }
            if item.status == .downloading || item.status == .preparing {
                item.status = .preparing
            }
            return item
        }
        sortDownloads()
    }

    private func persistFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: DownloadPaths.folders, options: .atomic)
    }

    private func save(_ download: GalleryDownload) {
        var download = download
        download.updatedAt = Date()
        let directory = DownloadPaths.galleryDirectory(download.gid)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if let data = try? JSONEncoder().encode(download) {
            try? data.write(to: DownloadPaths.manifest(download.gid), options: .atomic)
        }
        if let index = downloads.firstIndex(where: { $0.gid == download.gid }) {
            downloads[index] = download
        } else {
            downloads.append(download)
        }
        sortDownloads()
    }

    private func update(gid: String, changes: (inout GalleryDownload) -> Void) {
        guard var item = download(gid: gid) else { return }
        changes(&item)
        save(item)
    }

    private func markFailed(gid: String, message: String) {
        update(gid: gid) {
            guard $0.status != .paused else { return }
            $0.status = .failed
            $0.failureDescription = message
        }
    }

    private func removeMissingFileReferences(gid: String) {
        update(gid: gid) { item in
            item.fileNames = item.fileNames.filter { _, fileName in
                FileManager.default.fileExists(
                    atPath: DownloadPaths.galleryDirectory(gid).appendingPathComponent(fileName).path
                )
            }
        }
    }

    private func deletePageFiles(gid: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: DownloadPaths.galleryDirectory(gid),
            includingPropertiesForKeys: nil
        ) else { return }
        files.filter { $0.lastPathComponent.hasPrefix("page-") }.forEach {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    private func sortDownloads() {
        downloads.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func makeTaskDescription(gid: String, index: Int) -> String {
        "\(gid)|\(index)"
    }

    private nonisolated static func taskIdentity(_ description: String?) -> (gid: String, index: Int)? {
        guard let parts = description?.split(separator: "|"), parts.count == 2,
              let index = Int(parts[1]) else { return nil }
        return (String(parts[0]), index)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let identity = Self.taskIdentity(downloadTask.taskDescription) else { return }
        do {
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            guard let fileExtension = data.knownImageFileExtension else { throw AppError.parseFailed }
            let directory = DownloadPaths.galleryDirectory(identity.gid)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileName = "page-\(identity.index).\(fileExtension)"
            let destination = directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor [weak self] in
                self?.recordDownloadedPage(gid: identity.gid, index: identity.index, fileName: fileName)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.markFailed(gid: identity.gid, message: error.localizedDescription)
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
        guard nsError.code != NSURLErrorCancelled else { return }
        Task { @MainActor [weak self] in
            self?.markFailed(gid: identity.gid, message: error.localizedDescription)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let handler = self?.backgroundCompletionHandler
            self?.backgroundCompletionHandler = nil
            handler?()
        }
    }

    private func recordDownloadedPage(gid: String, index: Int, fileName: String) {
        update(gid: gid) { item in
            item.fileNames[index] = fileName
            item.failureDescription = nil
            item.status = item.fileNames.count >= item.gallery.pageCount ? .completed : .downloading
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
                if filteredDownloads.isEmpty {
                    AlertView(
                        symbol: .squareAndArrowDown,
                        message: manager.downloads.isEmpty
                            ? L10n.Localizable.DownloadsView.Empty.downloads
                            : L10n.Localizable.DownloadsView.Empty.filtered
                    ) { EmptyView() }
                    .padding()
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
                                    manager.delete(gid: item.gid)
                                } label: {
                                    Label(L10n.Localizable.Common.Button.delete, systemImage: "trash")
                                }
                                if item.status == .downloading || item.status == .preparing {
                                    Button { manager.pause(gid: item.gid) } label: {
                                        Label(L10n.Localizable.DownloadsView.Button.pause, systemImage: "pause.fill")
                                    }
                                    .tint(.indigo)
                                } else if item.status != .completed {
                                    Button { manager.resume(gid: item.gid) } label: {
                                        Label(L10n.Localizable.DownloadsView.Button.resume, systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $keyword, prompt: L10n.Localizable.DownloadsView.Search.prompt)
            .navigationTitle(L10n.Localizable.DownloadsView.Title.downloads)
            .toolbar { toolbar }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(item: $selectedDownload) { download in
            let urls = manager.localPageURLs(for: download)
            ReadingView(
                store: Store(
                    initialState: ReadingReducer.State.offline(download: download, imageURLs: urls),
                    reducer: ReadingReducer.init
                ),
                gid: download.gid,
                setting: $setting,
                blurRadius: blurRadius
            )
            .accentColor(setting.accentColor)
            .autoBlur(radius: blurRadius)
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
            Button { manager.pause(gid: item.gid) } label: {
                Label(L10n.Localizable.DownloadsView.Button.pause, systemImage: "pause.fill")
            }
        } else if item.status != .completed {
            Button { manager.resume(gid: item.gid) } label: {
                Label(L10n.Localizable.DownloadsView.Button.resume, systemImage: "play.fill")
            }
        }
        Button { manager.repair(gid: item.gid) } label: {
            Label(L10n.Localizable.DownloadsView.Button.repair, systemImage: "wrench.and.screwdriver")
        }
        Button { manager.updateAllPages(gid: item.gid) } label: {
            Label(L10n.Localizable.DownloadsView.Button.update, systemImage: "arrow.clockwise")
        }
        Menu {
            ForEach(manager.folders, id: \.self) { folder in
                Button(folder) { manager.move(gid: item.gid, to: folder) }
            }
        } label: {
            Label(L10n.Localizable.DownloadsView.Button.move, systemImage: "folder")
        }
        Button(role: .destructive) { manager.delete(gid: item.gid) } label: {
            Label(L10n.Localizable.Common.Button.delete, systemImage: "trash")
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
