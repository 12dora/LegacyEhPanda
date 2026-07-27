//
//  FrontpageReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/08.
//

import ComposableArchitecture
import Foundation

struct FrontpageReducer: Reducer {
    enum Route: Equatable {
        case filters
        case detail(String)
    }

    private enum CancelID: CaseIterable {
        case fetchGalleries, fetchMoreGalleries, fetchDateSeekGalleries
    }

    /// Backstop for a run of empty-but-continuable pages, bounding the work even while the
    /// server keeps advancing its cursor.
    private static let maxEmptyPageContinuations = 10

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var keyword = ""
        @BindingState var dateSeekPresented = false
        @BindingState var dateSeekDate = Date()

        var filteredGalleries: [Gallery] {
            guard !keyword.isEmpty else { return galleries }
            return galleries.filter({ $0.title.caseInsensitiveContains(keyword) })
        }
        var galleries = [Gallery]()
        var pageNumber = PageNumber()
        var loadingState: LoadingState = .idle
        var footerLoadingState: LoadingState = .idle

        /// Identifies the current base request (initial fetch or date seek). Footer completions
        /// carrying an older generation are rejected so stale pages never append to a newer list.
        var requestGeneration = 0
        /// Continuation cursor, held separately from the rendered list so that an empty page
        /// cannot reuse a previous request's last item.
        var lastGalleryID: String?
        var emptyPageContinuations = 0

        var filtersState = FiltersReducer.State()
        @Heap var detailState: DetailReducer.State!

        init() {
            _detailState = .init(.init())
        }

        mutating func insertGalleries(_ galleries: [Gallery]) {
            galleries.forEach { gallery in
                if !self.galleries.contains(gallery) {
                    self.galleries.append(gallery)
                }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates

        case teardown
        case fetchGalleries
        case fetchGalleriesDone(Int, Result<(PageNumber, [Gallery]), AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Int, Result<(PageNumber, [Gallery]), AppError>)
        case presentDateSeek
        case performDateSeek(DateSeekDirection)
        case performDateSeekDone(Int, Result<(PageNumber, [Gallery]), AppError>)

        case filters(FiltersReducer.Action)
        case detail(DetailReducer.Action)
    }

    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient

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
                state.detailState = .init(replacing: state.detailState)
                state.filtersState = .init()
                return .send(.detail(.teardown))

            case .teardown:
                return .merge(CancelID.allCases.map(Effect.cancel(id:)))

            case .fetchGalleries:
                // Latest-wins: a new base request replaces the in-flight base/date-seek request
                // and any footer continuation instead of racing them.
                state.requestGeneration += 1
                state.lastGalleryID = nil
                state.emptyPageContinuations = 0
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let generation = state.requestGeneration
                let filter = databaseClient.fetchFilterSynchronously(range: .global)
                return .merge(
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .cancel(id: CancelID.fetchDateSeekGalleries),
                    .run { send in
                        let response = await FrontpageGalleriesRequest(filter: filter).response()
                        await send(.fetchGalleriesDone(generation, response))
                    }
                    .cancellable(id: CancelID.fetchGalleries, cancelInFlight: true)
                )

            case .fetchGalleriesDone(let generation, let result):
                guard generation == state.requestGeneration else { return .none }
                state.loadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    // Retain the returned pagination before any continuation is dispatched.
                    state.pageNumber = pageNumber
                    guard !galleries.isEmpty else {
                        state.loadingState = .failed(.notFound)
                        // An empty page carries no row to continue from; only the server's own
                        // cursor can advance past it.
                        guard pageNumber.hasNextPage(), pageNumber.nextPageCursor != nil
                        else { return .none }
                        return .send(.fetchMoreGalleries)
                    }
                    state.galleries = galleries
                    state.lastGalleryID = galleries.last?.id
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache frontpage galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.loadingState = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                let pageNumber = state.pageNumber
                let cursor = pageNumber.nextPageCursor
                guard pageNumber.hasNextPage(),
                      state.footerLoadingState != .loading,
                      let lastID = cursor ?? state.lastGalleryID
                else { return .none }
                state.footerLoadingState = .loading
                let generation = state.requestGeneration
                let filter = databaseClient.fetchFilterSynchronously(range: .global)
                return .run { send in
                    let response = await MoreFrontpageGalleriesRequest(
                        filter: filter, lastID: lastID, nextCursor: cursor
                    )
                    .response()
                    await send(.fetchMoreGalleriesDone(generation, response))
                }
                .cancellable(id: CancelID.fetchMoreGalleries, cancelInFlight: true)

            case .fetchMoreGalleriesDone(let generation, let result):
                guard generation == state.requestGeneration else { return .none }
                state.footerLoadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    let previousCursor = state.pageNumber.nextPageCursor
                    state.pageNumber = pageNumber
                    state.insertGalleries(galleries)

                    var effects: [Effect<Action>] = [
                        .run { _ in
                            let result = await databaseClient.cacheGalleries(galleries)
                            if case .failure(let error) = result {
                                Logger.error("Failed to cache frontpage galleries.", context: ["error": "\(error)"])
                            }
                        }
                    ]
                    if galleries.isEmpty {
                        state.emptyPageContinuations += 1
                        // Continue only while the server keeps handing back a *new* cursor: an
                        // unchanged cursor would replay the same empty page forever.
                        if pageNumber.hasNextPage(),
                           let cursor = pageNumber.nextPageCursor, cursor != previousCursor,
                           state.emptyPageContinuations <= Self.maxEmptyPageContinuations {
                            effects.append(.send(.fetchMoreGalleries))
                        }
                    } else {
                        state.emptyPageContinuations = 0
                        state.lastGalleryID = galleries.last?.id
                        state.loadingState = .idle
                    }
                    return .merge(effects)

                case .failure(let error):
                    state.footerLoadingState = .failed(error)
                }
                return .none

            case .presentDateSeek:
                guard let navigation = state.pageNumber.dateSeekNavigation else { return .none }
                state.dateSeekDate = navigation.clampedDate(state.dateSeekDate)
                state.dateSeekPresented = true
                return .run(operation: { _ in hapticsClient.generateFeedback(.light) })

            case .performDateSeek(let direction):
                guard let url = state.pageNumber.dateSeekNavigation?
                    .seekURL(date: state.dateSeekDate, direction: direction)
                else { return .none }
                state.dateSeekPresented = false
                state.requestGeneration += 1
                state.lastGalleryID = nil
                state.emptyPageContinuations = 0
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let generation = state.requestGeneration
                return .merge(
                    .cancel(id: CancelID.fetchGalleries),
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .run { send in
                        await send(
                            .performDateSeekDone(
                                generation, await DateSeekGalleriesRequest(url: url).response()
                            )
                        )
                    }
                    .cancellable(id: CancelID.fetchDateSeekGalleries, cancelInFlight: true)
                )

            case .performDateSeekDone(let generation, let result):
                guard generation == state.requestGeneration else { return .none }
                state.loadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.pageNumber = pageNumber
                    guard !galleries.isEmpty else {
                        state.loadingState = .failed(.notFound)
                        return .none
                    }
                    state.galleries = galleries
                    state.lastGalleryID = galleries.last?.id
                    if let navigation = pageNumber.dateSeekNavigation {
                        state.dateSeekDate = navigation.clampedDate(state.dateSeekDate)
                    }
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache frontpage date galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.loadingState = .failed(error)
                    return .none
                }

            case .filters:
                return .none

            case .detail:
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.filters,
            hapticsClient: hapticsClient
        )

        Scope(state: \.filtersState, action: /Action.filters, child: FiltersReducer.init)
        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
    }
}
