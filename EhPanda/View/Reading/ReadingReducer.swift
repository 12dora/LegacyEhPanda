//
//  ReadingReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/22.
//

import SwiftUI
import ComposableArchitecture

struct ReadingReducer: Reducer {
    enum Route: Equatable {
        case hud
        case share(ShareItem)
        case readingSetting
    }

    enum ShareItem: Equatable {
        var associatedValue: Any {
            switch self {
            case .data(let data):
                return data
            case .image(let image):
                return image
            }
        }
        case data(Data)
        case image(UIImage)
    }

    enum ImageAction {
        case copy(Bool)
        case save(Bool)
        case share(Bool)
    }

    private enum CancelID: CaseIterable {
        case fetchImage
        case fetchDatabaseInfos
        case fetchPreviewURLs
        case fetchThumbnailURLs
        case fetchPrioritizedNormalImageURL
        case fetchNormalImageURLs
        case refetchNormalImageURLs
        case fetchMPVKeys
        case fetchMPVImageURL
    }

    // Persistence is coalesced per gallery, so its cancellation identity has to carry
    // the GID instead of being one process-wide constant.
    private struct ReadingProgressID: Hashable {
        let gid: String
    }
    private struct URLCheckpointID: Hashable {
        let gid: String
    }

    struct State: Equatable {
        @BindingState var route: Route?
        var gallery: Gallery = .empty
        var galleryDetail: GalleryDetail?
        var isOffline = false

        var readingProgress: Int = 1
        var initialReadingProgress: Int?
        var hudConfig: AppToastConfig = .loading

        var webImageLoadSuccessIndices = Set<Int>()
        var webImageAutomaticRetryCounts = [Int: Int]()
        var imageURLLoadingStates = [Int: LoadingState]()
        var previewLoadingStates = [Int: LoadingState]()
        var databaseLoadingState: LoadingState = .loading
        var previewConfig: PreviewConfig = .normal(rows: 4)

        var previewURLs = [Int: URL]()

        var thumbnailURLs = [Int: URL]()
        var imageURLs = [Int: URL]()
        var originalImageURLs = [Int: URL]()

        // URL resolution scheduling. Thumbnail pages are shared by many images, so coalesce
        // page requests while retaining every image that asked for the result.
        var prioritizedImageIndex = 1
        var loadingThumbnailPageNumbers = Set<Int>()
        var pendingThumbnailIndices = [Int: Set<Int>]()
        var pendingNormalImageURLIndices = Set<Int>()
        var prioritizedNormalImageURLLoadingIndex: Int?
        var normalImageURLBatchIndices = Set<Int>()
        var isNormalImageURLBatchLoading = false

        // Refetching is the path every failed page and every retry-all lands on, and it
        // had no ceiling at all. Fixed slots, drained by completions.
        var refetchingNormalImageURLIndices = Set<Int>()
        var pendingNormalImageURLRefetchIndices = [Int]()

        // Preview pages are shared by 20/40 adjacent image indices; key the in-flight
        // request by page and fan the single result out to every waiting index.
        var loadingPreviewPageNumbers = Set<Int>()
        var pendingPreviewIndices = [Int: Set<Int>]()

        var mpvKey: String?
        var mpvImageKeys = [Int: String]()
        var mpvSkipServerIdentifiers = [Int: String]()
        var isMPVKeysLoading = false
        var mpvImageURLLoadingIndices = Set<Int>()
        var pendingMPVImageURLRequests = [MPVImageURLRequest]()

        // Persistence is coalesced instead of written per delta: every small update used
        // to decode, merge and re-encode the whole growing JSON blob.
        var pendingReadingProgress: Int?
        var pendingPreviewURLs = [Int: URL]()
        var pendingThumbnailURLs = [Int: URL]()
        var pendingImageURLs = [Int: URL]()
        var pendingOriginalImageURLs = [Int: URL]()

        @BindingState var showsPanel = false
        @BindingState var showsSliderPreview = false

        static let maxConcurrentMPVImageURLRequests = 3
        static let maxConcurrentNormalImageURLRefetches = 3

        struct MPVImageURLRequest: Equatable {
            let index: Int
            let isRefresh: Bool
        }

        // Parsed and persisted page counts can be zero or negative, and every
        // `1...pageCount` the reader builds would trap on such a gallery. One validated
        // count is used everywhere instead.
        var validPageCount: Int {
            max(1, gallery.pageCount)
        }

        // Update
        func update<T>(stored: inout [Int: T], new: [Int: T], replaceExisting: Bool = true) {
            guard !new.isEmpty else { return }
            stored = stored.merging(new, uniquingKeysWith: { stored, new in replaceExisting ? new : stored })
        }
        mutating func updatePreviewURLs(_ previewURLs: [Int: URL]) {
            update(stored: &self.previewURLs, new: previewURLs)
        }
        mutating func updateThumbnailURLs(_ thumbnailURLs: [Int: URL]) {
            update(stored: &self.thumbnailURLs, new: thumbnailURLs)
        }
        mutating func updateImageURLs(_ imageURLs: [Int: URL], _ originalImageURLs: [Int: URL]) {
            update(stored: &self.imageURLs, new: imageURLs)
            update(stored: &self.originalImageURLs, new: originalImageURLs)
        }

        // Image
        func containerDataSource(setting: Setting, isLandscape: Bool = DeviceUtil.isLandscape) -> [Int] {
            let pageCount = validPageCount
            let defaultData = Array(1...pageCount)
            guard isLandscape && setting.enablesDualPageMode
                    && setting.readingDirection != .vertical
            else { return defaultData }

            let data = setting.exceptCover
                ? [1] + Array(stride(from: 2, through: pageCount, by: 2))
                : Array(stride(from: 1, through: pageCount, by: 2))

            return data
        }
        func imageContainerConfigs(
            index: Int, setting: Setting, isLandscape: Bool = DeviceUtil.isLandscape
        ) -> ImageStackConfig {
            let direction = setting.readingDirection
            let isReversed = direction == .rightToLeft
            let isFirstSingle = setting.exceptCover
            let isFirstPageAndSingle = index == 1 && isFirstSingle
            let isDualPage = isLandscape && setting.enablesDualPageMode && direction != .vertical
            let firstIndex = isDualPage && isReversed && !isFirstPageAndSingle ? index + 1 : index
            let secondIndex = firstIndex + (isReversed ? -1 : 1)
            let pageCount = validPageCount
            let isValidFirstRange = firstIndex >= 1 && firstIndex <= pageCount
            let isValidSecondRange = isFirstSingle
                ? secondIndex >= 2 && secondIndex <= pageCount
                : secondIndex >= 1 && secondIndex <= pageCount
            return .init(
                firstIndex: firstIndex, secondIndex: secondIndex, isFirstAvailable: isValidFirstRange,
                isSecondAvailable: !isFirstPageAndSingle && isValidSecondRange && isDualPage
            )
        }

