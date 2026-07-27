//
//  PreviewsReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/16.
//

import Foundation
import ComposableArchitecture

struct PreviewsReducer: Reducer {
    enum Route {
        case reading
    }

    /// Scoped to the state instance so tearing down one previews screen never cancels the
    /// requests of another one that is still on screen.
    private enum CancelIdentifier: CaseIterable {
        case fetchDatabaseInfos, fetchPreviewURLs
    }

    private struct CancelID: Hashable {
        let instanceID: UUID
        let identifier: CancelIdentifier
    }

    struct State: Equatable {
        @BindingState var route: Route?

        var instanceID = UUID()
        var gallery: Gallery = .empty
        var databaseLoadingState: LoadingState = .loading

        /// Per-image loading state. A single screen-wide flag used to swallow every page
        /// boundary that arrived while another batch was still in flight.
        var previewLoadingStates = [Int: LoadingState]()
        /// Preview pages currently being requested, so one page is fetched once for the many
        /// images that belong to it.
        var loadingPreviewPageNumbers = Set<Int>()
        /// Images waiting for a given page, so a result or an error reaches all of them.
        var pendingPreviewIndices = [Int: Set<Int>]()

        var previewURLs = [Int: URL]()
        var previewConfig: PreviewConfig = .normal(rows: 4)

        var readingState = ReadingReducer.State()

        mutating func updatePreviewURLs(_ previewURLs: [Int: URL]) {
            self.previewURLs = self.previewURLs.merging(
                previewURLs, uniquingKeysWith: { stored, _ in stored }
            )
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates

        case syncPreviewURLs([Int: URL])
        case updateReadingProgress(Int)
        case navigateReading(Int)

        case teardown
        case fetchDatabaseInfos(String)
        case fetchDatabaseInfosDone(GalleryState)
        case fetchDatabaseInfosFailed(String)
        case fetchPreviewURLs(Int)
        case fetchPreviewURLsDone(Int, Result<[Int: URL], AppError>)

        case reading(ReadingReducer.Action)
    }

    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient

    /// How long the screen waits for a pending background cache write before it gives up.
    private static let galleryCacheRetryCount = 8
    private static let galleryCacheRetryInterval = 250

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding(\.$route):
                return state.route == nil ? .send(.clearSubStates) : .none

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .clearSubStates:
                state.readingState = .init()
                return .send(.reading(.teardown))

            case .syncPreviewURLs(let previewURLs):
                return .run { [state] _ in
                    let result = await databaseClient.updatePreviewURLs(
                        gid: state.gallery.id, previewURLs: previewURLs
                    )
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist preview URLs.", context: [
                            "gid": state.gallery.id, "error": "\(error)"
                        ])
                    }
                }

            case .updateReadingProgress(let progress):
                return .run { [state] _ in
                    let result = await databaseClient.updateReadingProgress(
                        gid: state.gallery.id, progress: progress
                    )
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist preview reading progress.", context: [
                            "gid": state.gallery.id, "progress": progress, "error": "\(error)"
                        ])
                    }
                }

            case .navigateReading(let progress):
                // The reader reads its starting page back from the database, so hand the page
                // over in state first and only present it once the write has landed.
                state.readingState.setInitialReadingProgress(progress)
                return .run { [galleryID = state.gallery.id] send in
                    let result = await databaseClient.updateReadingProgress(gid: galleryID, progress: progress)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist preview navigation progress.", context: [
                            "gid": galleryID, "progress": progress, "error": "\(error)"
                        ])
                    }
                    await send(.setNavigation(.reading))
                }

            case .teardown:
                let effects: [Effect<Action>] = CancelIdentifier.allCases.map {
                    .cancel(id: CancelID(instanceID: state.instanceID, identifier: $0))
                }
                return .merge(effects)

            case .fetchDatabaseInfos(let gid):
                guard gid.isValidGID else {
                    state.databaseLoadingState = .failed(.notFound)
                    return .none
                }
                guard let gallery = databaseClient.fetchGallery(gid: gid) else {
                    // The gallery may still be on its way into the database, so wait a little
                    // before declaring the screen empty, and stay retryable afterwards.
                    state.databaseLoadingState = .loading
                    return .run { send in
                        for _ in 0..<Self.galleryCacheRetryCount {
                            try await Task.sleep(for: .milliseconds(Self.galleryCacheRetryInterval))
                            let isCached = await MainActor.run {
                                databaseClient.fetchGallery(gid: gid) != nil
                            }
                            if isCached {
                                await send(.fetchDatabaseInfos(gid))
                                return
                            }
                        }
                        await send(.fetchDatabaseInfosFailed(gid))
                    }
                    .cancellable(
                        id: CancelID(instanceID: state.instanceID, identifier: .fetchDatabaseInfos),
                        cancelInFlight: true
                    )
                }
                state.gallery = gallery
                state.databaseLoadingState = .loading
                return .run { [state] send in
                    guard let dbState = await databaseClient.fetchGalleryState(gid: state.gallery.id) else { return }
                    await send(.fetchDatabaseInfosDone(dbState))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchDatabaseInfos))

            case .fetchDatabaseInfosFailed(let gid):
                guard state.gallery.id == gid || !state.gallery.id.isValidGID else { return .none }
                state.databaseLoadingState = .failed(.databaseUnavailable(nil))
                return .none

            case .fetchDatabaseInfosDone(let galleryState):
                guard galleryState.gid == state.gallery.id else { return .none }
                if let previewConfig = galleryState.previewConfig {
                    state.previewConfig = previewConfig
                }
                state.previewURLs = galleryState.previewURLs
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
                // One request per preview page, however many images of it became visible.
                guard state.loadingPreviewPageNumbers.insert(pageNum).inserted else { return .none }
                return .run { send in
                    let response = await GalleryPreviewURLsRequest(galleryURL: galleryURL, pageNum: pageNum).response()
                    await send(.fetchPreviewURLsDone(pageNum, response))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchPreviewURLs))

            case .fetchPreviewURLsDone(let pageNum, let result):
                state.loadingPreviewPageNumbers.remove(pageNum)
                let waitingIndices = state.pendingPreviewIndices.removeValue(forKey: pageNum) ?? []
                switch result {
                case .success(let previewURLs):
                    guard !previewURLs.isEmpty else {
                        waitingIndices.forEach { state.previewLoadingStates[$0] = .failed(.notFound) }
                        return .none
                    }
                    state.updatePreviewURLs(previewURLs)
                    let resolvedURLs = state.previewURLs
                    waitingIndices.forEach { index in
                        state.previewLoadingStates[index] = resolvedURLs[index] == nil ? .failed(.notFound) : .idle
                    }
                    return .send(.syncPreviewURLs(previewURLs))
                case .failure(let error):
                    waitingIndices.forEach { state.previewLoadingStates[$0] = .failed(error) }
                }
                return .none

            case .reading(.onPerformDismiss):
                return .send(.setNavigation(nil))

            case .reading:
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.reading,
            hapticsClient: hapticsClient
        )

        Scope(state: \.readingState, action: /Action.reading, child: ReadingReducer.init)
    }
}