        static func prefetchCandidateIndices(center: Int, pageCount: Int, limit: Int) -> [Int] {
            guard pageCount > 1, limit > 0, (1...pageCount).contains(center) else { return [] }
            var result = [Int]()
            for distance in 1..<pageCount where result.count < limit {
                let forward = center + distance
                if forward <= pageCount { result.append(forward) }
                if result.count == limit { break }
                let backward = center - distance
                if backward >= 1 { result.append(backward) }
            }
            return result
        }

        func allowsAutomaticImageURLFetch(at index: Int) -> Bool {
            guard let loadingState = imageURLLoadingStates[index] else { return true }
            return loadingState == .idle
        }

        func clampedProgress(_ progress: Int) -> Int {
            min(max(progress, 1), validPageCount)
        }

        mutating func enqueueMPVImageURLRequest(_ request: MPVImageURLRequest) {
            guard !pendingMPVImageURLRequests.contains(where: { $0.index == request.index })
            else { return }
            pendingMPVImageURLRequests.append(request)
        }

        mutating func dequeueMPVImageURLRequest() -> MPVImageURLRequest? {
            // Nearest to the page being read first: MPV resolves one page per request.
            guard !pendingMPVImageURLRequests.isEmpty else { return nil }
            let target = prioritizedImageIndex
            let position = pendingMPVImageURLRequests.indices.min {
                let leftDistance = abs(pendingMPVImageURLRequests[$0].index - target)
                let rightDistance = abs(pendingMPVImageURLRequests[$1].index - target)
                return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
            }
            guard let position else { return nil }
            return pendingMPVImageURLRequests.remove(at: position)
        }

        mutating func enqueueNormalImageURLRefetch(_ index: Int) {
            guard !pendingNormalImageURLRefetchIndices.contains(index) else { return }
            pendingNormalImageURLRefetchIndices.append(index)
        }

        mutating func dequeueNormalImageURLRefetch() -> Int? {
            guard !pendingNormalImageURLRefetchIndices.isEmpty else { return nil }
            let target = prioritizedImageIndex
            let position = pendingNormalImageURLRefetchIndices.indices.min {
                let leftDistance = abs(pendingNormalImageURLRefetchIndices[$0] - target)
                let rightDistance = abs(pendingNormalImageURLRefetchIndices[$1] - target)
                return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
            }
            guard let position else { return nil }
            return pendingNormalImageURLRefetchIndices.remove(at: position)
        }

        mutating func resetPendingPersistence() {
            pendingPreviewURLs = .init()
            pendingThumbnailURLs = .init()
            pendingImageURLs = .init()
            pendingOriginalImageURLs = .init()
        }

        mutating func setInitialReadingProgress(_ progress: Int) {
            let clamped = clampedProgress(progress)
            readingProgress = clamped
            initialReadingProgress = clamped
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)

        case toggleShowsPanel
        case setOrientationPortrait(Bool)
        case onPerformDismiss
        case onAppear(String, Bool)

        case onWebImageRetry(Int)
        case onWebImageSucceeded(Int)
        case onWebImageFailed(Int)
        case reloadAllWebImages
        case retryAllFailedWebImages

        case copyImage(URL)
        case saveImage(URL)
        case saveImageDone(Bool)
        case shareImage(URL)
        case fetchImage(ImageAction, URL)
        case fetchImageDone(ImageAction, URL, Result<ReaderImageAsset, Error>)

        case syncReadingProgress(Int)
        case commitReadingProgress
        case syncPreviewURLs([Int: URL])
        case syncThumbnailURLs([Int: URL])
        case syncImageURLs([Int: URL], [Int: URL])
        case commitURLCheckpoint

        case teardown
        case fetchDatabaseInfos(String)
        case fetchDatabaseInfosDone(GalleryState)
        case fetchOfflineReadingProgressDone(Int)

        case fetchPreviewURLs(Int)
        case fetchPreviewURLsDone(Int, Result<[Int: URL], AppError>)

        case fetchImageURLs(Int)
        case refetchImageURLs(Int)
        case prefetchImages(Int, Int)

        case fetchThumbnailURLs(Int)
        case fetchThumbnailURLsDone(Int, Int, Result<[Int: URL], AppError>)
        case fetchNormalImageURL(Int, URL)
        case fetchNormalImageURLDone(Int, Result<(Int, URL, URL?), AppError>)
        case fetchPendingNormalImageURLs(Int)
        case fetchNormalImageURLs(Int, [Int: URL])
        case fetchNormalImageURLsDone(Int, [Int], Result<([Int: URL], [Int: URL]), AppError>)
        case refetchNormalImageURLs(Int)
        case refetchNormalImageURLsDone(Int, Result<([Int: URL], HTTPURLResponse?), AppError>)

        case fetchMPVKeys(Int, URL)
        case fetchMPVKeysDone(Int, Result<(String, [Int: String]), AppError>)
        case fetchMPVImageURL(Int, Bool)
        case fetchMPVImageURLDone(Int, Result<(URL, URL?, String), AppError>)
    }

    @Dependency(\.appDelegateClient) private var appDelegateClient
    @Dependency(\.clipboardClient) private var clipboardClient
    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.cookieClient) private var cookieClient
    @Dependency(\.deviceClient) private var deviceClient
    @Dependency(\.imageClient) private var imageClient
    @Dependency(\.urlClient) private var urlClient

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding(\.$showsSliderPreview):
                return .run(operation: { _ in hapticsClient.generateFeedback(.soft) })

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return .none

            case .toggleShowsPanel:
                state.showsPanel.toggle()
                return .none

            case .setOrientationPortrait(let isPortrait):
                var effects = [Effect<Action>]()
                if isPortrait {
                    effects.append(.run(operation: { _ in appDelegateClient.setPortraitOrientationMask() }))
                    effects.append(.run(operation: { _ in await appDelegateClient.setPortraitOrientation() }))
                } else {
                    effects.append(.run(operation: { _ in appDelegateClient.setAllOrientationMask() }))
                }
                return .merge(effects)

            case .onPerformDismiss:
                return .run(operation: { _ in hapticsClient.generateFeedback(.light) })

            case .onAppear(let gid, let enablesLandscape):
                var effects: [Effect<Action>] = state.isOffline
                    ? [
                        // Offline state carries local image URLs but the reading
                        // progress still lives in the shared database.
                        .run { [gid = state.gallery.id] send in
                            let progress = await databaseClient
                                .fetchGalleryState(gid: gid)?.readingProgress ?? 0
                            await send(.fetchOfflineReadingProgressDone(progress))
                        }
                    ]
                    : [.send(.fetchDatabaseInfos(gid))]
                if enablesLandscape {
                    effects.append(.send(.setOrientationPortrait(false)))
                }
                return .merge(effects)

            case .onWebImageRetry(let index):
                state.webImageAutomaticRetryCounts[index] = 0
                if state.isOffline {
                    state.imageURLLoadingStates[index] = .idle
                    return .none
                }
                return .send(.refetchImageURLs(index))

            case .onWebImageSucceeded(let index):
                state.imageURLLoadingStates[index] = .idle
                state.webImageAutomaticRetryCounts[index] = nil
                state.webImageLoadSuccessIndices.insert(index)
                return .none

            case .onWebImageFailed(let index):
                state.imageURLLoadingStates[index] = .failed(.webImageFailed)
                guard !state.isOffline,
                      state.webImageAutomaticRetryCounts[index, default: 0] < 1
                else { return .none }
                state.webImageAutomaticRetryCounts[index, default: 0] += 1
                return .send(.refetchImageURLs(index))

            case .reloadAllWebImages:
                guard !state.isOffline else { return .none }
                state.previewURLs = .init()
                state.thumbnailURLs = .init()
                state.imageURLs = .init()
                state.originalImageURLs = .init()
                state.mpvKey = nil
                state.mpvImageKeys = .init()
                state.mpvSkipServerIdentifiers = .init()
                state.isMPVKeysLoading = false
                state.mpvImageURLLoadingIndices = .init()
                state.pendingMPVImageURLRequests = .init()
                state.webImageAutomaticRetryCounts = .init()
                state.loadingThumbnailPageNumbers = .init()
                state.pendingThumbnailIndices = .init()
                state.loadingPreviewPageNumbers = .init()
                state.pendingPreviewIndices = .init()
                state.pendingNormalImageURLIndices = .init()
                state.refetchingNormalImageURLIndices = .init()
                state.pendingNormalImageURLRefetchIndices = .init()
                state.prioritizedNormalImageURLLoadingIndex = nil
                state.normalImageURLBatchIndices = .init()
                state.isNormalImageURLBatchLoading = false
                state.resetPendingPersistence()
                let urlCancelIDs: [CancelID] = [
                    .fetchPreviewURLs, .fetchThumbnailURLs, .fetchPrioritizedNormalImageURL,
                    .fetchNormalImageURLs, .refetchNormalImageURLs,
                    .fetchMPVKeys, .fetchMPVImageURL
                ]
                return .merge(
                    .merge(urlCancelIDs.map(Effect.cancel(id:))),
                    .cancel(id: URLCheckpointID(gid: state.gallery.id)),
                    .run { _ in imageClient.prefetchImages([]) },
                    .run { [state] _ in
                        let result = await databaseClient.removeImageURLs(gid: state.gallery.id)
                        if case .failure(let error) = result {
                            Logger.error("Failed to remove reader image URLs.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }
                )

            case .retryAllFailedWebImages:
                var retryIndices = [Int]()
                state.imageURLLoadingStates.forEach { (index, loadingState) in
                    if case .failed = loadingState {
                        state.imageURLLoadingStates[index] = .idle
                        state.webImageAutomaticRetryCounts[index] = 0
                        if !state.isOffline {
                            retryIndices.append(index)
                        }
                    }
                }
                state.previewLoadingStates.forEach { (index, loadingState) in
                    if case .failed = loadingState {
                        state.previewLoadingStates[index] = .idle
                    }
                }
                guard !retryIndices.isEmpty else { return .none }
                // Recovering a long gallery used to create one unbounded refetch effect
                // per failed page. The requests now enter the MPV and normal-refetch
                // schedulers below, which hold a fixed number of slots and admit the next
                // page only when one completes; nearest-first ordering is preserved both
                // in the dispatch order here and in how those queues are drained.
                let target = state.prioritizedImageIndex
                let orderedRetryIndices = retryIndices.sorted {
                    let leftDistance = abs($0 - target)
                    let rightDistance = abs($1 - target)
                    return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
                }
                return .merge(orderedRetryIndices.map { .send(.refetchImageURLs($0)) })

            case .copyImage(let imageURL):
                return .send(.fetchImage(.copy(imageURL.isAnimatedImage), imageURL))

            case .saveImage(let imageURL):
                return .send(.fetchImage(.save(imageURL.isAnimatedImage), imageURL))

            case .saveImageDone(let isSucceeded):
                state.hudConfig = isSucceeded ? .savedToPhotoLibrary : .error
                return .send(.setNavigation(.hud))

            case .shareImage(let imageURL):
                return .send(.fetchImage(.share(imageURL.isAnimatedImage), imageURL))

            case .fetchImage(let action, let imageURL):
                // The original bytes are needed, not just a decoded image: export must
                // write the source container instead of a Kingfisher re-encode.
                return .run { send in
                    let result = await imageClient.loadReaderImageAsset(imageURL, nil)
                    await send(.fetchImageDone(action, imageURL, result))
                }
                .cancellable(id: CancelID.fetchImage)

            case .fetchImageDone(let action, let imageURL, let result):
                if case .success(let asset) = result {
                    switch action {
                    case .copy(let isAnimated):
                        state.hudConfig = .copiedToClipboardSucceeded
                        return .merge(
                            .send(.setNavigation(.hud)),
                            .run(operation: { _ in
                                clipboardClient.saveImage(asset.image, isAnimated || asset.isAnimated)
                            })
                        )
                    case .save:
                        return .run { send in
                            let success = await imageClient.saveImageToPhotoLibrary(asset, imageURL)
                            await send(.saveImageDone(success))
                        }
                    case .share(let isAnimated):
                        if isAnimated || asset.isAnimated {
                            return .send(.setNavigation(.share(.data(asset.data))))
                        } else {
                            return .send(.setNavigation(.share(.image(asset.image))))
                        }
                    }
                } else {
                    state.hudConfig = .error
                    return .send(.setNavigation(.hud))
                }

            case .syncReadingProgress(let progress):
                // Every centered-page update used to start its own main-actor fetch,
                // update and save. Keep the latest value here and write it once the
                // reader settles, cancelling any in-flight debounce for this gallery.
                let clamped = state.clampedProgress(progress)
                guard state.pendingReadingProgress != clamped else { return .none }
                state.pendingReadingProgress = clamped
                return .run { send in
                    try await Task.sleep(for: .milliseconds(600))
                    await send(.commitReadingProgress)
                }
                .cancellable(id: ReadingProgressID(gid: state.gallery.id), cancelInFlight: true)

            case .commitReadingProgress:
                guard let progress = state.pendingReadingProgress else { return .none }
                state.pendingReadingProgress = nil
                return .run { [gid = state.gallery.id] _ in
                    let result = await databaseClient.updateReadingProgress(gid: gid, progress: progress)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist reading progress.", context: [
                            "gid": gid, "progress": progress, "error": "\(error)"
                        ])
                    }
                }

            case .syncPreviewURLs(let previewURLs):
                state.pendingPreviewURLs.merge(previewURLs, uniquingKeysWith: { _, new in new })
                return scheduleURLCheckpoint(gid: state.gallery.id)

            case .syncThumbnailURLs(let thumbnailURLs):
                state.pendingThumbnailURLs.merge(thumbnailURLs, uniquingKeysWith: { _, new in new })
                return scheduleURLCheckpoint(gid: state.gallery.id)

            case .syncImageURLs(let imageURLs, let originalImageURLs):
                state.pendingImageURLs.merge(imageURLs, uniquingKeysWith: { _, new in new })
                state.pendingOriginalImageURLs.merge(
                    originalImageURLs, uniquingKeysWith: { _, new in new }
                )
                return scheduleURLCheckpoint(gid: state.gallery.id)

            case .commitURLCheckpoint:
                let previewURLs = state.pendingPreviewURLs
                let thumbnailURLs = state.pendingThumbnailURLs
                let imageURLs = state.pendingImageURLs
                let originalImageURLs = state.pendingOriginalImageURLs
                state.resetPendingPersistence()
                guard !previewURLs.isEmpty || !thumbnailURLs.isEmpty
                        || !imageURLs.isEmpty || !originalImageURLs.isEmpty
                else { return .none }
                // One fetch, one merge pass and one save per checkpoint: the per-kind
                // writers each ran their own main-actor fetch/decode/encode/save cycle.
                return .run { [gid = state.gallery.id] _ in
                    let result = await databaseClient.updateGalleryState(gid: gid) { galleryStateMO in
                        Self.mergeStoredURLs(&galleryStateMO.previewURLs, with: previewURLs)
                        Self.mergeStoredURLs(&galleryStateMO.thumbnailURLs, with: thumbnailURLs)
                        Self.mergeStoredURLs(&galleryStateMO.imageURLs, with: imageURLs)
                        Self.mergeStoredURLs(&galleryStateMO.originalImageURLs, with: originalImageURLs)
                    }
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist reader image URLs.", context: [
                            "gid": gid, "error": "\(error)"
                        ])
                    }
                }

            case .teardown:
                var effects: [Effect<Action>] = [
                    .merge(CancelID.allCases.map(Effect.cancel(id:))),
                    // Flushing has to outlive the debounce timers that are cancelled here.
                    .cancel(id: ReadingProgressID(gid: state.gallery.id)),
                    .cancel(id: URLCheckpointID(gid: state.gallery.id)),
                    .send(.commitReadingProgress),
                    .send(.commitURLCheckpoint),
                    .run { _ in imageClient.prefetchImages([]) }
                ]
                if !deviceClient.isPad() {
                    effects.append(.send(.setOrientationPortrait(true)))
                }
                return .merge(effects)

            case .fetchDatabaseInfos(let gid):
                guard let gallery = databaseClient.fetchGallery(gid: gid) else { return .none }
                state.gallery = gallery
                state.galleryDetail = databaseClient.fetchGalleryDetail(gid: state.gallery.id)
                return .run { [state] send in
                    guard let dbState = await databaseClient.fetchGalleryState(gid: state.gallery.id) else { return }
                    await send(.fetchDatabaseInfosDone(dbState))
                }
                .cancellable(id: CancelID.fetchDatabaseInfos)

            case .fetchDatabaseInfosDone(let galleryState):
                if let previewConfig = galleryState.previewConfig {
                    state.previewConfig = previewConfig
                }
                state.previewURLs = galleryState.previewURLs
                state.imageURLs = galleryState.imageURLs
                state.thumbnailURLs = galleryState.thumbnailURLs
                state.originalImageURLs =  galleryState.originalImageURLs
                state.readingProgress = state.initialReadingProgress ?? galleryState.readingProgress
                state.initialReadingProgress = nil
                state.databaseLoadingState = .idle
                return .none

            case .fetchOfflineReadingProgressDone(let progress):
                if progress > 0 {
                    state.readingProgress = progress
                }
                state.databaseLoadingState = .idle
                return .none

            case .fetchPreviewURLs(let index):
                guard state.previewURLs[index] == nil,
                      state.previewLoadingStates[index] != .loading,
                      let galleryURL = state.gallery.galleryURL
                else { return .none }
                let pageNum = state.previewConfig.pageNumber(index: index)
                state.previewLoadingStates[index] = .loading
                state.pendingPreviewIndices[pageNum, default: []].insert(index)
                // One request per preview page, not per image index: dragging the slider
                // otherwise asked for the very same page twenty or forty times.
                guard state.loadingPreviewPageNumbers.insert(pageNum).inserted else { return .none }
                return .run { send in
                    let response = await GalleryPreviewURLsRequest(galleryURL: galleryURL, pageNum: pageNum).response()
                    await send(.fetchPreviewURLsDone(pageNum, response))
                }
                .cancellable(id: CancelID.fetchPreviewURLs)

            case .fetchPreviewURLsDone(let pageNum, let result):
                state.loadingPreviewPageNumbers.remove(pageNum)
                let waitingIndices = state.pendingPreviewIndices.removeValue(forKey: pageNum) ?? []
                switch result {
                case .success(let previewURLs):
                    guard !previewURLs.isEmpty else {
                        waitingIndices.forEach { state.previewLoadingStates[$0] = .failed(.notFound) }
                        return .none
                    }
                    waitingIndices.forEach { state.previewLoadingStates[$0] = .idle }
                    state.updatePreviewURLs(previewURLs)
                    return .send(.syncPreviewURLs(previewURLs))
                case .failure(let error):
                    waitingIndices.forEach { state.previewLoadingStates[$0] = .failed(error) }
                }
                return .none

            case .fetchImageURLs(let index):
                guard !state.isOffline else { return .none }
                state.prioritizedImageIndex = index
                guard state.imageURLs[index] == nil else { return .none }
                if state.mpvKey != nil {
                    return .send(.fetchMPVImageURL(index, false))
                } else if let thumbnailURL = state.thumbnailURLs[index] {
                    return .send(.fetchNormalImageURL(index, thumbnailURL))
                } else {
                    return .send(.fetchThumbnailURLs(index))
                }

            case .refetchImageURLs(let index):
                guard !state.isOffline else { return .none }
                guard state.imageURLs[index] != nil else {
                    state.imageURLLoadingStates[index] = .idle
                    return .send(.fetchImageURLs(index))
                }
                if state.mpvKey != nil {
                    return .send(.fetchMPVImageURL(index, true))
                } else {
                    return .send(.refetchNormalImageURLs(index))
                }

            case .prefetchImages(let index, let prefetchLimit):
                return prefetchImages(state: &state, index: index, limit: prefetchLimit)

            case .fetchThumbnailURLs(let index):
                return fetchThumbnailURLs(state: &state, index: index)

            case .fetchThumbnailURLsDone(let index, let pageNum, let result):
                return fetchThumbnailURLsDone(
                    state: &state, index: index, pageNum: pageNum, result: result
                )

            case .fetchNormalImageURL(let index, let thumbnailURL):
                return fetchNormalImageURL(state: &state, index: index, thumbnailURL: thumbnailURL)

            case .fetchNormalImageURLDone(let index, let result):
                return fetchNormalImageURLDone(state: &state, index: index, result: result)

            case .fetchPendingNormalImageURLs(let index):
                return fetchPendingNormalImageURLs(state: &state, index: index)

            case .fetchNormalImageURLs(let index, let thumbnailURLs):
                return fetchNormalImageURLs(state: &state, index: index, thumbnailURLs: thumbnailURLs)

            case .fetchNormalImageURLsDone(_, let attemptedIndices, let result):
                return fetchNormalImageURLsDone(
                    state: &state, attemptedIndices: attemptedIndices, result: result
                )

            case .refetchNormalImageURLs(let index):
                return refetchNormalImageURLs(state: &state, index: index)

            case .refetchNormalImageURLsDone(let index, let result):
                state.refetchingNormalImageURLIndices.remove(index)
                var effects = [Effect<Action>]()
                switch result {
                case .success(let (imageURLs, response)):
                    if let response = response {
                        effects.append(.run(operation: { _ in cookieClient.setSkipServer(response: response) }))
                    }
                    if imageURLs.isEmpty {
                        state.imageURLLoadingStates[index] = .failed(.notFound)
                    } else {
                        state.imageURLLoadingStates[index] = .idle
                        state.updateImageURLs(imageURLs, [:])
                        effects.append(.send(.syncImageURLs(imageURLs, [:])))
                    }
                case .failure(let error):
                    state.imageURLLoadingStates[index] = .failed(error)
                }
                effects.append(contentsOf: drainNormalImageURLRefetchQueue(state: &state))
                return effects.isEmpty ? .none : .merge(effects)

            case .fetchMPVKeys(let index, let mpvURL):
                // The MPV key set covers the whole gallery. Refetching it because another
                // thumbnail page happened to resolve to an MPV URL wasted a request and a
                // full parse per page turn.
                guard state.mpvKey == nil else {
                    return .send(.fetchMPVImageURL(index, false))
                }
                guard !state.isMPVKeysLoading else { return .none }
                state.isMPVKeysLoading = true
                return .run { send in
                    let response = await MPVKeysRequest(mpvURL: mpvURL).response()
                    await send(.fetchMPVKeysDone(index, response))
                }
                .cancellable(id: CancelID.fetchMPVKeys)

            case .fetchMPVKeysDone(let index, let result):
                state.isMPVKeysLoading = false
                let batchRange = state.previewConfig.batchRange(index: index)
                switch result {
                case .success(let (mpvKey, mpvImageKeys)):
                    let pageCount = state.validPageCount
                    guard mpvImageKeys.count == pageCount else {
                        batchRange.forEach {
                            state.imageURLLoadingStates[$0] = .failed(.notFound)
                        }
                        return .none
                    }
                    batchRange.forEach {
                        state.imageURLLoadingStates[$0] = .idle
                    }
                    state.mpvKey = mpvKey
                    state.mpvImageKeys = mpvImageKeys
                    let initialIndices = Set(Array(1...min(3, pageCount)) + [index])
                        .filter { state.imageURLs[$0] == nil }
                        .sorted()
                    guard !initialIndices.isEmpty else { return .none }
                    return .merge(
                        initialIndices.map {
                            .send(.fetchMPVImageURL($0, false))
                        }
                    )
                case .failure(let error):
                    batchRange.forEach {
                        state.imageURLLoadingStates[$0] = .failed(error)
                    }
                }
                return .none

            case .fetchMPVImageURL(let index, let isRefresh):
                return fetchMPVImageURL(state: &state, index: index, isRefresh: isRefresh)

            case .fetchMPVImageURLDone(let index, let result):
                state.mpvImageURLLoadingIndices.remove(index)
                var effects = [Effect<Action>]()
                switch result {
                case .success(let (imageURL, originalImageURL, skipServerIdentifier)):
                    let imageURLs: [Int: URL] = [index: imageURL]
                    var originalImageURLs = [Int: URL]()
                    if let originalImageURL = originalImageURL {
                        originalImageURLs[index] = originalImageURL
                    }
                    state.imageURLLoadingStates[index] = .idle
                    state.mpvSkipServerIdentifiers[index] = skipServerIdentifier
                    state.updateImageURLs(imageURLs, originalImageURLs)
                    effects.append(.send(.syncImageURLs(imageURLs, originalImageURLs)))
                case .failure(let error):
                    state.imageURLLoadingStates[index] = .failed(error)
                }
                effects.append(contentsOf: drainMPVImageURLQueue(state: &state))
                return effects.isEmpty ? .none : .merge(effects)
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.readingSetting,
            hapticsClient: hapticsClient
        )
        .haptics(
            unwrapping: \.route,
            case: /Route.share,
            hapticsClient: hapticsClient
        )
    }

    private static func mergeStoredURLs(_ storedData: inout Data?, with new: [Int: URL]) {
        guard !new.isEmpty else { return }
        if let stored = storedData?.toObject() as [Int: URL]? {
            storedData = stored.merging(new, uniquingKeysWith: { _, new in new }).toData()
        } else {
            storedData = new.toData()
        }
    }

    private func scheduleURLCheckpoint(gid: String) -> Effect<Action> {
        .run { send in
            try await Task.sleep(for: .milliseconds(1500))
            await send(.commitURLCheckpoint)
        }
        .cancellable(id: URLCheckpointID(gid: gid), cancelInFlight: true)
    }

    private func prefetchImages(state: inout State, index: Int, limit: Int) -> Effect<Action> {
        guard !state.isOffline else { return .none }
        state.prioritizedImageIndex = index
        var effects = [Effect<Action>]()
        let sortedIndices = State.prefetchCandidateIndices(
            center: index, pageCount: state.validPageCount, limit: limit
        )
        let resolvedURLs = sortedIndices.compactMap { state.imageURLs[$0] }
        effects.append(.run { [resolvedURLs] _ in imageClient.prefetchImages(resolvedURLs) })

        var resolvableThumbnailURLs = [Int: URL]()
        for candidateIndex in sortedIndices where state.imageURLs[candidateIndex] == nil {
            guard state.allowsAutomaticImageURLFetch(at: candidateIndex) else { continue }
            if state.mpvKey != nil {
                // An MPV gallery resolves pages through its key set; asking for the
                // thumbnail page again only re-detects MPV and refetches the keys.
                effects.append(.send(.fetchMPVImageURL(candidateIndex, false)))
            } else if let thumbnailURL = state.thumbnailURLs[candidateIndex] {
                resolvableThumbnailURLs[candidateIndex] = thumbnailURL
            } else {
                effects.append(.send(.fetchThumbnailURLs(candidateIndex)))
            }
        }
        if !resolvableThumbnailURLs.isEmpty {
            effects.append(.send(.fetchNormalImageURLs(index, resolvableThumbnailURLs)))
        }
        return effects.isEmpty ? .none : .merge(effects)
    }

    // Refetching had no ceiling: retry-all and automatic retries could put one request
    // per failed page in flight at once. Requests beyond the slot count wait in a
    // nearest-first queue admitted only by a completion, never by elapsed time.
    private func refetchNormalImageURLs(state: inout State, index: Int) -> Effect<Action> {
        guard state.refetchingNormalImageURLIndices.count
                < State.maxConcurrentNormalImageURLRefetches
        else {
            guard !state.refetchingNormalImageURLIndices.contains(index),
                  state.imageURLLoadingStates[index] != .loading,
                  state.gallery.galleryURL != nil,
                  state.imageURLs[index] != nil
            else { return .none }
            state.enqueueNormalImageURLRefetch(index)
            return .none
        }
        return startNormalImageURLRefetch(state: &state, index: index) ?? .none
    }

    private func drainNormalImageURLRefetchQueue(state: inout State) -> [Effect<Action>] {
        var effects = [Effect<Action>]()
        while state.refetchingNormalImageURLIndices.count
                < State.maxConcurrentNormalImageURLRefetches,
              let next = state.dequeueNormalImageURLRefetch() {
            if let effect = startNormalImageURLRefetch(state: &state, index: next) {
                effects.append(effect)
            }
        }
        return effects
    }

    // Returns nil when the page is already in flight or can no longer be refetched.
    private func startNormalImageURLRefetch(state: inout State, index: Int) -> Effect<Action>? {
        guard !state.refetchingNormalImageURLIndices.contains(index),
              state.imageURLLoadingStates[index] != .loading,
              let galleryURL = state.gallery.galleryURL,
              let imageURL = state.imageURLs[index]
        else { return nil }
        state.refetchingNormalImageURLIndices.insert(index)
        state.imageURLLoadingStates[index] = .loading
        let pageNum = state.previewConfig.pageNumber(index: index)
        return .run { [thumbnailURL = state.thumbnailURLs[index]] send in
            let response = await GalleryNormalImageURLRefetchRequest(
                index: index,
                pageNum: pageNum,
                galleryURL: galleryURL,
                thumbnailURL: thumbnailURL,
                storedImageURL: imageURL
            )
            .response()
            await send(.refetchNormalImageURLsDone(index, response))
        }
        .cancellable(id: CancelID.refetchNormalImageURLs)
    }

    // MPV resolves exactly one page per request, so an unguarded fan-out turns a page
    // turn into a burst. Requests beyond the slot count wait in a nearest-first queue
    // that is drained as each in-flight request completes.
    private func fetchMPVImageURL(state: inout State, index: Int, isRefresh: Bool) -> Effect<Action> {
        guard state.mpvImageURLLoadingIndices.count < State.maxConcurrentMPVImageURLRequests else {
            guard state.mpvKey != nil, state.mpvImageKeys[index] != nil,
                  isRefresh || state.imageURLs[index] == nil,
                  !state.mpvImageURLLoadingIndices.contains(index)
            else { return .none }
            state.enqueueMPVImageURLRequest(.init(index: index, isRefresh: isRefresh))
            return .none
        }
        return startMPVImageURLRequest(state: &state, index: index, isRefresh: isRefresh) ?? .none
    }

    private func drainMPVImageURLQueue(state: inout State) -> [Effect<Action>] {
        var effects = [Effect<Action>]()
        while state.mpvImageURLLoadingIndices.count < State.maxConcurrentMPVImageURLRequests,
              let next = state.dequeueMPVImageURLRequest() {
            if let effect = startMPVImageURLRequest(
                state: &state, index: next.index, isRefresh: next.isRefresh
            ) {
                effects.append(effect)
            }
        }
        return effects
    }

    // Returns nil when the page no longer needs resolving or is already in flight.
    private func startMPVImageURLRequest(
        state: inout State, index: Int, isRefresh: Bool
    ) -> Effect<Action>? {
        guard let gidInteger = Int(state.gallery.id), let mpvKey = state.mpvKey,
              let mpvImageKey = state.mpvImageKeys[index],
              isRefresh || state.imageURLs[index] == nil,
              !state.mpvImageURLLoadingIndices.contains(index),
              state.imageURLLoadingStates[index] != .loading
        else { return nil }
        state.mpvImageURLLoadingIndices.insert(index)
        state.imageURLLoadingStates[index] = .loading
        let skipServerIdentifier = isRefresh ? state.mpvSkipServerIdentifiers[index] : nil
        return .run { send in
            let response = await GalleryMPVImageURLRequest(
                gid: gidInteger,
                index: index,
                mpvKey: mpvKey,
                mpvImageKey: mpvImageKey,
                skipServerIdentifier: skipServerIdentifier
            )
            .response()
            await send(.fetchMPVImageURLDone(index, response))
        }
        .cancellable(id: CancelID.fetchMPVImageURL)
    }

    private func fetchThumbnailURLs(state: inout State, index: Int) -> Effect<Action> {
        guard state.imageURLs[index] == nil,
              let galleryURL = state.gallery.galleryURL else { return .none }
        if state.mpvKey != nil {
            return .send(.fetchMPVImageURL(index, false))
        }
        if let thumbnailURL = state.thumbnailURLs[index] {
            return .send(.fetchNormalImageURL(index, thumbnailURL))
        }
        let pageNum = state.previewConfig.pageNumber(index: index)
        state.pendingThumbnailIndices[pageNum, default: []].insert(index)
        state.imageURLLoadingStates[index] = .loading
        guard state.loadingThumbnailPageNumbers.insert(pageNum).inserted else { return .none }
        return .run { send in
            let response = await ThumbnailURLsRequest(
                galleryURL: galleryURL, pageNum: pageNum
            ).response()
            await send(.fetchThumbnailURLsDone(index, pageNum, response))
        }
        .cancellable(id: CancelID.fetchThumbnailURLs)
    }

    private func fetchThumbnailURLsDone(
        state: inout State,
        index: Int,
        pageNum: Int,
        result: Result<[Int: URL], AppError>
    ) -> Effect<Action> {
        state.loadingThumbnailPageNumbers.remove(pageNum)
        let pendingIndices = state.pendingThumbnailIndices.removeValue(forKey: pageNum) ?? [index]
        pendingIndices.forEach { state.imageURLLoadingStates[$0] = .idle }
        switch result {
        case .success(let thumbnailURLs):
            guard !thumbnailURLs.isEmpty else {
                pendingIndices.forEach { state.imageURLLoadingStates[$0] = .failed(.notFound) }
                return .none
            }
            let priorityIndex = closestIndex(
                in: pendingIndices, to: state.prioritizedImageIndex, fallback: index
            )
            if let url = thumbnailURLs[priorityIndex], urlClient.checkIfMPVURL(url) {
                return .send(.fetchMPVKeys(priorityIndex, url))
            }

            state.updateThumbnailURLs(thumbnailURLs)
            let resolvableIndices = pendingIndices.filter {
                thumbnailURLs[$0] != nil && state.imageURLs[$0] == nil
            }
            pendingIndices.subtracting(resolvableIndices).forEach {
                state.imageURLLoadingStates[$0] = .failed(.notFound)
            }
            guard let priorityIndex = closestIndex(
                in: resolvableIndices, to: state.prioritizedImageIndex
            ), let priorityURL = thumbnailURLs[priorityIndex] else {
                return .send(.syncThumbnailURLs(thumbnailURLs))
            }
            state.pendingNormalImageURLIndices.formUnion(resolvableIndices)
            return .merge(
                .send(.syncThumbnailURLs(thumbnailURLs)),
                .send(.fetchNormalImageURL(priorityIndex, priorityURL))
            )
        case .failure(let error):
            pendingIndices.forEach { state.imageURLLoadingStates[$0] = .failed(error) }
            return .none
        }
    }

    private func fetchNormalImageURL(
        state: inout State, index: Int, thumbnailURL: URL
    ) -> Effect<Action> {
        guard state.imageURLs[index] == nil else { return .none }
        if state.isNormalImageURLBatchLoading {
            let interruptedIndices = state.normalImageURLBatchIndices
            state.pendingNormalImageURLIndices.formUnion(interruptedIndices)
            interruptedIndices.forEach { state.imageURLLoadingStates[$0] = .idle }
            state.normalImageURLBatchIndices = []
            state.isNormalImageURLBatchLoading = false
            return .merge(
                .cancel(id: CancelID.fetchNormalImageURLs),
                .send(.fetchNormalImageURL(index, thumbnailURL))
            )
        }
        if let loadingIndex = state.prioritizedNormalImageURLLoadingIndex, loadingIndex != index {
            state.imageURLLoadingStates[loadingIndex] = .idle
            state.pendingNormalImageURLIndices.insert(loadingIndex)
        }
        guard state.imageURLLoadingStates[index] != .loading else { return .none }
        state.prioritizedNormalImageURLLoadingIndex = index
        state.imageURLLoadingStates[index] = .loading
        return .run { send in
            let response = await GalleryNormalImageURLRequest(
                index: index, thumbnailURL: thumbnailURL
            ).response()
            await send(.fetchNormalImageURLDone(index, response))
        }
        .cancellable(id: CancelID.fetchPrioritizedNormalImageURL, cancelInFlight: true)
    }

    private func fetchNormalImageURLDone(
        state: inout State,
        index: Int,
        result: Result<(Int, URL, URL?), AppError>
    ) -> Effect<Action> {
        if state.prioritizedNormalImageURLLoadingIndex == index {
            state.prioritizedNormalImageURLLoadingIndex = nil
        }
        state.pendingNormalImageURLIndices.remove(index)
        var effects: [Effect<Action>] = [.send(.fetchPendingNormalImageURLs(index))]
        switch result {
        case .success(let (_, imageURL, originalImageURL)):
            let imageURLs = [index: imageURL]
            let originalImageURLs: [Int: URL]
            if let originalImageURL {
                originalImageURLs = [index: originalImageURL]
            } else {
                originalImageURLs = [:]
            }
            state.imageURLLoadingStates[index] = .idle
            state.updateImageURLs(imageURLs, originalImageURLs)
            effects.append(.send(.syncImageURLs(imageURLs, originalImageURLs)))
        case .failure(let error):
            state.imageURLLoadingStates[index] = .failed(error)
        }
        return .merge(effects)
    }

    private func fetchPendingNormalImageURLs(state: inout State, index: Int) -> Effect<Action> {
        let lowerBound = max(1, index - 3)
        let upperBound = min(state.validPageCount, index + 3)
        var indices = state.pendingNormalImageURLIndices
        if lowerBound <= upperBound {
            indices.formUnion(lowerBound...upperBound)
        }
        var thumbnailURLs = [Int: URL]()
        for candidateIndex in indices {
            guard state.imageURLs[candidateIndex] == nil,
                  state.allowsAutomaticImageURLFetch(at: candidateIndex),
                  let thumbnailURL = state.thumbnailURLs[candidateIndex] else { continue }
            thumbnailURLs[candidateIndex] = thumbnailURL
        }
        guard !thumbnailURLs.isEmpty else { return .none }
        return .send(.fetchNormalImageURLs(index, thumbnailURLs))
    }

    private func fetchNormalImageURLs(
        state: inout State, index: Int, thumbnailURLs: [Int: URL]
    ) -> Effect<Action> {
        let availableURLs = thumbnailURLs.filter { candidateIndex, _ in
            state.imageURLs[candidateIndex] == nil
                && state.allowsAutomaticImageURLFetch(at: candidateIndex)
        }
        state.pendingNormalImageURLIndices.formUnion(availableURLs.keys)
        guard state.prioritizedNormalImageURLLoadingIndex == nil,
              !state.isNormalImageURLBatchLoading else { return .none }

        let attemptedIndices = state.pendingNormalImageURLIndices
            .filter {
                state.imageURLs[$0] == nil
                    && state.allowsAutomaticImageURLFetch(at: $0)
                    && state.thumbnailURLs[$0] != nil
            }
            .sorted {
                let leftDistance = abs($0 - state.prioritizedImageIndex)
                let rightDistance = abs($1 - state.prioritizedImageIndex)
                return leftDistance == rightDistance ? $0 > $1 : leftDistance < rightDistance
            }
            .prefix(3)
            .map { $0 }
        guard !attemptedIndices.isEmpty else { return .none }
        let pendingURLs = Dictionary(uniqueKeysWithValues: attemptedIndices.compactMap { candidateIndex in
            let thumbnailURL = availableURLs[candidateIndex] ?? state.thumbnailURLs[candidateIndex]
            return thumbnailURL.map { (candidateIndex, $0) }
        })
        guard pendingURLs.count == attemptedIndices.count else { return .none }
        state.isNormalImageURLBatchLoading = true
        state.normalImageURLBatchIndices = Set(attemptedIndices)
        attemptedIndices.forEach {
            state.imageURLLoadingStates[$0] = .loading
            state.pendingNormalImageURLIndices.remove($0)
        }
        return .run { send in
            let response = await GalleryNormalImageURLsRequest(
                thumbnailURLs: pendingURLs, maxConcurrentRequests: 3
            ).response()
            await send(.fetchNormalImageURLsDone(index, attemptedIndices, response))
        }
        .cancellable(id: CancelID.fetchNormalImageURLs)
    }

    private func fetchNormalImageURLsDone(
        state: inout State,
        attemptedIndices: [Int],
        result: Result<([Int: URL], [Int: URL]), AppError>
    ) -> Effect<Action> {
        state.isNormalImageURLBatchLoading = false
        state.normalImageURLBatchIndices = []
        var effects: [Effect<Action>] = [
            .send(.fetchPendingNormalImageURLs(state.prioritizedImageIndex))
        ]
        switch result {
        case .success(let (imageURLs, originalImageURLs)):
            attemptedIndices.forEach { attemptedIndex in
                state.imageURLLoadingStates[attemptedIndex] = imageURLs[attemptedIndex] == nil
                    ? .failed(.notFound) : .idle
            }
            guard !imageURLs.isEmpty else { return .merge(effects) }
            state.updateImageURLs(imageURLs, originalImageURLs)
            let prefetchURLs = imageURLs.sorted(by: { $0.key < $1.key }).map(\.value)
            effects.append(.send(.syncImageURLs(imageURLs, originalImageURLs)))
            effects.append(.run { [prefetchURLs] _ in imageClient.prefetchImages(prefetchURLs) })
            return .merge(effects)
        case .failure(let error):
            attemptedIndices.forEach { state.imageURLLoadingStates[$0] = .failed(error) }
            return .merge(effects)
        }
    }

    private func closestIndex(in indices: Set<Int>, to target: Int) -> Int? {
        indices.min {
            let leftDistance = abs($0 - target)
            let rightDistance = abs($1 - target)
            return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
        }
    }

    private func closestIndex(in indices: Set<Int>, to target: Int, fallback: Int) -> Int {
        closestIndex(in: indices, to: target) ?? fallback
    }
}

extension ReadingReducer.State {
    static func offline(download: GalleryDownload, imageURLs: [Int: URL]) -> Self {
        var state = Self()
        state.gallery = download.gallery
        state.galleryDetail = download.detail
        state.previewConfig = download.previewConfig
        state.imageURLs = imageURLs
        state.originalImageURLs = imageURLs
        // Stays .loading until the stored reading progress arrives in
        // fetchOfflineReadingProgressDone, so the page is initialized once, correctly.
        state.databaseLoadingState = .loading
        state.isOffline = true
        return state
    }
}
